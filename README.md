# Cuda-Switch

One script that swaps the precompiled **Strata** inference engine binary for
**Capricorn** to match the GPU pair currently installed in the machine.

There is no compilation here, no CUDA Toolkit changes, and no model config
changes. Two engine binaries already exist — one built for a Tesla P40, one for
a Tesla V100 — and this script picks the right one, checks it, and puts it in
place atomically.

## Why

P40 and V100 need different cubins (`sm_61` vs `sm_70`). Swapping by hand means
remembering which build is which, copying over a live binary while inference is
running, and finding out about an architecture mismatch at runtime. This script
detects the GPUs, verifies the cubins before touching anything, and refuses when
the answer is ambiguous.

## Requirements

- Linux, Bash 4+ (uses `mapfile`)
- `nvidia-smi` — for GPU detection
- `cuobjdump` (CUDA Toolkit) — for cubin architecture verification. Optional:
  if missing, the script warns and skips arch checks rather than failing.
- `sha256sum`, `mktemp`, `mv` — coreutils
- A local (non-network) filesystem under `$STRATA_ROOT/engine` — the final
  `mv -fT` is only atomic on the same filesystem.

## Usage

```bash
./switch-strata-engine.sh [--init | --status | --dry-run | --verify | --switch | --help]
```

No argument means `--switch`.

| Option | What it does |
| --- | --- |
| `--init` | Seeds `engine/versions/` from the existing binaries, without overwriting them |
| `--status` | Shows GPU detection, preserved binaries, and which version is live |
| `--dry-run` | Runs detection and verification, prints the proposed change, writes nothing |
| `--verify` | Checks both preserved binaries have the cubins they claim |
| `--switch` | Detects GPUs and activates the matching engine (default) |
| `--help` | Prints usage |

### Typical flow

```bash
# First run: preserve the two known builds
export STRATA_ROOT="$HOME/Workspaces/Strata"
./switch-strata-engine.sh --init

# Check what you have before changing anything
./switch-strata-engine.sh --status
./switch-strata-engine.sh --dry-run

# Activate the engine matching the installed GPUs
./switch-strata-engine.sh --switch
```

## How GPU selection works

`nvidia-smi --query-gpu=index,name,compute_cap` is queried and the compute
capability of each GPU is normalized to a `sm_XX` arch string (`8.9` → `89`).
Selection keys on **architecture, not GPU index order**, so cards can be
reordered in the PCI topology without confusing the script.

The RTX 4070 (`sm_89`) is expected in every configuration — it is the
always-present GPU, and its absence is a hard error. The second GPU decides
which engine is chosen:

| Detected archs | Configuration | Engine selected |
| --- | --- | --- |
| `sm_61` + `sm_89` | P40 + RTX 4070 | `versions/strata-p40` (needs `sm_61` + `sm_89`) |
| `sm_70` + `sm_89` | V100 + RTX 4070 | `versions/strata-v100` (needs `sm_70` + `sm_89`) |

Any of the following aborts before a single byte is written:

- An architecture outside `{61, 70, 89}` → `Unsupported GPU architecture: sm_NN`
- `sm_89` missing → `Expected RTX 4070 (sm_89) is missing`
- Both `sm_61` **and** `sm_70` present, or neither →
  `Ambiguous GPU combination; no engine selected`
- More or fewer than exactly 2 unique architectures →
  `Unexpected number of GPU architectures`

## Directory layout

```
$STRATA_ROOT/
└── engine/
    ├── strata                 # live binary the launcher actually execs
    ├── strata.backup-p40      # original P40 build, read by --init
    └── versions/
        ├── strata-p40         # sm_61 + sm_89
        └── strata-v100        # sm_70 + sm_89
```

`STRATA_ROOT` defaults to `$HOME/Workspaces/Strata`. Override it to point at a
different checkout:

```bash
STRATA_ROOT=/path/to/strata ./switch-strata-engine.sh --status
```

## Guards

- **No swap during inference.** If a process named exactly `strata` is running
  as you (`pgrep -u "$(id -u)" -x strata`), `--init` and `--switch` abort with
  `A Strata engine process is running. Stop it first.` `--status`, `--verify`,
  and `--dry-run` do not check this.
- **Cubin verification before activation.** `cuobjdump --list-elf` lists the
  embedded cubins; the required archs must each appear as an exact match
  (`grep -qx`). A binary missing native code for its target GPU is rejected
  rather than activated.
- **`--init` is non-destructive and mislabel-proof.** Existing
  `versions/strata-*` files are never overwritten. It refuses if
  `engine/strata` is a symlink (resolve it manually first), and it verifies the
  current binary really contains `sm_70` + `sm_89` cubins before copying it to
  `strata-v100` — so a P40 build can't end up filed under the V100 name.
- **Idempotent.** `--switch` compares SHA-256 of the selected and live binaries
  and reports `Correct engine already active. No change needed.` without
  touching the filesystem.
- **Atomic activation.** The engine is copied to a temp file in the same
  directory (`engine/.strata-switch.XXXXXXXX`), `chmod 755`'d, re-hashed and
  compared against the source, then `mv -fT`'d into place — a same-directory
  rename, so no window where `engine/strata` is half-written or missing. A
  `trap` removes the temp file on any exit path.

## Troubleshooting

| Message | Meaning / fix |
| --- | --- |
| `Missing: .../engine` | `STRATA_ROOT` points at the wrong place, or this checkout has no `engine/` directory at that level. Export `STRATA_ROOT` to the directory that actually contains `engine/`. |
| `nvidia-smi not found` | Install the NVIDIA driver + toolkit. |
| `NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver` | Driver not loaded (or no GPU currently attached). Load/reload it before running. |
| `No NVIDIA GPUs detected` | `nvidia-smi` returned no rows — usually a driver/passthrough problem. |
| `WARNING: cuobjdump unavailable` | Arch checks were skipped; the swap still happened. Install CUDA Toolkit for full verification. |
| `<file> lacks native sm_NN code` | That binary was built for a different GPU. Rebuild it, or fix `versions/` naming. |
| `A Strata engine process is running` | Stop the running engine, then re-run. |
| `engine/strata is a symlink; resolve it manually before --init` | `--init` expects a real file. Replace the symlink with the real binary, or switch to a layout where `versions/` is canonical. |

## Notes

- The header comment inside the script reads `select-strata-engine.sh` while the
  file is named `switch-strata-engine.sh`; the usage banner prints whichever name
  you invoke it as (`$0`).
- Selection is deliberately conservative — unknown or unexpected GPU
  combinations fail closed instead of guessing. Adding a card means adding an
  arch to the `case` in `detect_gpus()` and a branch in `choose_engine()`.

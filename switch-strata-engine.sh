
#!/usr/bin/env bash
# select-strata-engine.sh
# Select a precompiled Strata engine for Capricorn.
# No compilation, CUDA Toolkit changes, or model config changes.

set -euo pipefail

ROOT="${STRATA_ROOT:-$HOME/Workspaces/Strata}"
ENGINE_DIR="$ROOT/engine"
VERSIONS="$ENGINE_DIR/versions"
LIVE="$ENGINE_DIR/strata"

P40="$VERSIONS/strata-p40"
V100="$VERSIONS/strata-v100"

MODE="${1:---switch}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo "[Strata Selector] $*"
}

usage() {
    cat <<EOF
Usage: $0 [OPTION]

Options:
  --init       Preserve existing P40 and V100 binaries
  --status     Show GPU detection and engine status
  --dry-run    Show proposed change without writing
  --verify     Check preserved binaries and CUDA architectures
  --switch     Automatically select and activate engine (default)
  --help       Show help

Environment:
  STRATA_ROOT  Strata project directory
               Default: $HOME/Workspaces/Strata
EOF
}

[[ -d "$ENGINE_DIR" ]] || die "Missing: $ENGINE_DIR"

case "$MODE" in
    --init|--status|--dry-run|--verify|--switch|--help) ;;
    *) die "Unknown option: $MODE" ;;
esac

[[ "$MODE" == "--help" ]] && { usage; exit 0; }

# Detect GPU architectures without relying on GPU index order.
detect_gpus() {
    command -v nvidia-smi >/dev/null ||
        die "nvidia-smi not found"

    GPU_INFO=$(nvidia-smi \
        --query-gpu=index,name,compute_cap \
        --format=csv,noheader,nounits) ||
        die "Cannot query GPUs"

    [[ -n "$GPU_INFO" ]] || die "No NVIDIA GPUs detected"

    info "Detected GPUs:"
    printf '%s\n' "$GPU_INFO"

    mapfile -t ARCHS < <(
        printf '%s\n' "$GPU_INFO" |
        awk -F',' '
          {
            gsub(/[[:space:]]/, "", $3)
            split($3, a, ".")
            print a[1] a[2]
          }' | sort -u
    )

    HAS_61=0
    HAS_70=0
    HAS_89=0

    for arch in "${ARCHS[@]}"; do
        case "$arch" in
            61) HAS_61=1 ;;
            70) HAS_70=1 ;;
            89) HAS_89=1 ;;
            *) die "Unsupported GPU architecture: sm_$arch" ;;
        esac
    done
}

# Select only known hardware combinations.
choose_engine() {
    detect_gpus

    [[ "$HAS_89" == 1 ]] ||
        die "Expected RTX 4070 (sm_89) is missing"

    if [[ "$HAS_61" == 1 && "$HAS_70" == 0 ]]; then
        SELECTED="$P40"
        LABEL="P40 + RTX 4070"
    elif [[ "$HAS_70" == 1 && "$HAS_61" == 0 ]]; then
        SELECTED="$V100"
        LABEL="V100 + RTX 4070"
    else
        die "Ambiguous GPU combination; no engine selected"
    fi

    [[ "${#ARCHS[@]}" -eq 2 ]] ||
        die "Unexpected number of GPU architectures"

    info "Selected configuration: $LABEL"
    info "Engine: $SELECTED"
}

# Check preserved binaries. Require native cubins for both GPUs.
check_binary() {
    local file="$1"
    shift

    [[ -f "$file" && -x "$file" ]] ||
        die "Missing or non-executable binary: $file"

    if ! command -v cuobjdump >/dev/null 2>&1; then
        info "WARNING: cuobjdump unavailable; cannot verify CUDA architectures"
        return
    fi

    local architectures
    architectures=$(cuobjdump --list-elf "$file" 2>/dev/null |
        grep -oE 'sm_[0-9]+' | sort -u || true)

    [[ -n "$architectures" ]] ||
        die "Could not inspect CUDA cubins in $file"

    local required
    for required in "$@"; do
        printf '%s\n' "$architectures" |
            grep -qx "sm_$required" ||
            die "$file lacks native sm_$required code"
    done

    info "Verified: $(basename "$file") supports sm_$(IFS=,; echo "$*")"
}

verify_all() {
    check_binary "$P40" 61 89
    check_binary "$V100" 70 89
}

# Do not replace the engine during active inference.
check_not_running() {
    if pgrep -u "$(id -u)" -x strata >/dev/null 2>&1; then
        die "A Strata engine process is running. Stop it first."
    fi
}

# Preserve known existing builds, without overwriting.
initialize() {
    check_not_running

    mkdir -p "$VERSIONS"

    [[ ! -L "$LIVE" ]] ||
        die "engine/strata is a symlink; resolve it manually before --init"

    if [[ ! -e "$P40" ]]; then
        [[ -f "$ENGINE_DIR/strata.backup-p40" ]] ||
            die "Missing original P40 backup"

        cp -a "$ENGINE_DIR/strata.backup-p40" "$P40"
        info "Preserved P40 binary"
    fi

    if [[ ! -e "$V100" ]]; then
        [[ -f "$LIVE" ]] ||
            die "Missing current engine; cannot initialize V100"

        # Guard against accidentally labelling a P40 engine as V100.
        check_binary "$LIVE" 70 89
        cp -a "$LIVE" "$V100"
        info "Preserved V100 binary"
    fi

    verify_all
    info "Initialization complete"
}

# Show current engine and available versions.
show_status() {
    choose_engine

    info "Preserved versions:"
    ls -lh "$P40" "$V100" 2>/dev/null || true

    if [[ -L "$LIVE" ]]; then
        info "Current engine is a symlink:"
        readlink "$LIVE"
    elif [[ -f "$LIVE" ]]; then
        info "Current engine:"
        ls -lh "$LIVE"

        local live_hash
        live_hash=$(sha256sum "$LIVE" | awk '{print $1}')

        for candidate in "$P40" "$V100"; do
            [[ -f "$candidate" ]] || continue
            if [[ "$live_hash" == "$(sha256sum "$candidate" | awk '{print $1}')" ]]; then
                info "Active version: $(basename "$candidate")"
                return
            fi
        done

        info "Active version: unknown/custom"
    else
        info "No active engine"
    fi
}

# Atomic replacement using a temporary file in engine/.
switch_engine() {
    choose_engine

    local required_arch
    if [[ "$SELECTED" == "$P40" ]]; then
        required_arch=61
    else
        required_arch=70
    fi

    check_binary "$SELECTED" "$required_arch" 89

    if [[ "$MODE" == "--dry-run" ]]; then
        info "DRY RUN: would activate $(basename "$SELECTED")"
        return
    fi

    check_not_running

    local selected_hash live_hash=""
    selected_hash=$(sha256sum "$SELECTED" | awk '{print $1}')

    if [[ -f "$LIVE" && ! -L "$LIVE" ]]; then
        live_hash=$(sha256sum "$LIVE" | awk '{print $1}')
    fi

    if [[ "$selected_hash" == "$live_hash" ]]; then
        info "Correct engine already active. No change needed."
        return
    fi

    local temp
    temp=$(mktemp "$ENGINE_DIR/.strata-switch.XXXXXXXX")

    trap 'rm -f -- "${temp:-}"' EXIT

    cp -a "$SELECTED" "$temp"
    chmod 755 "$temp"

    [[ "$(sha256sum "$temp" | awk '{print $1}')" == "$selected_hash" ]] ||
        die "Binary checksum mismatch during copy"

    # Same-directory rename is atomic on a normal local filesystem.
    mv -fT -- "$temp" "$LIVE"
    trap - EXIT

    info "Activated: $(basename "$SELECTED")"
    info "Ready to start Strata"
}

case "$MODE" in
    --init)    initialize ;;
    --status)  show_status ;;
    --verify)  verify_all ;;
    --dry-run) switch_engine ;;
    --switch)  switch_engine ;;
esac


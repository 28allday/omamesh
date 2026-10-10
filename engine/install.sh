#!/usr/bin/env bash
# Omamesh engine setup: installs img2mesh (TRELLIS.2 photo-to-3D) for this user.
#
#   omamesh-setup            set up, or update after a new Omamesh version
#   omamesh-setup --no-test  skip the test model at the end
#
# Everything lands in one folder: ~/.local/share/omamesh/engine when installed
# from the package, or beside this script in a writable checkout. It gets its
# own Python, GPU toolkit (CUDA for NVIDIA, ROCm for AMD) and compiler (no sudo,
# nothing in /usr). Re-running
# is safe: finished steps are skipped, so an interrupted setup carries on, and
# only what changed is redone after an update.
#
# Environment: IMG2MESH_HOME picks another folder; IMG2MESH_HF_HOME reuses a
# model cache elsewhere (the weights are ~17 GB); MAX_JOBS sets parallel
# compiler jobs for the GPU extensions.

set -eo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "Run omamesh-setup as yourself, not with sudo: the engine is set up per user." >&2
    exit 1
fi

CODE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# Same rule as bin/img2mesh: a read-only install keeps its data per user.
if [ -z "${IMG2MESH_HOME:-}" ]; then
    if [ -w "$CODE" ]; then
        IMG2MESH_HOME=$CODE
    else
        IMG2MESH_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/omamesh/engine"
    fi
fi
export IMG2MESH_HOME
mkdir -p "$IMG2MESH_HOME"
ROOT="$(cd "$IMG2MESH_HOME" && pwd)"
cd "$ROOT"
ENGINE="$CODE/bin/img2mesh"

MICROMAMBA_VERSION=2.9.0
CUDA_VERSION=12.8
TORCH_INDEX=https://download.pytorch.org/whl/cu128
MIN_DRIVER=570          # first driver series with CUDA 12.8 (and Blackwell)
MIN_VRAM_GB=16          # Draft and Standard verified on a 16 GB card
MIN_RAM_GB=24
MIN_DISK_GB=45          # toolchain ~17 GB, weights ~17 GB, build room

# AMD: PyTorch and the HIP compiler both come from AMD's per-family wheel index,
# so the compiler matches the HIP that torch was built with. Verified on an
# RX 9060 XT (gfx1200); the index also serves RDNA 3 (gfx110x).
ROCM_VERSION=7.13.0
ROCM_TORCH="torch==2.11.0+rocm$ROCM_VERSION torchvision==0.26.0+rocm$ROCM_VERSION"
ROCM_INDEX_BASE=https://repo.amd.com/rocm/whl
FLASH_ATTN_VERSION=2.8.3   # its Triton backend stands in for xformers on AMD
MIN_VRAM_GB_AMD=16

# Sources, pinned to the revisions this setup was verified with.
declare -A REPOS=(
    [TRELLIS.2]="https://github.com/microsoft/TRELLIS.2.git 75fbf01"
)
CUDA_REPOS=(
    "ext/nvdiffrast https://github.com/NVlabs/nvdiffrast.git 253ac4f"
    "ext/nvdiffrec https://github.com/JeffreyXiang/nvdiffrec.git b296927"
    "ext/CuMesh https://github.com/JeffreyXiang/CuMesh.git 12289e1"
    "ext/FlexGEMM https://github.com/JeffreyXiang/FlexGEMM.git 6dd94a8"
)
# HIP ports of the same extensions, by Cardboard-box-a. TRELLIS.2's own o-voxel
# builds for HIP as it is.
ROCM_REPOS=(
    "ext/nvdiffrast-hip https://github.com/Cardboard-box-a/nvdiffrast-hip.git d298923"
    "ext/nvdiffrec-rocm https://github.com/Cardboard-box-a/nvdiffrec.git a762ded"
    "ext/CuMesh-rocm https://github.com/Cardboard-box-a/CuMesh.git 2ef5f9d"
    "ext/FlexGEMM-rocm https://github.com/Cardboard-box-a/FlexGEMM-rocm.git 2a92675"
)

# The image encoder TRELLIS.2 uses is gated on Hugging Face (Meta's licence).
DINOV3=facebook/dinov3-vitl16-pretrain-lvd1689m

RUN_TEST=1
for arg in "$@"; do
    case $arg in
        --no-test) RUN_TEST=0 ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

export MAMBA_ROOT_PREFIX="$ROOT/tools/mamba"
export HF_HOME="${IMG2MESH_HF_HOME:-$ROOT/hf}"
export HF_TOKEN_PATH="${HF_TOKEN_PATH:-$HOME/.cache/huggingface/token}"
export HF_HUB_DISABLE_XET=1   # Xet downloads stall partway through large files
# Downloads and builds stage gigabytes of temporary files. Many distributions
# (Arch, Omarchy) keep /tmp in RAM, where that competes with everything else.
export TMPDIR="$ROOT/.tmp"
mkdir -p "$TMPDIR"
PY="$ROOT/env/bin/python"
STATE="$ROOT/.install-state"
ACCEL=""      # cuda or rocm, set by check_machine
GFX=""        # AMD compute target, e.g. gfx1200
LOG="$ROOT/install.log"

bold=$'\e[1m'; dim=$'\e[2m'; red=$'\e[31m'; green=$'\e[32m'; yellow=$'\e[33m'; off=$'\e[0m'
[ -t 1 ] || { bold=; dim=; red=; green=; yellow=; off=; }
step() { printf '\n%s==> %s%s\n' "$bold" "$*" "$off"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    %s! %s%s\n' "$yellow" "$*" "$off"; }
die()  { printf '\n%sxx %s%s\n' "$red" "$*" "$off" >&2; exit 1; }
done_before() { grep -qx "$1" "$STATE" 2>/dev/null; }
# Steps that depend on pinned inputs carry a fingerprint of them, so a newer
# Omamesh with different pins redoes just those steps.
fingerprint() { printf '%s\n' "$@" | sha256sum | cut -c1-12; }
mark_done() { echo "$1" >> "$STATE"; }
# Retries a network step a few times before giving up (big wheels and weights
# sometimes drop partway through; every tool used here resumes).
with_retries() {
    local attempt
    for attempt in 1 2 3; do
        "$@" && return 0
        [ "$attempt" -lt 3 ] && warn "Download interrupted; trying again ($((attempt + 1))/3)…" && sleep 10
    done
    return 1
}
# Long, noisy commands write to install.log; the screen keeps one line each.
quietly() {
    echo "### $*" >> "$LOG"
    if ! "$@" >> "$LOG" 2>&1; then
        tail -n 25 "$LOG" >&2
        die "That step failed. The full output is in $LOG"
    fi
}

# ---------------------------------------------------------------- checks
check_nvidia() {
    ACCEL=cuda
    local driver vram name
    IFS=, read -r name driver vram < <(nvidia-smi --query-gpu=name,driver_version,memory.total \
        --format=csv,noheader,nounits | head -1)
    driver=${driver// /}; vram=${vram// /}; name=${name# }
    info "GPU: $name, $(((vram + 512) / 1024)) GB, driver $driver"
    [ "${driver%%.*}" -ge "$MIN_DRIVER" ] \
        || die "The NVIDIA driver is too old ($driver). Version $MIN_DRIVER or newer is needed for CUDA $CUDA_VERSION."
    if [ "$vram" -lt $((MIN_VRAM_GB * 1024 - 512)) ]; then
        warn "This GPU has $(((vram + 512) / 1024)) GB. img2mesh is tested on ${MIN_VRAM_GB} GB; Draft quality may still work."
        confirm "Carry on anyway?" || exit 1
    fi
}

# The first AMD compute target the kernel publishes (gfx_target_version 120000
# is gfx1200), read from the amdgpu driver's KFD topology: no ROCm install needed.
amd_target() {
    local props v
    for props in /sys/class/kfd/kfd/topology/nodes/*/properties; do
        v=$(awk '$1 == "gfx_target_version" {print $2}' "$props" 2>/dev/null)
        [ -n "$v" ] && [ "$v" != 0 ] || continue
        printf 'gfx%d%d%x\n' $((v / 10000)) $((v / 100 % 100)) $((v % 100))
        return 0
    done
    return 1
}

check_amd() {
    ACCEL=rocm
    case $GFX in
        gfx120[01]) ROCM_INDEX="$ROCM_INDEX_BASE/gfx120X-all/" ;;
        gfx110[012]) ROCM_INDEX="$ROCM_INDEX_BASE/gfx110X-all/" ;;
        *) die "This AMD GPU ($GFX) isn't supported. img2mesh runs on Radeon RX 9000 (gfx1200/gfx1201)
    and RX 7000 (gfx1100-gfx1102) cards." ;;
    esac
    local vram=0 card v
    for card in /sys/class/drm/card*/device; do
        [ "$(cat "$card/vendor" 2>/dev/null)" = 0x1002 ] || continue
        v=$(cat "$card/mem_info_vram_total" 2>/dev/null || echo 0)
        [ "$v" -gt "$vram" ] && vram=$v
    done
    vram=$(((vram + 2**29) / 2**30))
    info "GPU: AMD Radeon ($GFX), ${vram} GB"
    [ "$GFX" = gfx1200 ] || info "${dim}AMD support was verified on gfx1200 (RX 9060 XT); $GFX uses the same ports.${off}"
    [ -r /dev/kfd ] && [ -w /dev/kfd ] \
        || die "Can't open /dev/kfd, which ROCm needs to reach the GPU. Add yourself to the
    render group (sudo usermod -aG render \$USER), log out and back in, and run this again."
    if [ "$vram" -lt "$MIN_VRAM_GB_AMD" ]; then
        warn "This GPU has ${vram} GB. img2mesh is tested on ${MIN_VRAM_GB_AMD} GB; Draft quality may still work."
        confirm "Carry on anyway?" || exit 1
    fi
    info "${dim}High quality needs a Radeon with 20 GB or more; Draft and Standard run on 16 GB.${off}"
}

check_machine() {
    step "Checking this machine"
    [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] \
        || die "img2mesh needs 64-bit Linux on x86_64."
    for tool in git curl tar bzip2; do
        command -v "$tool" >/dev/null || die "Please install '$tool' first."
    done

    local gpus
    gpus=$(lspci 2>/dev/null | grep -Ei 'vga|3d controller|display' || true)
    if command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; then
        check_nvidia  # NVIDIA keeps priority on a machine with both
    elif GFX=$(amd_target); then
        check_amd
    elif grep -qi 'nvidia' <<<"$gpus"; then
        die "There's an NVIDIA GPU but its driver isn't working (nvidia-smi failed).
    Install the NVIDIA driver (on Omarchy/Arch: the nvidia-open package), reboot, and run this again."
    elif grep -Eqi 'amd|ati|radeon' <<<"$gpus"; then
        die "This machine has an AMD GPU, but the kernel publishes no compute target for it
    (nothing in /sys/class/kfd). img2mesh needs a Radeon RX 7000 or 9000 series card
    with the amdgpu driver."
    elif grep -qi 'intel' <<<"$gpus"; then
        die "This machine has Intel graphics. img2mesh needs an NVIDIA or AMD Radeon GPU:
    there is no Intel (XPU) version of TRELLIS.2's GPU parts yet."
    else
        die "No supported GPU found. img2mesh needs an NVIDIA GPU or an AMD Radeon RX 7000/9000
    with ${MIN_VRAM_GB} GB of memory."
    fi
    echo "$ACCEL" > "$ROOT/accelerator.new"
    if [ -f "$ROOT/accelerator" ] && ! cmp -s "$ROOT/accelerator" "$ROOT/accelerator.new"; then
        # Moved to another make of GPU: rebuild the toolchain, keep the weights.
        warn "This engine was set up for $(cat "$ROOT/accelerator"); setting it up again for $ACCEL."
        grep -xE 'weights|hf-access' "$STATE" > "$STATE.new" 2>/dev/null || true
        mv "$STATE.new" "$STATE"
    fi
    mv "$ROOT/accelerator.new" "$ROOT/accelerator"

    local ram_gb disk_gb
    ram_gb=$(awk '/MemTotal/ {print int($2 / 1048576 + 0.5)}' /proc/meminfo)
    disk_gb=$(df --output=avail -BG "$ROOT" | tail -1 | tr -dc 0-9)
    info "RAM: ${ram_gb} GB, free disk here: ${disk_gb} GB"
    [ "$ram_gb" -ge "$MIN_RAM_GB" ] || warn "Less than ${MIN_RAM_GB} GB of RAM: Standard and High quality may run out of memory."
    if ! done_before weights && [ "$disk_gb" -lt "$MIN_DISK_GB" ]; then
        die "Needs about ${MIN_DISK_GB} GB of free disk space here; there's ${disk_gb} GB."
    fi
}

confirm() {
    local answer
    [ -t 0 ] || return 1
    read -r -p "    $1 [y/N] " answer
    [[ $answer =~ ^[Yy] ]]
}

# ---------------------------------------------------------------- toolchain
install_micromamba() {
    [ -x tools/bin/micromamba ] && return
    step "Fetching micromamba $MICROMAMBA_VERSION (package manager)"
    mkdir -p tools
    curl -fsSL "https://github.com/mamba-org/micromamba-releases/releases/download/$MICROMAMBA_VERSION-0/micromamba-linux-64" \
        -o tools/micromamba.tmp
    mkdir -p tools/bin
    mv tools/micromamba.tmp tools/bin/micromamba
    chmod +x tools/bin/micromamba
}

make_env() {
    rm -rf "$ROOT/env"
    # On AMD the HIP toolchain arrives with PyTorch (install_packages).
    local toolkit=("cuda-toolkit=$CUDA_VERSION")
    [ "$ACCEL" = rocm ] && toolkit=()
    tools/bin/micromamba create -y -p "$ROOT/env" -c conda-forge \
        python=3.11 "${toolkit[@]}" gcc=13 gxx=13 ninja git cmake libjpeg-turbo
}

create_env() {
    done_before env && return
    if [ "$ACCEL" = rocm ]; then
        step "Creating the Python 3.11 environment with gcc 13"
    else
        step "Creating the Python 3.11 environment with CUDA $CUDA_VERSION and gcc 13"
    fi
    info "${dim}downloads ~3 GB; a few minutes${off}"
    quietly with_retries make_env
    mark_done env
}

install_packages() {
    local key; key="packages-$(fingerprint "$(cat "$CODE/requirements.lock")" "$ACCEL" \
        "$ROCM_TORCH" "$FLASH_ATTN_VERSION")"
    done_before "$key" && return
    step "Installing PyTorch and the Python packages"
    info "${dim}downloads ~5 GB${off}"
    quietly with_retries "$PY" -m pip install --upgrade pip setuptools wheel
    if [ "$ACCEL" = rocm ]; then
        install_rocm_packages
        mark_done "$key"
        return
    fi
    # Only PyTorch itself comes from PyTorch's index; its CUDA libraries and
    # everything else come from PyPI (PyTorch's index sends those to NVIDIA's
    # server, which keeps cutting the 650 MB cuDNN download partway).
    local torch_pins rest
    torch_pins=$(grep -E '^(torch|torchvision)==' "$CODE/requirements.lock")
    rest="$ROOT/.requirements-pypi.txt"
    grep -vE '^(torch|torchvision)==' "$CODE/requirements.lock" > "$rest"
    # shellcheck disable=SC2086  # one pin per word
    quietly with_retries "$PY" -m pip install --resume-retries 30 --no-deps \
        --index-url "$TORCH_INDEX" $torch_pins
    quietly with_retries "$PY" -m pip install --resume-retries 30 -r "$rest"
    rm -f "$rest"
    mark_done "$key"
}

install_rocm_packages() {
    # PyTorch for ROCm and the matching HIP SDK (compiler, headers) from AMD's
    # index for this GPU family; the runtime ships inside the wheels.
    # shellcheck disable=SC2086  # one pin per word
    quietly with_retries "$PY" -m pip install --resume-retries 30 \
        --index-url "$ROCM_INDEX" --extra-index-url https://pypi.org/simple \
        $ROCM_TORCH "rocm[libraries,devel]==$ROCM_VERSION"
    # The lock's CUDA-only packages (and PyPI's CUDA Triton) stay out.
    local rest="$ROOT/.requirements-pypi.txt"
    grep -vE '^(torch|torchvision|xformers|triton)==|^(cuda|nvidia)-' "$CODE/requirements.lock" > "$rest"
    quietly with_retries "$PY" -m pip install --resume-retries 30 -r "$rest"
    rm -f "$rest"
    local sdk; sdk=$("$ROOT/env/bin/rocm-sdk" path --root)
    quietly with_retries env FLASH_ATTENTION_TRITON_AMD_ENABLE=TRUE ROCM_PATH="$sdk" ROCM_HOME="$sdk" \
        PATH="$sdk/bin:$ROOT/env/bin:$PATH" \
        "$PY" -m pip install --no-build-isolation "flash-attn==$FLASH_ATTN_VERSION"
}

# The GPU extensions differ by vendor; TRELLIS.2 itself is the same.
add_gpu_sources() {
    local entry dir url rev list=("${CUDA_REPOS[@]}")
    [ "$ACCEL" = rocm ] && list=("${ROCM_REPOS[@]}")
    for entry in "${list[@]}"; do
        read -r dir url rev <<<"$entry"
        REPOS[$dir]="$url $rev"
    done
}

sources_key() {
    local dir; for dir in "${!REPOS[@]}"; do echo "$dir ${REPOS[$dir]}"; done | sort
}

fetch_sources() {
    local key; key="sources-$(fingerprint "$(sources_key)")"
    done_before "$key" && return
    step "Fetching TRELLIS.2 and its GPU extensions"
    local dir url rev
    for dir in "${!REPOS[@]}"; do
        read -r url rev <<<"${REPOS[$dir]}"
        if [ ! -d "$dir/.git" ]; then
            info "$dir"
            quietly with_retries git clone --quiet "$url" "$dir"
        elif ! git -C "$dir" cat-file -e "$rev^{commit}" 2>/dev/null; then
            quietly with_retries git -C "$dir" fetch --quiet origin
        fi
        quietly git -C "$dir" checkout --quiet "$rev"
        quietly git -C "$dir" submodule update --init --recursive --quiet
    done
    mark_done "$key"
}

build_extensions() {
    local key; key="extensions-$(fingerprint "$(sources_key)" "$(cat "$CODE/requirements.lock")")"
    done_before "$key" && return
    step "Compiling the GPU extensions for this card"
    info "${dim}10-20 minutes; progress goes to install.log${off}"
    local ram_gb jobs cap
    ram_gb=$(awk '/MemTotal/ {print int($2 / 1048576)}' /proc/meminfo)
    # nvcc takes 2-3 GB per job; keep the desktop usable meanwhile.
    jobs=${MAX_JOBS:-$(( ram_gb >= 48 ? 4 : 2 ))}
    cap=$(( ram_gb / 2 < 8 ? ram_gb / 2 : 8 ))
    local runner=()
    if command -v systemd-run >/dev/null && systemd-run --user --scope -q true 2>/dev/null; then
        runner=(systemd-run --user --scope -q -p "MemoryMax=${cap}G")
    fi
    export MAX_JOBS=$jobs
    quietly "${runner[@]}" bash "$CODE/build-ext.sh"
    mark_done "$key"
}

# ---------------------------------------------------------------- weights
hf_access() {
    "$PY" - "$1" <<'EOF'
import sys
from huggingface_hub import auth_check
from huggingface_hub.utils import GatedRepoError, RepositoryNotFoundError
try:
    auth_check(sys.argv[1])
except GatedRepoError:
    sys.exit(3)
except RepositoryNotFoundError:
    sys.exit(4)
except Exception as e:
    print(e, file=sys.stderr)
    sys.exit(5)
EOF
}

hugging_face_access() {
    done_before hf-access && return
    step "Hugging Face access"
    info "One of the models TRELLIS.2 uses (Meta's DINOv3 image encoder) is free but"
    info "gated: Hugging Face needs you to accept its licence once, from an account."
    local status
    while true; do
        if [ ! -s "$HF_TOKEN_PATH" ]; then
            echo
            info "1. Sign in or sign up at ${bold}https://huggingface.co/join${off}"
            info "2. Accept the licence at ${bold}https://huggingface.co/$DINOV3${off}"
            info "3. Make a 'Read' token at ${bold}https://huggingface.co/settings/tokens${off}"
            [ -t 0 ] || die "Run this in a terminal to paste the token."
            local token
            read -r -s -p "    Paste the token here (it won't show): " token; echo
            [ -n "$token" ] || continue
            mkdir -p "$(dirname "$HF_TOKEN_PATH")"
            ( umask 077; printf '%s' "$token" > "$HF_TOKEN_PATH" )
        fi
        status=0; hf_access "$DINOV3" 2>>"$LOG" || status=$?
        case $status in
            0) info "${green}Access to DINOv3 confirmed.${off}"; break ;;
            3) warn "The token works, but the DINOv3 licence isn't accepted yet (or is still pending)."
               info "Accept it at https://huggingface.co/$DINOV3 — approval is usually quick."
               [ -t 0 ] || exit 1
               read -r -p "    Press Enter to check again, or Ctrl+C to stop and re-run later. " ;;
            *) warn "Hugging Face didn't accept that token."
               rm -f "$HF_TOKEN_PATH" ;;
        esac
    done
    mark_done hf-access
}

download_weights() {
    done_before weights && return
    step "Downloading the model weights (~17 GB)"
    info "${dim}into $HF_HOME; resumes if interrupted${off}"
    quietly with_retries "$ENGINE" --download
    mark_done weights
}

# ---------------------------------------------------------------- finish
link_command() {
    # A model cache kept elsewhere: point ./hf at it so bin/img2mesh finds it.
    if [ "$HF_HOME" != "$ROOT/hf" ] && [ ! -e "$ROOT/hf" ]; then
        ln -s "$HF_HOME" "$ROOT/hf"
    fi
    # The package puts img2mesh in /usr/bin; a checkout links its own.
    [ -w "$CODE" ] || return 0
    mkdir -p "$HOME/.local/bin"
    ln -sfn "$ENGINE" "$HOME/.local/bin/img2mesh"
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) warn "$HOME/.local/bin isn't on your PATH; add it to run 'img2mesh' from anywhere." ;;
    esac
}

smoke_test() {
    [ "$RUN_TEST" = 1 ] || return 0
    done_before tested && return
    step "Making a test model (Draft quality, about 2 minutes the first time)"
    local samples=(TRELLIS.2/assets/example_image/*.webp) sample out
    sample=${samples[0]}  # (ls | head would SIGPIPE under pipefail)
    out="$ROOT/test-output"
    mkdir -p "$out"
    quietly "$ENGINE" -q draft -o "$out" "$sample"
    local made=("$out"/*.glb)
    [ -f "${made[0]}" ] || die "The test ran but wrote no model; see $LOG"
    info "${green}Wrote ${made[0]}${off}"
    mark_done tested
}

main() {
    printf '%sOmamesh engine setup%s — TRELLIS.2 photo-to-3D, on this computer\n' "$bold" "$off"
    info "${dim}Installing into $ROOT${off}"
    echo "=== $(date -Is) install.sh $*" >> "$LOG"
    if ! done_before env; then
        echo
        info "TRELLIS.2 bakes textures with NVIDIA's nvdiffrast, whose licence allows"
        info "${bold}non-commercial use only${off} (research or evaluation). Omamesh's README lists every licence."
    fi
    check_machine
    add_gpu_sources
    install_micromamba
    create_env
    install_packages
    fetch_sources
    build_extensions
    hugging_face_access
    download_weights
    link_command
    smoke_test
    rm -rf "$TMPDIR"
    step "${green}Done.${off}"
    info "Open Omamesh from the app launcher and drop a photo in, or from a terminal:"
    info "  img2mesh photo.jpg        (writes photo.glb beside it; img2mesh --help for more)"
    info "The engine lives in $ROOT"
}

main "$@"

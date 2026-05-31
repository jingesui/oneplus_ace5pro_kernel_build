#!/usr/bin/env bash
# build_common.sh — shared build logic, sourced by build_android{15,16}.sh
# Do not run directly.

WORKSPACE="$SCRIPT_DIR/kernel_workspace"
PLATFORM_DIR="$WORKSPACE/kernel_platform"
KERNEL_DIR="$PLATFORM_DIR/common"
OUT_DIR="$KERNEL_DIR/out"
MODULES_DIR="$WORKSPACE/modules_and_devicetree"

# ── Source repos (forks from OnePlusOSS) ─────────────────────
COMMON_REPO="https://github.com/s1lently/android_kernel_common_oneplus_sm8750"
MSM_REPO="https://github.com/s1lently/android_kernel_oneplus_sm8750"
MODULES_REPO="https://github.com/s1lently/android_kernel_modules_and_devicetree_oneplus_sm8750"
CLANG_ARM64_URL="https://github.com/s1lently/llvm-project/releases/download/r510928-arm64/aosp-clang-r510928-arm64-kernel.tar.gz"
CLANG_X86_64_URL="https://github.com/s1lently/llvm-project/releases/download/r510928-arm64/aosp-clang-r510928-x86_64-kernel.tar.gz"

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[build]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
die()  { echo -e "${RED}[error]${NC} $*"; exit 1; }

clone_if_missing() {
    local repo="$1" dest="$2" branch="$3"
    if [[ ! -d "$dest/.git" ]]; then
        log "Cloning $(basename "$dest") @ $branch ..."
        git clone --depth 1 -b "$branch" "$repo" "$dest" 2>&1 | tail -1
    else
        log "$(basename "$dest") already exists, skipping"
    fi
}

do_build() {
    # ── 单核编译，防止 OOM ──────────────────────────────────
    local JOBS=1
    local ARCH=$(uname -m)

    log "=== OnePlus Ace 5 Pro Kernel Build ==="
    log "Branch: $BRANCH"
    log "Host: $(uname -s) $ARCH, $JOBS cores"

    # ── Platform detection ────────────────────────────────────
    local PLATFORM="x86_64"
    if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        PLATFORM="arm64"
    fi

    # ── Dependencies ──────────────────────────────────────────
    local MISSING=()
    for cmd in make bc flex bison cpio gcc g++ curl git; do
        command -v $cmd &>/dev/null || MISSING+=("$cmd")
    done
    if ! pahole --version &>/dev/null; then
        MISSING+=("pahole")
    fi
    if [[ ${#MISSING[@]} -gt 0 ]]; then
        log "Installing: ${MISSING[*]}"
        if command -v apt-get &>/dev/null; then
            local SUDO=""
            [[ $(id -u) -ne 0 ]] && SUDO="sudo"
            $SUDO apt-get update -qq && $SUDO apt-get install -y -qq \
                build-essential bc flex bison cpio dwarves libssl-dev libelf-dev python3 curl git 2>&1 | tail -1
        else
            die "Missing: ${MISSING[*]}. Install manually."
        fi
    fi

    # ── 8 GB Swap 防 OOM（独立命名，避免冲突） ──────────────
    local SWAPFILE="/swapfile_kbuild"
    if ! swapon --show | grep -q "$SWAPFILE"; then
        log "Creating 8 GB swap at $SWAPFILE..."
        local SUDO=""
        [[ $(id -u) -ne 0 ]] && SUDO="sudo"
        if [[ ! -f "$SWAPFILE" ]]; then
            $SUDO fallocate -l 8G "$SWAPFILE" || $SUDO dd if=/dev/zero of="$SWAPFILE" bs=1M count=8192
            $SUDO chmod 600 "$SWAPFILE"
        fi
        $SUDO mkswap "$SWAPFILE" >/dev/null
        $SUDO swapon "$SWAPFILE"
        log "✓ Swap enabled ($SWAPFILE)"
    else
        log "Swap already active at $SWAPFILE, skipping"
    fi

    # ── Clone sources ─────────────────────────────────────────
    mkdir -p "$PLATFORM_DIR"
    clone_if_missing "$COMMON_REPO"  "$KERNEL_DIR"               "$BRANCH"
    clone_if_missing "$MSM_REPO"     "$PLATFORM_DIR/msm-kernel"  "$BRANCH"
    clone_if_missing "$MODULES_REPO" "$MODULES_DIR"              "$BRANCH"

    # ── 彻底禁止 git 版本检测：删除内核源码树中的 .git ─────
    if [[ -d "$KERNEL_DIR/.git" ]]; then
        log "Removing .git to prevent auto localversion suffix..."
        rm -rf "$KERNEL_DIR/.git"
    fi

    # ── Download & Apply Fengchi scheduler patch ─────────────
    local PATCH_URL="https://raw.githubusercontent.com/Numbersf/SCHED_PATCH/sm8750/fengchi_oneplus_ace5_pro_b.patch"
    local PATCH_FILE="/tmp/fengchi_oneplus_ace5_pro_b.patch"
    log "Downloading Fengchi patch..."
    if curl -sL "$PATCH_URL" -o "$PATCH_FILE"; then
        cd "$KERNEL_DIR" || die "Cannot enter kernel source dir"
        if patch --dry-run -p1 < "$PATCH_FILE" &>/dev/null; then
            patch -p1 < "$PATCH_FILE"
            log "✓ Patch applied successfully"
        else
            warn "Patch may already be applied or has conflicts; attempting --forward force"
            patch -p1 --forward --no-backup-if-mismatch < "$PATCH_FILE" || \
                warn "Patch failed (possibly already applied, continuing)"
        fi
        cd - > /dev/null
        rm -f "$PATCH_FILE"
    else
        warn "Failed to download Fengchi patch, skipping"
    fi

    # ── Toolchain ─────────────────────────────────────────────
    local AOSP_CLANG="$HOME/aosp-clang-r510928/bin"
    local PAHOLE_CMD="pahole"

    if [[ ! -f "$AOSP_CLANG/clang" ]]; then
        local CLANG_URL
        if [[ "$PLATFORM" == "arm64" ]]; then
            CLANG_URL="$CLANG_ARM64_URL"
        else
            CLANG_URL="$CLANG_X86_64_URL"
        fi
        log "Downloading $PLATFORM Clang..."
        curl -L "$CLANG_URL" -o /tmp/aosp-clang.tar.gz
        rm -rf "$HOME/aosp-clang-r510928" "$HOME/clang-kernel-only"
        tar xzf /tmp/aosp-clang.tar.gz -C "$HOME"
        mv "$HOME/clang-kernel-only" "$HOME/aosp-clang-r510928"
        rm -f /tmp/aosp-clang.tar.gz
        log "✓ Clang installed"
    fi
    export PATH="$AOSP_CLANG:$PATH"

    log "Clang: $(clang --version | head -1)"

    # ── Extract stock defconfig ───────────────────────────────
    local DEFCONFIG="$KERNEL_DIR/arch/arm64/configs/gki_defconfig"
    if [[ ! -f "$DEFCONFIG" ]]; then
        die "gki_defconfig not found at $DEFCONFIG"
    fi

    # ── Configure ─────────────────────────────────────────────
    log "Configuring..."
    rm -rf "$OUT_DIR"
    mkdir -p "$OUT_DIR"
    cp "$DEFCONFIG" "$OUT_DIR/.config"

    # Patch config using scripts/config (more reliable than sed)
    cd "$KERNEL_DIR" || die
    scripts/config --file "$OUT_DIR/.config" --set-str CONFIG_LOCALVERSION "$LOCALVERSION"
    scripts/config --file "$OUT_DIR/.config" --disable CONFIG_LOCALVERSION_AUTO
    scripts/config --file "$OUT_DIR/.config" --disable CONFIG_TRIM_UNUSED_KSYMS
    scripts/config --file "$OUT_DIR/.config" --disable CONFIG_MODULE_SIG_PROTECT
    scripts/config --file "$OUT_DIR/.config" --disable CONFIG_MODULE_SCMVERSION
    cd - > /dev/null

    # Remove any stale UNUSED_KSYMS_WHITELIST entries
    sed -i '/CONFIG_UNUSED_KSYMS_WHITELIST/d' "$OUT_DIR/.config"

    # ── Append DroidSpaces required configs ──────────────────
    log "Appending DroidSpaces kernel configs..."
    cat >> "$OUT_DIR/.config" << 'EOF'
CONFIG_SYSVIPC=y
CONFIG_POSIX_MQUEUE=y
CONFIG_IPC_NS=y
CONFIG_PID_NS=y
CONFIG_DEVTMPFS=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_TARGET_REJECT=y
CONFIG_NETFILTER_XT_TARGET_LOG=y
CONFIG_NETFILTER_XT_MATCH_RECENT=y
CONFIG_IP_SET=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_NETFILTER_XT_SET=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_TMPFS_XATTR=y
EOF

    make -j"$JOBS" LLVM=1 ARCH=arm64 CC=clang LD=ld.lld HOSTLD=ld.lld \
        PAHOLE="$PAHOLE_CMD" O=out -C "$KERNEL_DIR" olddefconfig

    # ── Build ─────────────────────────────────────────────────
    log "Building with $JOBS threads..."
    make -j"$JOBS" LLVM=1 ARCH=arm64 CC=clang LD=ld.lld HOSTLD=ld.lld \
        PAHOLE="$PAHOLE_CMD" O=out -C "$KERNEL_DIR" \
        ${EXTRA_KCFLAGS:+KCFLAGS="$EXTRA_KCFLAGS"} all

    local IMAGE="$OUT_DIR/arch/arm64/boot/Image"
    [[ -f "$IMAGE" ]] || die "Build failed: Image not generated"
    local SIZE=$(du -sh "$IMAGE" | cut -f1)
    log "✓ Image: $IMAGE ($SIZE)"
    log "vermagic: $(strings "$IMAGE" | grep 'Linux version' | head -1)"
}
#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$HOME/src/erofs-utils"

echo "[*] Installing build dependencies..."
sudo pacman -S --needed \
    base-devel \
    git \
    autoconf \
    automake \
    libtool \
    pkgconf \
    make \
    gcc

if ! command -v paru >/dev/null 2>&1; then
    echo "[!] paru is required but was not found."
    exit 1
fi

echo "[*] Installing SELinux libraries..."
paru -S --needed --noconfirm libselinux libsepol

if [ ! -d "$REPO_DIR/.git" ]; then
    echo "[*] Cloning erofs-utils..."
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone https://git.kernel.org/pub/scm/linux/kernel/git/xiang/erofs-utils.git "$REPO_DIR"
else
    echo "[*] Updating erofs-utils..."
    git -C "$REPO_DIR" pull --ff-only
fi

cd "$REPO_DIR"

echo "[*] Cleaning previous build..."
make distclean >/dev/null 2>&1 || true
git clean -fdx

echo "[*] Generating configure script..."
./autogen.sh

echo "[*] Configuring with SELinux support..."
./configure --with-selinux=yes

echo "[*] Building..."
make -j"$(nproc)"

echo "[*] Installing mkfs.erofs..."
sudo install -Dm755 mkfs/mkfs.erofs /usr/local/bin/mkfs.erofs

echo
echo "[*] Installed binary:"
which mkfs.erofs

echo
echo "[*] Checking SELinux support..."

if mkfs.erofs --help | grep -q -- '--file-contexts'; then
    echo
    echo "[✓] SUCCESS!"
    echo "mkfs.erofs supports --file-contexts"
else
    echo
    echo "[✗] ERROR: SELinux support is missing."
    exit 1
fi

#!/usr/bin/env bash
# gen_vendor_dlkm.sh — Generate vendor_dlkm.tar.xz + vendor_dlkm.img for OP9 (lemonade)
# Adapted from YAKB/main.sh for OnePlus 9 / SM8350
#
# Each run creates /op9/code/temp/vendor_dlkm_files_{timestamp}/
# containing extracted files, .tar.xz, and .img — never cleaned.

set -euo pipefail

# ──────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────

KDIR="/home/tony/op9/code/Levion_kernel_OP9"
BUILD_MODULES_DIR="${KDIR}/out/modules"
STOCK_IMG="/home/tony/op9/code/vendor_dlkm.img"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
TEMP_DIR="/home/tony/op9/code/temp"
RUN_DIR="${TEMP_DIR}/vendor_dlkm_files_${TIMESTAMP}"

# ──────────────────────────────────────────────────────────────
# Step 1: Create run directory
# ──────────────────────────────────────────────────────────────

mkdir -p "${RUN_DIR}"
echo -e "\e[1;93m[*] Output directory: ${RUN_DIR}\e[0m"

# ──────────────────────────────────────────────────────────────
# Step 2: Extract stock vendor_dlkm.img
# ──────────────────────────────────────────────────────────────

if [ ! -f "${STOCK_IMG}" ]; then
    echo -e "\e[1;31m[✗] Stock image not found: ${STOCK_IMG}\e[0m"
    exit 1
fi

EXTRACT_DIR="${RUN_DIR}/extracted"
mkdir -p "${EXTRACT_DIR}"

echo -e "\e[1;93m[*] Extracting stock vendor_dlkm.img...\e[0m"
fsck.erofs --extract="${EXTRACT_DIR}" --overwrite "${STOCK_IMG}" 2>&1
echo -e "\e[1;32m[✓] Extracted stock image\e[0m"

MODULES_DIR="${EXTRACT_DIR}/lib/modules"

STOCK_KO_COUNT=$(find "${MODULES_DIR}" -name "*.ko" | wc -l)
echo -e "\e[1;93m    Stock has ${STOCK_KO_COUNT} modules\e[0m"

# Derive exclude set from stock BEFORE replacing modules:
# stock total .ko - stock modules.load - stock blocklist = modules that should never load
declare -A STOCK_LOAD_SET
while IFS= read -r entry; do
    [ -z "${entry}" ] && continue
    STOCK_LOAD_SET["${entry}"]=1
done < "${MODULES_DIR}/modules.load"

declare -A BLOCKLIST_SET
if [ -f "${MODULES_DIR}/modules.blocklist" ]; then
    while read -r _ mod; do
        [ -n "${mod}" ] && BLOCKLIST_SET["${mod}"]=1
    done < <(grep '^blocklist ' "${MODULES_DIR}/modules.blocklist" || true)
fi

declare -A EXCLUDE_SET
for ko in "${MODULES_DIR}"/*.ko; do
    mod_name=$(basename "${ko}" .ko)
    if [ -z "${STOCK_LOAD_SET[${mod_name}]+x}" ] && [ -z "${BLOCKLIST_SET[${mod_name}]+x}" ]; then
        EXCLUDE_SET["${mod_name}"]=1
    fi
done

echo -e "\e[1;93m    Derived ${#EXCLUDE_SET[@]} excluded modules: ${!EXCLUDE_SET[*]}\e[0m"

# ──────────────────────────────────────────────────────────────
# Step 3: Validate build output
# ──────────────────────────────────────────────────────────────

if [ ! -d "${BUILD_MODULES_DIR}" ]; then
    echo -e "\e[1;31m[✗] No modules_install output at ${BUILD_MODULES_DIR}\e[0m"
    echo "    Run: make O=out ... INSTALL_MOD_PATH=out/modules modules_install"
    exit 1
fi

BUILD_KO_COUNT=$(find "${BUILD_MODULES_DIR}" -type f -name "*.ko" | wc -l)
if [ "${BUILD_KO_COUNT}" -eq 0 ]; then
    echo -e "\e[1;31m[✗] No .ko files found in ${BUILD_MODULES_DIR}\e[0m"
    exit 1
fi

echo -e "\e[1;93m[*] Found ${BUILD_KO_COUNT} built modules\e[0m"

# ──────────────────────────────────────────────────────────────
# Step 4: Replace stock modules with built ones
# ──────────────────────────────────────────────────────────────

echo -e "\e[1;93m[*] Removing stock .ko files...\e[0m"
rm -f "${MODULES_DIR}"/*.ko

echo -e "\e[1;93m[*] Copying built modules...\e[0m"
find "${BUILD_MODULES_DIR}" -type f -name "*.ko" | while read -r ko; do
    cp -p "${ko}" "${MODULES_DIR}/"
done

NEW_KO_COUNT=$(find "${MODULES_DIR}" -name "*.ko" | wc -l)
echo -e "\e[1;32m[✓] Replaced with ${NEW_KO_COUNT} built modules\e[0m"

# ──────────────────────────────────────────────────────────────
# Step 5: Rename wlan.ko → qca_cld3_wlan.ko (before strip/depmod)
# ──────────────────────────────────────────────────────────────

if [ -f "${MODULES_DIR}/wlan.ko" ]; then
    mv "${MODULES_DIR}/wlan.ko" "${MODULES_DIR}/qca_cld3_wlan.ko"
    echo -e "\e[1;32m[✓] Renamed wlan.ko → qca_cld3_wlan.ko\e[0m"
fi

# ──────────────────────────────────────────────────────────────
# Step 6: Strip debug symbols
# ──────────────────────────────────────────────────────────────

if command -v llvm-objcopy &>/dev/null; then
    echo -e "\e[1;93m[*] Stripping debug symbols...\e[0m"
    for ko in "${MODULES_DIR}"/*.ko; do
        llvm-objcopy --strip-debug "${ko}"
    done
    echo -e "\e[1;32m[✓] Stripped debug symbols\e[0m"
else
    echo -e "\e[1;31m[!] llvm-objcopy not in PATH, skipping strip\e[0m"
fi

# ──────────────────────────────────────────────────────────────
# Step 6: Run depmod
# ──────────────────────────────────────────────────────────────

echo -e "\e[1;93m[*] Running depmod...\e[0m"

DEPMOD_STAGING="${RUN_DIR}/depmod_staging"
DEPMOD_VER="0.0"
DEPMOD_MOD_DIR="${DEPMOD_STAGING}/lib/modules/${DEPMOD_VER}"
mkdir -p "${DEPMOD_MOD_DIR}"

# Copy .ko into depmod staging
cp -p "${MODULES_DIR}"/*.ko "${DEPMOD_MOD_DIR}"/

# Create empty placeholder files to suppress warnings
touch "${DEPMOD_MOD_DIR}/modules.order"
touch "${DEPMOD_MOD_DIR}/modules.builtin"
touch "${DEPMOD_MOD_DIR}/modules.builtin.modinfo"

# Run depmod
depmod -a -b "${DEPMOD_STAGING}" "${DEPMOD_VER}"

# Copy generated depmod files back
for f in modules.alias modules.dep modules.softdep; do
    if [ -f "${DEPMOD_MOD_DIR}/${f}" ]; then
        cp -p "${DEPMOD_MOD_DIR}/${f}" "${MODULES_DIR}/"
    fi
done

echo -e "\e[1;32m[✓] depmod complete\e[0m"

# ──────────────────────────────────────────────────────────────
# Step 7: Fix paths in modules.dep
# ──────────────────────────────────────────────────────────────

echo -e "\e[1;93m[*] Fixing module paths in modules.dep...\e[0m"

sed -i 's|[^ :]*lib/modules/[^/]*/||g' "${MODULES_DIR}/modules.dep"
sed -i 's|\([a-zA-Z0-9_.-]*\.ko\)|/vendor_dlkm/lib/modules/\1|g' "${MODULES_DIR}/modules.dep"

echo -e "\e[1;32m[✓] Paths fixed\e[0m"

# ──────────────────────────────────────────────────────────────
# Step 8: modules.load — generated from present .ko files
# ──────────────────────────────────────────────────────────────

echo -e "\e[1;93m[*] Generating modules.load...\e[0m"

# Generate modules.load: all present .ko - exclude set - blocklist
: > "${MODULES_DIR}/modules.load"
for ko in "${MODULES_DIR}"/*.ko; do
    mod_name=$(basename "${ko}" .ko)
    if [ -z "${EXCLUDE_SET[${mod_name}]+x}" ] && [ -z "${BLOCKLIST_SET[${mod_name}]+x}" ]; then
        echo "${mod_name}" >> "${MODULES_DIR}/modules.load"
    fi
done

LOAD_COUNT=$(wc -l < "${MODULES_DIR}/modules.load")
echo -e "\e[1;32m[✓] modules.load: ${LOAD_COUNT} entries (${#EXCLUDE_SET[@]} excluded, ${#BLOCKLIST_SET[@]} blocklisted)\e[0m"

# ──────────────────────────────────────────────────────────────
# Step 9: modules.blocklist — kept from stock (preserved)
# ──────────────────────────────────────────────────────────────

echo -e "\e[1;32m[✓] modules.blocklist: preserved from stock\e[0m"

# ──────────────────────────────────────────────────────────────
# Step 10: Create vendor_dlkm.tar.xz
# ──────────────────────────────────────────────────────────────

OUT_TAR="${RUN_DIR}/vendor_dlkm_${TIMESTAMP}.tar.xz"

echo -e "\e[1;93m[*] Creating tarball...\e[0m"

tar -cpf - -C "${EXTRACT_DIR}" lib/ | xz -9e -T0 >"${OUT_TAR}"

TAR_SIZE=$(du -sh "${OUT_TAR}" | cut -f1)
echo -e "\e[1;32m[✓] Created ${OUT_TAR} (${TAR_SIZE})\e[0m"

# ──────────────────────────────────────────────────────────────
# Step 11: Build vendor_dlkm.img (EROFS)
# ──────────────────────────────────────────────────────────────

OUT_IMG="${RUN_DIR}/vendor_dlkm_${TIMESTAMP}.img"

echo -e "\e[1;93m[*] Building EROFS vendor_dlkm image...\e[0m"

FILE_CONTEXTS="${RUN_DIR}/file_contexts"
cat <<'EOF' >"${FILE_CONTEXTS}"
/ u:object_r:vendor_file:s0
/vendor_dlkm(/.*)? u:object_r:vendor_file:s0
/vendor_dlkm/etc(/.*)? u:object_r:vendor_configs_file:s0
EOF

mkfs.erofs \
    --mount-point=/vendor_dlkm \
    --all-root \
    --file-contexts="${FILE_CONTEXTS}" \
    -zlz4 \
    -b4096 \
    -T1230768000 \
    "${OUT_IMG}" \
    "${EXTRACT_DIR}"

# Check size against original partition
ORIG_SIZE=$(stat --format="%s" "${STOCK_IMG}")
NEW_SIZE=$(stat --format="%s" "${OUT_IMG}")

if [ "${NEW_SIZE}" -le "${ORIG_SIZE}" ]; then
    echo -e "\e[1;93m[*] Padding image to match partition size (${ORIG_SIZE} bytes)...\e[0m"
    truncate -s "${ORIG_SIZE}" "${OUT_IMG}"
else
    echo -e "\e[1;31m[!] WARNING: New image (${NEW_SIZE}) > original partition (${ORIG_SIZE})!\e[0m"
    echo -e "\e[1;31m    Image may not fit! Consider removing unused modules.\e[0m"
fi

IMG_SIZE=$(du -sh "${OUT_IMG}" | cut -f1)
echo -e "\e[1;32m[✓] Created ${OUT_IMG} (${IMG_SIZE})\e[0m"

# Verify
echo -e "\e[1;93m[*] Verifying image...\e[0m"
fsck.erofs "${OUT_IMG}" 2>&1 && echo -e "\e[1;32m[✓] Image passed fsck\e[0m" || echo -e "\e[1;31m[✗] Image failed fsck!\e[0m"

# ──────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "\e[1;32m[✓] Done!\e[0m"
echo "    Run dir:     ${RUN_DIR}"
echo "    Modules:     ${NEW_KO_COUNT} .ko files"
echo "    Tarball:     ${OUT_TAR} (${TAR_SIZE})"
echo "    Image:       ${OUT_IMG} (${IMG_SIZE})"
echo "    Extracted:   ${EXTRACT_DIR}"
echo "    Depmod:      ${DEPMOD_STAGING}"
echo "    Contexts:    ${FILE_CONTEXTS}"

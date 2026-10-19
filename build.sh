#!/bin/bash
set -euo pipefail

info(){ echo -e "\n[INFO]: $*\n"; }
error(){ echo -e "\n[ERROR]: $*\n" >&2; exit 1; }

KERNEL_DIR="$(dirname "$(readlink -f "$0")")"
VERSION=$(awk -F' = ' '/^VERSION/ {print $2}' Makefile)
PATCHLEVEL=$(awk -F' = ' '/^PATCHLEVEL/ {print $2}' Makefile)
KERNEL_VERSION="${VERSION}.${PATCHLEVEL}"

TOOLCHAIN_DIR="$KERNEL_DIR/toolchain"
CLANG_DIR="$TOOLCHAIN_DIR/clang"
GCC_DIR="$TOOLCHAIN_DIR/gcc"
DEFCONFIG_DIR=("$KERNEL_DIR/arch/arm64/configs")
[ "$VERSION" -lt 4 ] && DEFCONFIG_DIR+=("$KERNEL_DIR/arch/arm/configs")
DEFCONFIG=
KSU=y

# ==============================================================================
# SAMSUNG kernel?
# ==============================================================================
if [[ -d "security/defex" || -d "security/rkp" || -d "security/proca" || -d "security/five" || -d "security/samsung" ]]; then
 SAMSUNG_KERNEL=true
 info "Detected SAMSUNG kernel!"
 info "Please create an Issues if it's wrong!"
 if [ -f "README_Kernel.txt" ]; then
  SAMSUNG_DEFCONFIG=$(grep -m 1 -oE '[a-zA-Z0-9_-]+_defconfig' README_Kernel.txt || true)
  [ -n "$SAMSUNG_DEFCONFIG" ] && DEFCONFIG="$SAMSUNG_DEFCONFIG"
 fi
 [ -f "build_kernel.sh" ] && source <(grep -E "^export " build_kernel.sh || true)
else
 SAMSUNG_KERNEL=false
 info "Please create an Issues if it can't detect Samsung kernel!"
fi

# ==============================================================================
# 1. CHECK KERNEL VERSION
# ==============================================================================
if [[ -z "$VERSION" || -z "$PATCHLEVEL" ]]; then
 error "Can not detect kernel version!"
elif [[ ( "$VERSION" -eq 5 && "$PATCHLEVEL" -gt 4 ) || "$VERSION" -gt 5 ]]; then
 error "This script does not support GKI kernel ${KERNEL_VERSION}!"
else
 info "Detected kernel ${KERNEL_VERSION}!"
fi

# ==============================================================================
# 2. DEPENDENCIES & OS CHECK
# ==============================================================================
RPM_PKGS=(make gcc gcc-c++ bc bison flex pkgconf git curl ccache tar xz zip unzip cpio rsync kmod
          perl python3 openssl openssl-devel openssl-devel-engine elfutils-libelf-devel dwarves
          ncurses-devel zlib-devel libyaml-devel lz4 zstd dtc)
DEB_PKGS=(build-essential bc bison flex pkg-config git curl ccache tar xz-utils zip unzip cpio rsync
          kmod perl python3 python-is-python3 libssl-dev libelf-dev pahole libncurses-dev
          zlib1g-dev libyaml-dev lz4 zstd device-tree-compiler)

install_deps(){
 local missing=() available=() p
 if command -v rpm &>/dev/null; then
  for p in "${RPM_PKGS[@]}"; do
   rpm -q --whatprovides "$p" &>/dev/null || missing+=("$p")
  done
  [ "${#missing[@]}" = 0 ] && return 0
  info "Installing: ${missing[*]}"
  sudo dnf install -y --skip-unavailable "${missing[@]}" || error "Install the kernel build dependencies failed"
 elif command -v dpkg &>/dev/null; then
  for p in "${DEB_PKGS[@]}"; do
   [ "$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null)" = installed ] || missing+=("$p")
  done
  [ "${#missing[@]}" = 0 ] && return 0
  for p in "${missing[@]}"; do apt-cache show "$p" &>/dev/null && available+=("$p"); done
  [ "${#available[@]}" = 0 ] && return 0
  info "Installing: ${available[*]}"
  sudo apt update && sudo apt install -y "${available[@]}" || error "Install the kernel build dependencies failed!"
 else
  info "Unknown package manager -- install the kernel build dependencies yourself."
 fi
}

install_deps
[ -f .gitmodules ] && git submodule update --init --recursive

# ==============================================================================
# 3. CHECK DEFCONFIG
# ==============================================================================
get_available_configs(){
 find "${DEFCONFIG_DIR[@]}" -type f \( -name "*defconfig" -o -name "*.config" -o -name "*.fragment" \) -printf "%f\n" 2>/dev/null | sort -u
}
check_defconfigs(){
 local input_configs="$1"
 local check_defconfigs_name=""
 local check_defconfigs_path=""
 
 for config in $input_configs; do
  local config_path=$(find "${DEFCONFIG_DIR[@]}" -type f -name "$config" -print -quit 2>/dev/null)
  
  if [ -n "$config_path" ]; then
   local rel_name="$config_path"
   for dir in "${DEFCONFIG_DIR[@]}"; do rel_name="${rel_name#$dir/}"; done
   check_defconfigs_name="${check_defconfigs_name} ${rel_name}"
   check_defconfigs_path="${check_defconfigs_path} ${config_path}"
  else
   echo -e "\n[ERROR]: No such defconfig name '${config}'! Please try again with available one(s):" >&2
   get_available_configs | column | expand | sed 's/^/    /'
   return 1
  fi
 done
 
 DEFCONFIGS_NAMES="${check_defconfigs_name# }"
 DEFCONFIGS_PATHS="${check_defconfigs_path# }"
 return 0
}

AVAILABLE_CONFIGS=$(get_available_configs)
CONFIG_COUNT=$(echo "$AVAILABLE_CONFIGS" | grep -c . || true)

[[ "$CONFIG_COUNT" -eq 1 && -z "$DEFCONFIG" ]] && DEFCONFIG="$AVAILABLE_CONFIGS"
while [ -z "$DEFCONFIG" ] || ! check_defconfigs "$DEFCONFIG"; do
 read -p "[?] Enter defconfig (supports multiple, space-separated): " DEFCONFIG
done
DEFCONFIG="$DEFCONFIGS_NAMES"
info "Using ${DEFCONFIG} as defconfig!"

# ==============================================================================
# 4. DETECT ARCHITECTURE
# ==============================================================================
if [[ "$DEFCONFIGS_PATHS" == *"arm64"* ]]; then
 export ARCH=arm64
 export CLANG_TRIPLE="aarch64-linux-gnu-"
 info "Kernel's architecture is 64-bits!"
else
 export ARCH=arm
 export CLANG_TRIPLE="arm-linux-gnueabi-"
 info "Kernel's architecture is 32-bits!"
fi

if [[ "$SAMSUNG_KERNEL" == true && ! -f "${KERNEL_DIR}/arch/${ARCH}/configs/samsung-rkp.config" ]]; then
 cat <<EOF > "${KERNEL_DIR}/arch/${ARCH}/configs/samsung-rkp.config"
CONFIG_UH=n
CONFIG_UH_RKP=n
CONFIG_UH_LKMAUTH=n
CONFIG_UH_LKM_BLOCK=n
CONFIG_RKP_CFP_JOPP=n
CONFIG_RKP_CFP_ROPP=n
CONFIG_RKP_CFP=n
CONFIG_SECURITY_DEFEX=n
CONFIG_PROCA=n
CONFIG_FIVE=n
EOF
fi
[ "$SAMSUNG_KERNEL" = true ] && DEFCONFIG+=" samsung-rkp.config"

# ==============================================================================
# 5. BUILD OPTIONS
# ==============================================================================
BUILD_OPTIONS=(-C "${KERNEL_DIR}" -j"$(nproc)" ARCH="${ARCH}" )

if [[ "$SAMSUNG_KERNEL" == true && "${DEFCONFIG,,}" == *"exynos"* ]]; then
 IMAGE_DIR="${KERNEL_DIR}/arch/${ARCH}/boot"
else
 BUILD_OPTIONS+=( O="${KERNEL_DIR}/out" )
 IMAGE_DIR="${KERNEL_DIR}/out/arch/${ARCH}/boot"
fi

# ==============================================================================
# 6. DOWNLOAD TOOLCHAIN
# ==============================================================================
get_gcc(){
 [ ! -d "$GCC_DIR/aarch64" ] && git clone -q https://github.com/Tam97123/Google-GCC-Android -b aarch64 "$GCC_DIR/aarch64"
 [ ! -d "$GCC_DIR/arm" ] && git clone -q https://github.com/Tam97123/Google-GCC-Android -b arm32 "$GCC_DIR/arm"
 if [ "$ARCH" = "arm64" ]; then
  export CROSS_COMPILE="${GCC_DIR}/aarch64/bin/aarch64-linux-android-"
  export CROSS_COMPILE_ARM32="${GCC_DIR}/arm/bin/arm-linux-androideabi-"
  BUILD_OPTIONS+=( CROSS_COMPILE="${CROSS_COMPILE}" CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}" )
 else
  export CROSS_COMPILE="${GCC_DIR}/arm/bin/arm-linux-androideabi-"
  BUILD_OPTIONS+=( CROSS_COMPILE="${CROSS_COMPILE}" )
 fi
}

if ls "${KERNEL_DIR}"/build.config.* 1> /dev/null 2>&1; then
 info "Detected AOSP kernel (Using LLVM/Clang)"
 if [ ! -d "$CLANG_DIR" ]; then
  CLANG_NAME="$(grep -hoE 'clang-r?[0-9]+[a-z0-9]*' "$KERNEL_DIR"/build.config.* 2>/dev/null | sort | uniq -c | sort -nr | awk '{print $2}' | head -n 1 || true )"
  if [ -n "$CLANG_NAME" ]; then
   info "Downloading ${CLANG_NAME}..."
   git clone --filter=blob:none --no-checkout https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 aosp_clang >/dev/null 2>&1
   cd aosp_clang
   CLANG_TARGET=$(git log -n 1 --all --diff-filter=AM --format="%H" -- "$CLANG_NAME")
   git sparse-checkout init --cone >/dev/null 2>&1
   git sparse-checkout set "$CLANG_NAME" >/dev/null 2>&1
   git checkout "$CLANG_TARGET" >/dev/null 2>&1
   mkdir -p "${CLANG_DIR%/*}"
   mv "$CLANG_NAME" "$CLANG_DIR"
   cd "$KERNEL_DIR" && rm -rf aosp_clang
  else
   error "Can not detect clang!"
  fi
 fi

 export PATH="${CLANG_DIR}/bin:${PATH}"
 export LD_LIBRARY_PATH="${CLANG_DIR}/lib:${CLANG_DIR}/lib64:${LD_LIBRARY_PATH:-}"
 [[ "$VERSION" -lt 5 || ( "$VERSION" -ge 5 && "$PATCHLEVEL" -le 10 ) ]] && get_gcc
 BUILD_OPTIONS+=( CC="ccache ${CLANG_DIR}/bin/clang" LD="${CLANG_DIR}/bin/ld.lld" LLVM=1 LLVM_IAS=1 HOSTCC=gcc HOSTCXX=g++ CLANG_TRIPLE="${CLANG_TRIPLE}" )
else
 info "Detected OEM kernel (Using GCC)"
 get_gcc
 BUILD_OPTIONS+=( CC="ccache ${CROSS_COMPILE}gcc" )
fi

# ==============================================================================
# 7. INTEGRATE KERNELSU
# ==============================================================================
while [ -z "$KSU" ]; do
 read -t 10 -p "Integrate KSU? [y/n]: " KSU || break
 [[ "${KSU,,}" =~ ^[yn]$ ]] && sed -i "s/^KSU=.*/KSU=$KSU/" "${BASH_SOURCE[0]}" && break
 info "Unknown answer: ${KSU}" && KSU=
done

if [ "${KSU,,}" = "y" ]; then
 if [ ! -d "$KERNEL_DIR/KernelSU" ]; then
  info "Integrating KernelSU..."
  curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash >/dev/null 2>&1
 fi

 if [[ "$VERSION" -eq 4 || "$KERNEL_VERSION" == "5.4" ]]; then
  REJECT_DIR="$KERNEL_DIR/patch_rejects"
  
  if [ ! -f "$KERNEL_DIR/.ksu_patch" ]; then
   info "Integrating SUSFS..."
   KSU_PATCH="susfs_inline_hook_patches.sh"
   curl -sLO "https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/refs/heads/mainline/Patches/${KSU_PATCH}"
   bash "$KSU_PATCH" >/dev/null 2>&1 && rm -f "$KSU_PATCH"
   
   SUSFS_PATCH="susfs_patch_to_${KERNEL_VERSION}.patch"
   if curl -sLfO "https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/refs/heads/mainline/Patches/Patch/${SUSFS_PATCH}"; then
    patch -p1 < "$SUSFS_PATCH" || true
    rm -f "$SUSFS_PATCH"
   fi
   touch .ksu_patch
  fi
 
  if find "$KERNEL_DIR" -path "$REJECT_DIR" -prune -o -name "*.rej" -print | grep -q "."; then
   info "Patches failed!"
   mkdir -p "$REJECT_DIR"
   find "$KERNEL_DIR" -path "$REJECT_DIR" -prune -o -type f -name "*.rej" -print | while read -r rej_file; do
    rel_dir=$(dirname "${rej_file#$KERNEL_DIR/}")
    mkdir -p "$REJECT_DIR/$rel_dir"
    mv "$rej_file" "$REJECT_DIR/$rel_dir/"
   done
   error "Collected failed patches into $REJECT_DIR"
  fi
  if [ ! -f "${KERNEL_DIR}/arch/${ARCH}/configs/ksu-susfs.config" ]; then 
   info "Appending KernelSU configurations..."
   cat <<EOF > "${KERNEL_DIR}/arch/${ARCH}/configs/ksu-susfs.config"
CONFIG_DEBUG_KERNEL=y
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
EOF
  fi
  DEFCONFIG+=" ksu-susfs.config"
 elif [ "$KERNEL_VERSION" = "3.18" ]; then
  info "This script does not support SUSFS for kernel 3.18!"
  if [ ! -f "${KERNEL_DIR}/arch/${ARCH}/configs/ksu.config" ]; then
   info "Appending KernelSU configurations..."
   cat <<EOF > "${KERNEL_DIR}/arch/${ARCH}/configs/ksu.config"
CONFIG_DEBUG_KERNEL=y
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
EOF
  fi
  DEFCONFIG+=" ksu.config"
 else
  info "This script does not support KernelSU for kernel ${KERNEL_VERSION}. Skipping KernelSU integration!"
  sed -i "s/^KSU=y.*/KSU=n/" "${BASH_SOURCE[0]}"
 fi
elif [ "${KSU,,}" = "n" ]; then
 info "Skipping KernelSU integration!"
fi

# ==============================================================================
# 8. BUILDING PROCESS
# ==============================================================================
export USE_CCACHE=1
export CCACHE_EXEC=$(command -v ccache || echo "/usr/bin/ccache")
ccache -M 50G >/dev/null

info "Generating Defconfig..."
make "${BUILD_OPTIONS[@]}" $DEFCONFIG

info "Compiling Kernel..."
[ -f "${KERNEL_DIR}/build.log" ] && rm -f build.log
make "${BUILD_OPTIONS[@]}" 2>&1 | tee build.log
info "BUILD succeed!"

# ==============================================================================
# 9. PACKAGE ANYKERNEL3 ZIP
# ==============================================================================
ANYKERNEL3_DIR="${KERNEL_DIR}/AnyKernel3"
ZIP_NAME="Kernel_${KERNEL_VERSION}_$(date +%y%m%d).zip"

if [ ! -d "$ANYKERNEL3_DIR" ]; then
 info "Downloading AnyKernel3..."
 git clone -q https://github.com/osm0sis/AnyKernel3 "$ANYKERNEL3_DIR" || error "Can not download AnyKernel3!"
fi

info "Copying Kernel Image..."
for img in Image.gz-dtb Image.lz4-dtb Image.gz Image.lz4 Image; do
 [ -f "$IMAGE_DIR/$img" ] && cp "$IMAGE_DIR/$img" "$ANYKERNEL3_DIR/" && break
done
find "${KERNEL_DIR}/out" -type f -name "*.img" -exec cp {} "$ANYKERNEL3_DIR/" \; 2>/dev/null || true

cd "$ANYKERNEL3_DIR"
zip -r9 "${KERNEL_DIR}/${ZIP_NAME}" . -x "*.git*" > /dev/null
rm -rf "$ANYKERNEL3_DIR"
info "AnyKernel3 created at ${KERNEL_DIR}/${ZIP_NAME}"

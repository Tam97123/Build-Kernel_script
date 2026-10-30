#!/bin/bash
set -euo pipefail

info(){ echo -e "\n[INFO]: $*\n"; }
error(){ echo -e "\n[ERROR]: $*\n" >&2; exit 1; }

KERNEL_DIR="$(dirname "$(readlink -f "$0")")"
cd "$KERNEL_DIR"
VERSION=$(awk -F' = ' '/^VERSION/ {print $2}' Makefile)
PATCHLEVEL=$(awk -F' = ' '/^PATCHLEVEL/ {print $2}' Makefile)
KERNEL_VERSION="${VERSION}.${PATCHLEVEL}"

TOOLCHAIN_DIR="$KERNEL_DIR/toolchain"
CLANG_DIR="$TOOLCHAIN_DIR/clang"
GCC_DIR="$TOOLCHAIN_DIR/gcc"
DEFCONFIG_DIR=("$KERNEL_DIR/arch/arm64/configs")
[ "$VERSION" -lt 4 ] && DEFCONFIG_DIR+=("$KERNEL_DIR/arch/arm/configs")

DEFCONFIG=
KSU=
KSU_FORK=
SUSFS=
KPM=
REKERNEL=
BBG=
DROIDSPACES=
NOMOUNT=
PACK_MODULES=

PATCH_REPO="https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/refs/heads/mainline/Patches"

ask_choice(){
 local var_name="$1" prompt="$2" regex="$3" val="${!1}"
 while [ -z "$val" ] || [[ ! "${val,,}" =~ $regex ]]; do
  read -t 15 -p "$prompt" val || break
  if [[ "${val,,}" =~ $regex ]]; then
   sed -i "s|^${var_name}=.*|${var_name}=${val,,}|" "${BASH_SOURCE[0]}"
   break
  fi
  info "Unknown answer: ${val}" && val=
 done
 printf -v "$var_name" "%s" "${val,,}"
}

if [ -f /etc/os-release ]; then
 . /etc/os-release
 info "OS: ${PRETTY_NAME:-Linux} | User: $(whoami) | Dir: ${KERNEL_DIR} | Shell: ${SHELL}"
fi

if [[ -z "$VERSION" || -z "$PATCHLEVEL" ]]; then
 error "Can not detect kernel version!"
elif [[ ( "$VERSION" -eq 5 && "$PATCHLEVEL" -gt 4 ) || "$VERSION" -gt 5 ]]; then
 error "This script does not support GKI kernel ${KERNEL_VERSION}!"
else
 info "Detected kernel ${KERNEL_VERSION}!"
fi

if [[ -d "security/defex" || -d "security/rkp" || -d "security/proca" || -d "security/five" || -d "security/samsung" || -d "drivers/samsung" ]]; then
 SAMSUNG_KERNEL=true
 SAMSUNG_README=$(find "$KERNEL_DIR" "$KERNEL_DIR/.." -maxdepth 1 -type f -iname "README_Kernel.txt" -print -quit 2>/dev/null || true)
 info "Detected SAMSUNG kernel! Please create an Issue if it's wrong!"
 [ -z "$SAMSUNG_README" ] && error "Instruction from SAMSUNG not found! Please provide README_Kernel.txt in the kernel source or upper directory."
 [ -z "$DEFCONFIG" ] && DEFCONFIG=$(grep -m 1 -oE '[a-zA-Z0-9_-]+_defconfig' "$SAMSUNG_README" || true)
 [ -f "build_kernel.sh" ] && source <(grep -E "^export " build_kernel.sh || true)
else
 SAMSUNG_KERNEL=false
 info "Please create an Issue if this is SAMSUNG kernel!"
fi

RPM_PKGS=(make gcc gcc-c++ bc bison flex pkgconf git curl ccache tar xz zip unzip cpio rsync kmod
          perl python3 openssl openssl-devel openssl-devel-engine elfutils-libelf-devel dwarves
          ncurses-devel zlib-devel libyaml-devel lz4 zstd dtc patch coccinelle)
DEB_PKGS=(build-essential bc bison flex pkg-config git curl ccache tar xz-utils zip unzip cpio rsync
          kmod perl python3 python-is-python3 libssl-dev libelf-dev pahole libncurses-dev
          zlib1g-dev libyaml-dev lz4 zstd device-tree-compiler patch coccinelle)
PAC_PKGS=(base-devel bc bison flex pkgconf git curl ccache tar xz zip unzip cpio rsync kmod
          perl python openssl libelf pahole ncurses zlib libyaml lz4 zstd dtc patch coccinelle)

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
 elif command -v pacman &>/dev/null; then
  for p in "${PAC_PKGS[@]}"; do
   pacman -Qi "$p" &>/dev/null || missing+=("$p")
  done
  [ "${#missing[@]}" = 0 ] && return 0
  info "Installing: ${missing[*]}"
  sudo pacman -S --needed --noconfirm "${missing[@]}" || error "Install the kernel build dependencies failed!"
 else
  info "Unknown package manager -- install the kernel build dependencies yourself."
 fi
}

install_deps
[ -f .gitmodules ] && git submodule update --init --recursive

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

if [ -z "$DEFCONFIG" ]; then
 AVAILABLE_CONFIGS=$(get_available_configs)
 [ "$(echo "$AVAILABLE_CONFIGS" | grep -c . || true)" -eq 1 ] && DEFCONFIG="$AVAILABLE_CONFIGS"
fi
while [ -z "$DEFCONFIG" ] || ! check_defconfigs "$DEFCONFIG"; do
 read -p "[INFO] Enter defconfig (supports multiple, space-separated): " DEFCONFIG
done
DEFCONFIG="$DEFCONFIGS_NAMES"
PRIMARY_DEFCONFIG="${DEFCONFIGS_PATHS%% *}"
sed -i "s|^DEFCONFIG=.*|DEFCONFIG=\"$DEFCONFIG\"|" "${BASH_SOURCE[0]}"
info "Using ${DEFCONFIG} as defconfig!"

if [[ "$DEFCONFIGS_PATHS" = *"arm64"* ]]; then
 export ARCH=arm64
 export CLANG_TRIPLE="aarch64-linux-gnu-"
else
 export ARCH=arm
 export CLANG_TRIPLE="arm-linux-gnueabi-"
fi

if [[ "$SAMSUNG_KERNEL" = true && ! -f "${KERNEL_DIR}/arch/${ARCH}/configs/samsung-rkp.config" ]]; then
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

BUILD_OPTIONS=(-C "${KERNEL_DIR}" -j"$(nproc)" ARCH="${ARCH}" )

if [[ "$SAMSUNG_KERNEL" = true && "${DEFCONFIG,,}" = *"exynos"* ]]; then
 IMAGE_DIR="${KERNEL_DIR}/arch/${ARCH}/boot"
 OUT_DIR="${KERNEL_DIR}"
else
 BUILD_OPTIONS+=( O="${KERNEL_DIR}/out" )
 IMAGE_DIR="${KERNEL_DIR}/out/arch/${ARCH}/boot"
 OUT_DIR="${KERNEL_DIR}/out"
fi

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

if ls "${KERNEL_DIR}"/build.config.* 1> /dev/null 2>&1 || grep -qi "clang" "${SAMSUNG_README:-}" 2>/dev/null; then
 info "Detected AOSP kernel (Using LLVM/Clang)"
 if [ ! -d "$CLANG_DIR" ]; then
  CLANG_NAME="$(grep -oE 'clang-r?[0-9]+[a-z0-9]*' "${SAMSUNG_README:-}" 2>/dev/null | head -n 1 || true)"
  [ -n "$CLANG_NAME" ] || CLANG_NAME="$(grep -hoE 'clang-r?[0-9]+[a-z0-9]*' "$KERNEL_DIR"/build.config.* 2>/dev/null | sort | uniq -c | sort -nr | awk '{print $2}' | head -n 1 || true)"
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
  elif [ "$KERNEL_VERSION" = "5.4" ]; then
   info "Downloading LLVM toolchain 10.0.9..."
   mkdir -p "$CLANG_DIR"
   curl -LSs "https://github.com/ravindu644/Android-Kernel-Tutorials/releases/download/toolchains/llvm-arm-toolchain-ship-10.0.9.tar.gz" | tar -xz -C "$CLANG_DIR" --strip-components=1
  else
   error "Can not detect clang!"
  fi
 fi

 export PATH="${CLANG_DIR}/bin:${PATH}"
 export LD_LIBRARY_PATH="${CLANG_DIR}/lib:${CLANG_DIR}/lib64:${LD_LIBRARY_PATH:-}"
 [[ "$VERSION" -lt 5 || ( "$VERSION" -ge 5 && "$PATCHLEVEL" -le 10 ) ]] && get_gcc
 BUILD_OPTIONS+=( CC="ccache ${CLANG_DIR}/bin/clang" LD="${CLANG_DIR}/bin/ld.lld" AR="${CLANG_DIR}/bin/llvm-ar" NM="${CLANG_DIR}/bin/llvm-nm" OBJCOPY="${CLANG_DIR}/bin/llvm-objcopy" OBJDUMP="${CLANG_DIR}/bin/llvm-objdump" STRIP="${CLANG_DIR}/bin/llvm-strip" READELF="${CLANG_DIR}/bin/llvm-readelf" LLVM=1 LLVM_IAS=1 HOSTCC=gcc HOSTCXX=g++ CLANG_TRIPLE="${CLANG_TRIPLE}" )
else
 info "Detected OEM kernel (Using GCC)"
 get_gcc
 BUILD_OPTIONS+=( CC="ccache ${CROSS_COMPILE}gcc" )
fi

clean_hooks(){
 local f
 for f in drivers/kernelsu KernelSU KernelSU-Next fs/susfs.c fs/sus_su.c include/linux/susfs.h include/linux/susfs_def.h .ksu_patch; do
  rm -rf "$f"
 done
 for f in fs/exec.c fs/read_write.c fs/open.c fs/stat.c fs/devpts/inode.c fs/namei.c drivers/input/input.c drivers/tty/pty.c security/selinux/hooks.c kernel/reboot.c kernel/sys.c; do
  [ -f "$f" ] && sed -i '/#ifdef CONFIG_KSU/,/#endif/d' "$f"
 done
 for f in security/selinux/avc.c kernel/kallsyms.c kernel/sys.c kernel/reboot.c fs/dcache.c fs/statfs.c fs/namespace.c fs/proc_namespace.c fs/stat.c fs/namei.c fs/readdir.c fs/exec.c fs/proc/task_mmu.c fs/proc/base.c fs/proc/fd.c fs/proc/cmdline.c fs/overlayfs/super.c fs/overlayfs/overlayfs.h fs/overlayfs/inode.c fs/notify/fdinfo.c fs/devpts/inode.c include/linux/sched.h fs/super.c include/linux/mount.h; do
  if [ -f "$f" ]; then
   perl -i -0777 -pe 's/#ifndef CONFIG_KSU_SUSFS[^\n]*\n(.*?)#else\n(.*?)#endif\n/$1/gs; s/#ifdef CONFIG_KSU_SUSFS[^\n]*\n(.*?)#else\n(.*?)#endif\n/$1/gs' "$f"
   sed -i '/#ifdef CONFIG_KSU_SUSFS/,/#endif/d; /#if defined(CONFIG_KSU_SUSFS/,/#endif/d; /#ifndef CONFIG_KSU_SUSFS/,/#endif/d' "$f"
  fi
 done
 [ -f fs/Makefile ] && sed -i '/CONFIG_KSU_SUSFS/d' fs/Makefile
}

fix_selinux_static(){
 if ! grep -rq "check_symbol_export" "drivers/kernelsu/tools/static_export_check.mk" 2>/dev/null; then
  return 0
 fi
 if [ -f security/selinux/selinuxfs.c ]; then
  sed -i 's/static ssize_t (\*const write_op\[\])(struct file \*, char \*, size_t)/ssize_t (*const write_op[])(struct file *, char *, size_t)/; s/static ssize_t (\*write_op\[\])(struct file \*, char \*, size_t)/ssize_t (*write_op[])(struct file *, char *, size_t)/; s/^static const struct file_operations sel_handle_status_ops = {/const struct file_operations sel_handle_status_ops = {/' security/selinux/selinuxfs.c
 fi
 if [ -f security/selinux/ss/services.c ]; then
  sed -i 's/static void security_dump_masked_av(struct policydb \*policydb,/void security_dump_masked_av(struct policydb *policydb,/; s/static void context_struct_compute_av(struct policydb \*policydb,/void context_struct_compute_av(struct policydb *policydb,/' security/selinux/ss/services.c
 fi
 if [[ "$VERSION" -lt 5 || ( "$VERSION" -eq 5 && "$PATCHLEVEL" -lt 15 ) ]]; then
  [ -f security/selinux/selinuxfs.c ] && sed -i 's/^static DEFINE_MUTEX(sel_mutex)/DEFINE_MUTEX(sel_mutex)/' security/selinux/selinuxfs.c
  [ -f security/selinux/ss/status.c ] && sed -i 's/^static struct page \*selinux_status_page/struct page *selinux_status_page/; s/^static DEFINE_MUTEX(selinux_status_lock)/DEFINE_MUTEX(selinux_status_lock)/' security/selinux/ss/status.c
 fi
 if [[ "$VERSION" -lt 4 || ( "$VERSION" -eq 4 && "$PATCHLEVEL" -lt 19 ) ]]; then
  [ -f security/selinux/hooks.c ] && sed -i 's/^static struct security_operations selinux_ops/struct security_operations selinux_ops/' security/selinux/hooks.c
 fi
}

ask_choice KSU "Integrate KSU? [y/n]: " "^[yn]$"

if [ "$KSU" = "y" ]; then
 ask_choice KSU_FORK "Select KSU fork [resukisu/sukisu/bakasu/next/rsuntk/xxksu]: " "^(resukisu|sukisu|bakasu|next|rsuntk|xxksu)$"
 [ -z "$KSU_FORK" ] && KSU_FORK="resukisu"

 if [[ "$KSU_FORK" =~ ^(resukisu|sukisu|bakasu)$ ]] && [[ "$VERSION" -eq 4 || "$KERNEL_VERSION" = "5.4" ]]; then
  ask_choice SUSFS "Enable SUSFS? [y/n]: " "^[yn]$"
 else
  SUSFS="n"
 fi

 ask_choice KPM "Enable KPM? [y/n]: " "^[yn]$"

 if [ ! -d "$KERNEL_DIR/KernelSU" ] && [ ! -d "$KERNEL_DIR/KernelSU-Next" ]; then
  info "Integrating KernelSU (${KSU_FORK})..."
  case "$KSU_FORK" in
   resukisu) curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash >/dev/null 2>&1 ;;
   sukisu)
    curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/refs/heads/main/kernel/setup.sh" | bash -s builtin >/dev/null 2>&1
    if [ -d "drivers/kernelsu" ]; then
     curl -sLf "${PATCH_REPO}/Patch/sukisu_ultra_fixed.patch" | patch -d drivers/kernelsu -p1 || true
    fi
    ;;
   bakasu) curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/refs/heads/main/kernel/setup.sh" | bash -s main >/dev/null 2>&1 ;;
   next) curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/refs/heads/legacy/kernel/setup.sh" | bash -s legacy >/dev/null 2>&1 ;;
   rsuntk) curl -LSs "https://raw.githubusercontent.com/rsuntk/KernelSU/refs/heads/main/kernel/setup.sh" | bash -s main >/dev/null 2>&1 ;;
   xxksu) curl -LSs "https://raw.githubusercontent.com/backslashxx/KernelSU/refs/heads/master/kernel/setup.sh" | bash -s master >/dev/null 2>&1 ;;
  esac
 fi

 KSU_CFG="${KERNEL_DIR}/arch/${ARCH}/configs/ksu-custom.config"
 cat <<EOF > "$KSU_CFG"
CONFIG_DEBUG_KERNEL=y
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y
CONFIG_KSU=y
EOF
 [ "$KSU_FORK" = "xxksu" ] && echo "CONFIG_KSU_KPROBES_KSUD=n" >> "$KSU_CFG"
 [[ "$KSU_FORK" = "next" && ( "$VERSION" -lt 5 || "$PATCHLEVEL" -lt 10 ) ]] && echo "CONFIG_KSU_ALLOWLIST_WORKAROUND=y" >> "$KSU_CFG"
 grep -q "THREAD_INFO_IN_TASK" "drivers/kernelsu/Kconfig" 2>/dev/null && echo "CONFIG_THREAD_INFO_IN_TASK=y" >> "$KSU_CFG"

 if [ "$SUSFS" = "y" ]; then
  REJECT_DIR="$KERNEL_DIR/patch_rejects"
  if [ ! -f "$KERNEL_DIR/.ksu_patch" ] && ! grep -q "CONFIG_KSU_SUSFS" "fs/namespace.c" 2>/dev/null; then
   info "Integrating SUSFS..."
   curl -sLO "${PATCH_REPO}/susfs_inline_hook_patches.sh"
   bash susfs_inline_hook_patches.sh >/dev/null 2>&1 && rm -f susfs_inline_hook_patches.sh
   SUSFS_PATCH="susfs_patch_to_${KERNEL_VERSION}.patch"
   if curl -sLfO "${PATCH_REPO}/Patch/${SUSFS_PATCH}"; then
    patch -p1 < "$SUSFS_PATCH" || true
    rm -f "$SUSFS_PATCH"
   fi
   touch .ksu_patch
  fi

  if find "$KERNEL_DIR" -path "$REJECT_DIR" -prune -o -name "*.rej" -print | grep -q "."; then
   info "Patches failed! Packing rejects..."
   mkdir -p "$REJECT_DIR"
   find "$KERNEL_DIR" -path "$REJECT_DIR" -prune -o -type f -name "*.rej" -print | while read -r rej_file; do
    rel_dir=$(dirname "${rej_file#$KERNEL_DIR/}")
    mkdir -p "$REJECT_DIR/$rel_dir"
     [ -f "${rej_file%.rej}" ] && cp "${rej_file%.rej}" "$REJECT_DIR/$rel_dir/"
    mv "$rej_file" "$REJECT_DIR/$rel_dir/"
   done
   tar -czf "$KERNEL_DIR/rej_files.tar.gz" -C "$REJECT_DIR" .
   find "$KERNEL_DIR" -name "*.orig" -delete
   error "Collected failed patches into $REJECT_DIR and rej_files.tar.gz"
  fi

  cat <<EOF >> "$KSU_CFG"
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
 else
  if [ ! -f "$KERNEL_DIR/.ksu_patch" ]; then
   info "Applying manual syscall hooks..."
   curl -sLO "${PATCH_REPO}/syscall_hook_patches.sh"
   bash syscall_hook_patches.sh >/dev/null 2>&1 && rm -f syscall_hook_patches.sh
   touch .ksu_patch
  fi
  [[ "$KSU_FORK" =~ ^(sukisu|bakasu)$ ]] && echo "CONFIG_KSU_SUSFS=n" >> "$KSU_CFG"
  echo "CONFIG_KSU_MANUAL_HOOK=y" >> "$KSU_CFG"
 fi

 fix_selinux_static

 if [ "$KPM" = "y" ]; then
  echo "CONFIG_KPM=y" >> "$KSU_CFG"
  if [[ "$KSU_FORK" =~ ^(resukisu|sukisu)$ ]]; then
   if [ ! -f "include/linux/set_memory.h" ]; then
    curl -sLf "${PATCH_REPO}/Patch/set_memory_to_49_and_low.patch" | patch -p1 || true
   fi
   [ ! -f "patch_linux" ] && curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU_patch/refs/heads/main/kpm/patch_linux" -o patch_linux && chmod +x patch_linux
  elif [ "$KSU_FORK" = "next" ]; then
   [ ! -f "kpimg-linux" ] && curl -LSs "https://github.com/KernelSU-Next/KPatch-Next/releases/latest/download/kpimg-linux" -o kpimg-linux
   [ ! -f "kptools-linux" ] && curl -LSs "https://github.com/KernelSU-Next/KPatch-Next/releases/latest/download/kptools-linux" -o kptools-linux && chmod +x kptools-linux
  fi
 fi

 DEFCONFIG+=" ksu-custom.config"
elif [ "$KSU" = "n" ]; then
 info "Skipping KernelSU integration!"
fi

ask_choice REKERNEL "Enable Re:Kernel? [y/n]: " "^[yn]$"
ask_choice BBG "Enable Baseband Guard? [y/n]: " "^[yn]$"
ask_choice DROIDSPACES "Enable Droidspaces (Docker/LXC)? [y/n]: " "^[yn]$"
ask_choice NOMOUNT "Enable NoMount? [y/n]: " "^[yn]$"
ask_choice PACK_MODULES "Pack kernel modules (.ko) in AnyKernel3? [y/n]: " "^[yn]$"

EXTRA_CFG="${KERNEL_DIR}/arch/${ARCH}/configs/extra-features.config"
rm -f "$EXTRA_CFG"

if [ "$REKERNEL" = "y" ]; then
 if grep -q "cgroup_task_frozen" "kernel/cgroup.c" 2>/dev/null || grep -q "cgroup_task_frozen" "kernel/cgroup/cgroup.c" 2>/dev/null; then
  info "Patching Re:Kernel..."
  curl -sLO "${PATCH_REPO}/Rekernel/rekernel_patches.sh"
  bash rekernel_patches.sh && rm -f rekernel_patches.sh
  curl -sLf "${PATCH_REPO}/Rekernel/rekernel_extra.patch" | patch -p1 || true
  echo "CONFIG_REKERNEL=y" >> "$EXTRA_CFG"
 else
  info "Cgroup v2 freeze missing, skipping Re:Kernel!"
 fi
fi

if [ "$BBG" = "y" ]; then
 info "Patching Baseband Guard..."
 [ ! -d "security/baseband-guard" ] && curl -LSs "https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh" | bash >/dev/null 2>&1
 echo "CONFIG_BBG=y" >> "$EXTRA_CFG"
 if grep -q "DEFINE_LSM" "include/linux/lsm_hooks.h" 2>/dev/null; then
  if grep -q "^CONFIG_LSM=" "$PRIMARY_DEFCONFIG" 2>/dev/null; then
   LSM_VAL=$(grep "^CONFIG_LSM=" "$PRIMARY_DEFCONFIG" | tail -n 1 | sed 's/"$/\,baseband_guard"/')
   echo "$LSM_VAL" >> "$EXTRA_CFG"
  elif grep -q "bpf" "security/Kconfig" 2>/dev/null; then
   echo 'CONFIG_LSM="lockdown,yama,loadpin,safesetid,integrity,selinux,smack,tomoyo,apparmor,bpf,baseband_guard"' >> "$EXTRA_CFG"
  else
   echo 'CONFIG_LSM="lockdown,yama,loadpin,safesetid,integrity,selinux,smack,tomoyo,apparmor,baseband_guard"' >> "$EXTRA_CFG"
  fi
 fi
fi

if [ "$DROIDSPACES" = "y" ]; then
 info "Patching Droidspaces..."
 curl -sLf "${PATCH_REPO}/Droidspaces/droidspaces.config" -o "${KERNEL_DIR}/arch/${ARCH}/configs/droidspaces.config"
 if command -v spatch &>/dev/null; then
  if [ -f "net/netfilter/xt_qtaguid.c" ]; then
   curl -sLO "${PATCH_REPO}/Droidspaces/fix_kernel_panic_in_xt_qtaguid.cocci"
   spatch --sp-file fix_kernel_panic_in_xt_qtaguid.cocci --in-place net/netfilter/xt_qtaguid.c >/dev/null 2>&1 || true
   rm -f fix_kernel_panic_in_xt_qtaguid.cocci
  fi
  for cg_file in kernel/cgroup/cgroup.c kernel/cgroup.c; do
   if [ -f "$cg_file" ] && ! grep -q "kernfs_create_link" "$cg_file" 2>/dev/null; then
    curl -sLO "${PATCH_REPO}/Droidspaces/fix_restore_cgroup_file_prefix_handling.cocci"
    spatch --sp-file fix_restore_cgroup_file_prefix_handling.cocci --in-place "$cg_file" >/dev/null 2>&1 || true
    rm -f fix_restore_cgroup_file_prefix_handling.cocci
    break
   fi
  done
 fi
 DEFCONFIG+=" droidspaces.config"
fi

if [ "$NOMOUNT" = "y" ]; then
 info "Patching NoMount..."
 curl -LSs "https://raw.githubusercontent.com/maxsteeel/nomount/refs/heads/dev/kernel/setup.sh" | bash -s >/dev/null 2>&1 || true
 echo "CONFIG_NOMOUNT=y" >> "$EXTRA_CFG"
fi

[ -f "$EXTRA_CFG" ] && DEFCONFIG+=" extra-features.config"

analyze_errors(){
 local log_file="$1"
 [ ! -f "$log_file" ] && return 0
 info "Analyzing build errors in $log_file..."
 grep -E " error:| fatal error:|undefined reference to|multiple definition of" "$log_file" | head -n 25 || true
 if grep -q "No such file or directory" "$log_file"; then
  info "Suggestion: Missing header or source file. Check include paths or missing dev libraries."
 elif grep -q "multiple definition of 'yylloc'" "$log_file"; then
  info "Suggestion: Change 'YYLTYPE yylloc;' to 'extern YYLTYPE yylloc;' in scripts/dtc/dtc-lexer.lex.c_shipped."
 elif grep -q "MODULE_IMPORT_NS" "$log_file"; then
  info "Suggestion: KernelSU namespace mismatch. Use SukiSU builtin branch or legacy Non-GKI KernelSU branch."
 elif grep -q "incompatible pointer types passing 'atomic_long_t \*'" "$log_file"; then
  info "Suggestion: Replace atomic_inc_not_zero with atomic_long_inc_not_zero in cred.h."
 elif grep -q "Error: junk at end of line" "$log_file" || grep -q "undefined symbol: __stack_chk_guard" "$log_file"; then
  info "Suggestion: Downgrade Clang version or append -gdwarf-4 to KBUILD_CFLAGS."
 elif grep -q "unrecognized command line option" "$log_file"; then
  info "Suggestion: Compiler flag mismatch. Check Makefile flags against your Clang/GCC version."
 elif grep -q "undefined reference to" "$log_file"; then
  info "Suggestion: Linker error (missing symbol). Check Kconfig dependencies or static SELinux symbols."
 fi

 if grep -q "Error 2" "$log_file"; then
  local tmp_err="error_files"
  mkdir -p "$tmp_err"
  grep -i "error:" "$log_file" | awk -F: '{print $1}' | sed 's#^\.\./##' | sort -u | while read -r err_src; do
   if [ -f "$err_src" ]; then
    mkdir -p "$tmp_err/$(dirname "$err_src")"
    cp "$err_src" "$tmp_err/$err_src"
   fi
  done
  if [ -n "$(ls -A "$tmp_err" 2>/dev/null)" ]; then
   zip -rq "${KERNEL_DIR}/error_files.zip" "$tmp_err"
   info "Packaged failing source files into ${KERNEL_DIR}/error_files.zip"
  fi
  rm -rf "$tmp_err"
 fi
}

export USE_CCACHE=1
export CCACHE_EXEC=$(command -v ccache || echo "/usr/bin/ccache")
export CCACHE_COMPILERCHECK="%compiler% -dumpmachine; %compiler% -dumpversion"
export CCACHE_NOHASHDIR="true"
export CCACHE_HARDLINK="true"
ccache -M 50G >/dev/null

info "Generating Defconfig..."
make "${BUILD_OPTIONS[@]}" $DEFCONFIG

if [ "$BBG" = "y" ]; then
 info "Pre-building SELinux for Baseband Guard..."
 make "${BUILD_OPTIONS[@]}" security/selinux/
fi

info "Compiling Kernel..."
[ -f "${KERNEL_DIR}/build.log" ] && rm -f build.log
set +e
make "${BUILD_OPTIONS[@]}" 2>&1 | tee build.log
BUILD_STATUS="${PIPESTATUS[0]}"
set -e

if [ "$BUILD_STATUS" -ne 0 ]; then
 analyze_errors build.log
 error "Kernel compilation failed!"
fi
info "BUILD succeed!"

if [ "$KSU" = "y" ] && [ "$KPM" = "y" ] && [ -f "$IMAGE_DIR/Image" ]; then
 info "Applying KPM patch to Kernel Image..."
 if [[ "$KSU_FORK" =~ ^(resukisu|sukisu)$ ]] && [ -f "$KERNEL_DIR/patch_linux" ]; then
  cp "$KERNEL_DIR/patch_linux" "$IMAGE_DIR/"
  (cd "$IMAGE_DIR" && ./patch_linux && mv -f oImage Image && rm -f patch_linux)
 elif [ "$KSU_FORK" = "next" ] && [ -f "$KERNEL_DIR/kptools-linux" ]; then
  cp "$KERNEL_DIR/kpimg-linux" "$KERNEL_DIR/kptools-linux" "$IMAGE_DIR/"
  (cd "$IMAGE_DIR" && ./kptools-linux -p -k kpimg-linux -i Image -o oImage && mv -f oImage Image && rm -f kpimg-linux kptools-linux)
 fi
 if [ -f "$IMAGE_DIR/Image.gz" ] || [ -f "$IMAGE_DIR/Image.gz-dtb" ]; then
  gzip -c "$IMAGE_DIR/Image" > "$IMAGE_DIR/Image.gz"
  if [ -f "$IMAGE_DIR/Image.gz-dtb" ]; then
   DTB_FILES=$(find "$IMAGE_DIR/dts" -type f -name "*.dtb" 2>/dev/null || true)
   [ -n "$DTB_FILES" ] && cat "$IMAGE_DIR/Image.gz" $DTB_FILES > "$IMAGE_DIR/Image.gz-dtb"
  fi
 fi
fi

if [ ! -f "$IMAGE_DIR/dtbo.img" ]; then
 DTBO_FILES=$(find "$IMAGE_DIR/dts" -type f -name "*.dtbo" 2>/dev/null || true)
 if [ -n "$DTBO_FILES" ]; then
  info "Generating dtbo.img..."
  if ! command -v mkdtboimg.py &>/dev/null && [ ! -f "$TOOLCHAIN_DIR/mkdtbo/mkdtboimg.py" ]; then
   git clone -q --depth=1 https://android.googlesource.com/platform/system/libufdt "$TOOLCHAIN_DIR/mkdtbo"
  fi
  MKDTBO_BIN=$(command -v mkdtboimg.py || echo "python3 $TOOLCHAIN_DIR/mkdtbo/utils/src/mkdtboimg.py")
  $MKDTBO_BIN create "$IMAGE_DIR/dtbo.img" --page_size=4096 $DTBO_FILES 2>/dev/null || true
 fi
fi

ANYKERNEL3_DIR="${KERNEL_DIR}/AnyKernel3"
ZIP_NAME="Kernel_${KERNEL_VERSION}_$(date +%y%m%d).zip"

if [ ! -d "$ANYKERNEL3_DIR" ]; then
 info "Downloading AnyKernel3..."
 git clone -q --depth=1 https://github.com/osm0sis/AnyKernel3 "$ANYKERNEL3_DIR" || error "Can not download AnyKernel3!"
 sed -i 's/ExampleKernel by osm0sis @ xda-developers/NonGKI Kernel Build/g; s/do.devicecheck=1/do.devicecheck=0/g; s!BLOCK=/dev/block/platform/omap/omap_hsmmc.0/by-name/boot;!BLOCK=auto;!g; s/IS_SLOT_DEVICE=0;/IS_SLOT_DEVICE=auto;/g' "$ANYKERNEL3_DIR/anykernel.sh"
fi

info "Copying Kernel Image..."
for img in Image.gz-dtb Image.lz4-dtb Image-dtb zImage-dtb Image; do
 [ -f "$IMAGE_DIR/$img" ] && cp "$IMAGE_DIR/$img" "$ANYKERNEL3_DIR/" && break
done

if [ -f "$IMAGE_DIR/dtb.img" ]; then
 cp "$IMAGE_DIR/dtb.img" "$ANYKERNEL3_DIR/dtb"
elif [ -f "$IMAGE_DIR/dtb" ]; then
 cp "$IMAGE_DIR/dtb" "$ANYKERNEL3_DIR/dtb"
fi

find "$OUT_DIR" -type f -name "*.img" -exec cp {} "$ANYKERNEL3_DIR/" \; 2>/dev/null || true

if [ "$PACK_MODULES" = "y" ]; then
 info "Packing kernel modules (.ko)..."
 sed -i 's/^do\.modules=.*/do.modules=1/' "$ANYKERNEL3_DIR/anykernel.sh"
 mkdir -p "$ANYKERNEL3_DIR/modules/vendor/lib/modules"
 find "$OUT_DIR" -type f -name "*.ko" -exec cp -fp {} "$ANYKERNEL3_DIR/modules/vendor/lib/modules/" \; 2>/dev/null || true
 [ -z "$(ls -A "$ANYKERNEL3_DIR/modules/vendor/lib/modules" 2>/dev/null)" ] && rm -rf "$ANYKERNEL3_DIR/modules"
fi

cd "$ANYKERNEL3_DIR"
zip -r9 "${KERNEL_DIR}/${ZIP_NAME}" . -x "*.git*" > /dev/null
rm -rf "$ANYKERNEL3_DIR"
info "AnyKernel3 created at ${KERNEL_DIR}/${ZIP_NAME}"

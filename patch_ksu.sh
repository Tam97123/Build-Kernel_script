#!/bin/bash
set -euo pipefail

KERNEL_DIR=$(pwd)
VERSION=$(grep -w '^VERSION' Makefile | tr -d ' ' | cut -d= -f2 || echo "")
PATCHLEVEL=$(grep -w '^PATCHLEVEL' Makefile | tr -d ' ' | cut -d= -f2 || echo "")
KERNEL_VERSION="${VERSION}.${PATCHLEVEL}"

if [ -z "$VERSION" ] || [ -z "$PATCHLEVEL" ]; then
 echo "[-] Error: Can not detect kernel version!" >&2
 exit 1
elif [[ ( "$VERSION" -eq "5" && "$PATCHLEVEL" -gt "4" ) || "$VERSION" -gt "5" ]]; then
 echo "[-] This script does not support GKI kernel ${KERNEL_VERSION}!" >&2
 exit 1
else
 echo "[+] Detected kernel ${KERNEL_VERSION}!"
fi

if [ ! -d "$KERNEL_DIR/KernelSU" ]; then
 echo "[+] Integrating KernelSU..."
 curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash >/dev/null 2>&1
elif [ -f "$KERNEL_DIR/KernelSU/kernel/Kbuild" ]; then
 sed -i 's|$(subst ",,$(CONFIG_KSU_FULL_NAME_FORMAT))|%TAG_NAME%-%COMMIT_SHA%-t.me/noforce2pay|' "$KERNEL_DIR/KernelSU/kernel/Kbuild"
 sed -i '/-dirty/d' "$KERNEL_DIR/KernelSU/kernel/Kbuild"
fi

if [[ "$VERSION" -eq "4" || "$KERNEL_VERSION" == "5.4" ]]; then
 REJECT_DIR="$KERNEL_DIR/patch_rejects"
 
 if [ ! -f "$KERNEL_DIR/.ksu_patch" ]; then
  echo "[+] Integrating SUSFS..."
  SUSFS_PATCH="susfs_patch_to_${KERNEL_VERSION}.patch"
  curl -LSsfO "https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/refs/heads/mainline/Patches/Patch/${SUSFS_PATCH}"
  patch -p1 < "$SUSFS_PATCH" || true
  rm -f "$SUSFS_PATCH"

  echo "[+] Integrating inline hook..."
  KSU_PATCH="susfs_inline_hook_patches.sh"
  curl -LSsfO "https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/refs/heads/mainline/Patches/${KSU_PATCH}"
  bash "$KSU_PATCH" >/dev/null 2>&1 && rm -f "$KSU_PATCH"
  
  touch .ksu_patch
 fi
 
 if find "$KERNEL_DIR" -path "$REJECT_DIR" -prune -o -name "*.rej" -print | grep -q "."; then
  echo "[-] Error: Failed to patch susfs into kernel, please patch manually!" >&2
  echo "[!] Collecting failed patches into $REJECT_DIR"
   mkdir -p "$REJECT_DIR"
  find "$KERNEL_DIR" -path "$REJECT_DIR" -prune -o -type f -name "*.rej" -print | while read -r rej_file; do
   rel_dir=$(dirname "${rej_file#$KERNEL_DIR/}")
   mkdir -p "$REJECT_DIR/$rel_dir"
   mv "$rej_file" "$REJECT_DIR/$rel_dir/"
  done
  exit 1
 fi
# if [ ! -f "${KERNEL_DIR}/arch/${ARCH}/configs/ksu-susfs.config" ]; then 
#  echo "[+] Appending KernelSU configurations..."
#  cat <<EOF > "${KERNEL_DIR}/arch/${ARCH}/configs/ksu-susfs.config"
#CONFIG_DEBUG_KERNEL=y
#CONFIG_KALLSYMS=y
#CONFIG_KALLSYMS_ALL=y
#CONFIG_KSU=y
#CONFIG_KSU_SUSFS=y
#CONFIG_KSU_SUSFS_SUS_PATH=y
#CONFIG_KSU_SUSFS_SUS_MOUNT=y
#CONFIG_KSU_SUSFS_SUS_KSTAT=y
#CONFIG_KSU_SUSFS_TRY_UMOUNT=y
#CONFIG_KSU_SUSFS_SPOOF_UNAME=y
#CONFIG_KSU_SUSFS_ENABLE_LOG=y
#CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
#CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
#CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
#CONFIG_KSU_SUSFS_SUS_MAP=y
#EOF
# fi
#elif [ "$KERNEL_VERSION" == "3.18" ]; then
# echo "[+] This script does not support SUSFS for kernel 3.18!"
# if [ ! -f "${KERNEL_DIR}/arch/${ARCH}/configs/ksu.config" ]; then
#  echo "[+] Appending KernelSU configurations..."
#  cat <<EOF > "${KERNEL_DIR}/arch/${ARCH}/configs/ksu.config"
#CONFIG_DEBUG_KERNEL=y
#CONFIG_KALLSYMS=y
#CONFIG_KALLSYMS_ALL=y
#CONFIG_KSU=y
#CONFIG_KSU_MANUAL_HOOK=y
#EOF
# fi
else
 echo "[-] This script does not support KernelSU for kernel ${KERNEL_VERSION}. Skipping KernelSU integration!"
fi

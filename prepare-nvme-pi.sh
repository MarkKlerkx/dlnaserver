#!/usr/bin/env bash
#
# setup-nvme-pi.sh
#
# End-to-end helper to get a fresh Raspberry Pi OS install working on an
# NVMe drive behind a PCIe switch (e.g. Pimoroni NVMe Base Duo).
#
# Run this FROM the currently booted system (e.g. the SD card), targeting
# a different, currently-inactive NVMe drive.
#
# What it does:
#   1. Installs rpi-imager and its dependencies (incl. the libOpenGL fix
#      needed to run rpi-imager --cli headless)
#   2. Lets you pick the target disk and an OS image, then flashes it
#      with `rpi-imager --cli --enable-writing-system-drives`
#   3. Mounts the freshly-flashed boot + root partitions
#   4. Adds the ASPM/power-management boot parameters to cmdline.txt
#      (needed for NVMe behind a PCIe switch like the Base Duo)
#   5. Enables SSH (flag file + direct systemd symlink)
#   6. Sets a root password and allows root login over SSH
#   7. If the CURRENTLY running system also sits behind an NVMe HAT/base,
#      applies the same ASPM fix to its own cmdline.txt (so the running
#      system stops fighting the same power-management issue too)
#   8. Sets the EEPROM boot order so the target NVMe disk is tried first
#      (non-interactively, via `rpi-eeprom-config --apply`)
#   9. Cleans up all mounts, even on error
#
# Usage:
#   sudo bash setup-nvme-pi.sh
#
set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}==>${NC} $*"; }
warn()  { echo -e "${YELLOW}!!${NC} $*"; }
err()   { echo -e "${RED}ERROR:${NC} $*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  err "This script must run as root. Use: sudo bash $0"
  exit 1
fi

MNT_BOOT="/mnt/nvme-boot-prep"
MNT_ROOT="/mnt/nvme-root-prep"

cleanup() {
  info "Cleaning up / unmounting..."
  umount "${MNT_ROOT}/dev" 2>/dev/null || true
  umount "${MNT_ROOT}/proc" 2>/dev/null || true
  umount "${MNT_ROOT}/sys" 2>/dev/null || true
  umount "${MNT_BOOT}" 2>/dev/null || true
  umount "${MNT_ROOT}" 2>/dev/null || true
}
trap cleanup EXIT

echo
echo -e "${BOLD}=== NVMe Raspberry Pi Setup Script ===${NC}"
echo

# -------------------------------------------------------------------------
# STEP 0: pick and confirm the target disk (used for both flashing and
# for the post-flash configuration, so we only ask once)
# -------------------------------------------------------------------------
info "Current disks:"
lsblk -f
echo

read -rp "Target disk name, without /dev/ (e.g. nvme1n1): " DISK_NAME
DISK_PATH="/dev/${DISK_NAME}"

if [ ! -b "${DISK_PATH}" ]; then
  err "${DISK_PATH} does not exist or is not a block device."
  exit 1
fi

CURRENT_ROOT_SRC=$(findmnt -n -o SOURCE / || true)
CURRENT_ROOT_DISK=$(lsblk -no PKNAME "${CURRENT_ROOT_SRC}" 2>/dev/null || true)
if [ "${DISK_NAME}" = "${CURRENT_ROOT_DISK}" ]; then
  err "That is the disk you are currently booted from! Choose a different one."
  exit 1
fi

echo
info "Partitions currently on ${DISK_PATH}:"
lsblk -f "${DISK_PATH}" || true
echo
warn "Everything on ${DISK_PATH} will be ERASED by the imaging step."
read -rp "Type YES to confirm this is the correct disk: " CONFIRM
if [ "${CONFIRM}" != "YES" ]; then
  warn "Cancelled by user."
  exit 1
fi

# -------------------------------------------------------------------------
# STEP 1: install rpi-imager + dependencies
# -------------------------------------------------------------------------
echo
info "Installing rpi-imager and dependencies..."
apt update
apt install -y rpi-imager

# Fix for: "error while loading shared libraries: libOpenGL.so.0"
# which happens when running rpi-imager --cli on a headless/minimal system.
if ! ldconfig -p | grep -q libOpenGL.so.0; then
  info "Installing libopengl0 (fixes libOpenGL.so.0 error in headless CLI mode)..."
  apt install -y libopengl0 || apt install -y libgl1 libglx-mesa0 || true
else
  info "libOpenGL.so.0 already present, skipping."
fi

# -------------------------------------------------------------------------
# STEP 2: choose an OS image and flash it
# -------------------------------------------------------------------------
echo
info "Choose the OS image to flash."
echo "  You can either paste a direct image URL/path, or press Enter to use"
echo "  the default Raspberry Pi OS Lite (64-bit) latest release."
echo
read -rp "Image URL or local path [default: RPi OS Lite 64-bit]: " IMAGE_SRC
if [ -z "${IMAGE_SRC}" ]; then
  IMAGE_SRC="https://downloads.raspberrypi.com/raspios_lite_arm64_latest"
fi

echo
info "About to flash:"
echo "    Image : ${IMAGE_SRC}"
echo "    Target: ${DISK_PATH}"
echo
read -rp "Type FLASH to start writing now: " FLASH_CONFIRM
if [ "${FLASH_CONFIRM}" != "FLASH" ]; then
  warn "Cancelled by user before flashing."
  exit 1
fi

info "Flashing image, this can take a few minutes..."
rpi-imager --cli --enable-writing-system-drives "${IMAGE_SRC}" "${DISK_PATH}"
info "Flashing complete."

# Give the kernel a moment to re-read the new partition table
partprobe "${DISK_PATH}" 2>/dev/null || true
udevadm settle 2>/dev/null || true
sleep 2

# -------------------------------------------------------------------------
# STEP 3: mount the freshly written boot + root partitions
# -------------------------------------------------------------------------
echo
info "Partitions on ${DISK_PATH} after flashing:"
lsblk -f "${DISK_PATH}"
echo

BOOT_PART=$(lsblk -ln -o NAME,FSTYPE "${DISK_PATH}" | awk '$2=="vfat"{print $1; exit}')
ROOT_PART=$(lsblk -ln -o NAME,FSTYPE "${DISK_PATH}" | awk '$2=="ext4"{print $1; exit}')

if [ -z "${BOOT_PART}" ] || [ -z "${ROOT_PART}" ]; then
  warn "Could not auto-detect boot/root partitions."
  lsblk "${DISK_PATH}"
  read -rp "Boot partition name (vfat), e.g. ${DISK_NAME}p1: " BOOT_PART
  read -rp "Root partition name (ext4), e.g. ${DISK_NAME}p2: " ROOT_PART
fi

BOOT_DEV="/dev/${BOOT_PART}"
ROOT_DEV="/dev/${ROOT_PART}"

info "Boot partition: ${BOOT_DEV}"
info "Root partition: ${ROOT_DEV}"
echo

mkdir -p "${MNT_BOOT}" "${MNT_ROOT}"
mount "${BOOT_DEV}" "${MNT_BOOT}"
mount "${ROOT_DEV}" "${MNT_ROOT}"

# -------------------------------------------------------------------------
# STEP 4: ASPM / power-management boot parameters
# -------------------------------------------------------------------------
CMDLINE="${MNT_BOOT}/cmdline.txt"
ASPM_PARAMS="nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off"

if [ ! -f "${CMDLINE}" ]; then
  err "cmdline.txt not found on ${MNT_BOOT}. Wrong partition?"
  exit 1
fi

if grep -q "pcie_aspm=off" "${CMDLINE}"; then
  info "ASPM parameters already present in cmdline.txt, nothing to do."
else
  sed -i "s/\$/ ${ASPM_PARAMS}/" "${CMDLINE}"
  info "ASPM parameters added to cmdline.txt"
fi

# -------------------------------------------------------------------------
# STEP 5: enable SSH
# -------------------------------------------------------------------------
touch "${MNT_BOOT}/ssh"
info "SSH flag file created (enables sshd on first boot)"

mkdir -p "${MNT_ROOT}/etc/systemd/system/multi-user.target.wants"
if [ -f "${MNT_ROOT}/lib/systemd/system/ssh.service" ]; then
  ln -sf /lib/systemd/system/ssh.service \
    "${MNT_ROOT}/etc/systemd/system/multi-user.target.wants/ssh.service"
  info "ssh.service enabled directly via systemd symlink"
else
  warn "ssh.service not found in image, skipping symlink step."
fi

# -------------------------------------------------------------------------
# STEP 6: root password + allow root SSH login
# -------------------------------------------------------------------------
echo
info "Set a root password for the new installation"
while true; do
  read -rsp "New root password: " ROOTPW
  echo
  read -rsp "Confirm password: " ROOTPW2
  echo
  if [ "${ROOTPW}" = "${ROOTPW2}" ] && [ -n "${ROOTPW}" ]; then
    break
  fi
  warn "Passwords do not match or are empty, try again."
done

# Password is piped via stdin to chpasswd, not passed as an argument,
# so it never shows up in the process list (ps aux) of this system.
printf '%s:%s\n' root "${ROOTPW}" | chroot "${MNT_ROOT}" chpasswd
chroot "${MNT_ROOT}" passwd -u root || true
unset ROOTPW ROOTPW2
info "Root password set and root account unlocked"

mkdir -p "${MNT_ROOT}/etc/ssh/sshd_config.d"
cat > "${MNT_ROOT}/etc/ssh/sshd_config.d/99-allow-root.conf" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF
info "SSH password login for root allowed (via sshd_config.d/99-allow-root.conf)"

# -------------------------------------------------------------------------
# STEP 7: apply the same ASPM fix to the CURRENTLY running system, if it
# also has NVMe devices visible (i.e. it is booted on the same NVMe
# base/HAT and may hit the same power-management issue while it's up).
# -------------------------------------------------------------------------
echo
CURRENT_CMDLINE="/boot/firmware/cmdline.txt"
OTHER_NVME_PRESENT=$(lsblk -dn -o NAME | grep -E '^nvme' | grep -v "^${DISK_NAME}$" || true)

if [ -n "${OTHER_NVME_PRESENT}" ] && [ -f "${CURRENT_CMDLINE}" ]; then
  info "This running system also sees other NVMe device(s): ${OTHER_NVME_PRESENT}"
  read -rp "Apply the same ASPM fix to THIS system's own cmdline.txt too? [y/N]: " APPLY_HERE
  if [[ "${APPLY_HERE}" =~ ^[Yy]$ ]]; then
    if grep -q "pcie_aspm=off" "${CURRENT_CMDLINE}"; then
      info "ASPM parameters already present in the current system's cmdline.txt."
    else
      cp "${CURRENT_CMDLINE}" "${CURRENT_CMDLINE}.bak-$(date +%Y%m%d%H%M%S)"
      sed -i "s/\$/ ${ASPM_PARAMS}/" "${CURRENT_CMDLINE}"
      info "ASPM parameters added to the current system's cmdline.txt (backup saved alongside it)."
      warn "This will take effect on this system's next reboot."
    fi
  else
    info "Skipped patching the currently running system."
  fi
else
  info "No other NVMe devices visible on the running system, skipping this step."
fi

# -------------------------------------------------------------------------
# STEP 8: set the EEPROM boot order so the target NVMe disk boots first
# -------------------------------------------------------------------------
echo
info "Setting boot order so ${DISK_PATH} is tried first on next boot..."

if ! command -v rpi-eeprom-config >/dev/null 2>&1; then
  warn "rpi-eeprom-config not found, skipping automatic boot order change."
  warn "Set it manually with: sudo raspi-config -> Advanced Options -> Boot Order"
else
  TMP_EEPROM_CONF=$(mktemp)
  rpi-eeprom-config > "${TMP_EEPROM_CONF}" 2>/dev/null || echo "[all]" > "${TMP_EEPROM_CONF}"

  # BOOT_ORDER=0xf416, read right-to-left: 6=NVMe, 1=SD, 4=USB, f=repeat.
  # This tries NVMe first, falls back to SD, then USB, then restarts the cycle.
  if grep -q "^BOOT_ORDER=" "${TMP_EEPROM_CONF}"; then
    sed -i "s/^BOOT_ORDER=.*/BOOT_ORDER=0xf416/" "${TMP_EEPROM_CONF}"
  else
    echo "BOOT_ORDER=0xf416" >> "${TMP_EEPROM_CONF}"
  fi

  if rpi-eeprom-config --apply "${TMP_EEPROM_CONF}" >/dev/null 2>&1; then
    info "Boot order updated (BOOT_ORDER=0xf416: NVMe -> SD -> USB)."
    warn "This EEPROM change is applied on the NEXT reboot of this Pi."
  else
    warn "Automatic EEPROM update failed. Set it manually with:"
    warn "  sudo raspi-config -> Advanced Options -> Boot Order -> NVMe/USB Boot"
  fi
  rm -f "${TMP_EEPROM_CONF}"
fi

# -------------------------------------------------------------------------
# Done
# -------------------------------------------------------------------------
echo
info "All steps completed successfully."
warn "Root login over SSH is convenient for troubleshooting, but not ideal"
warn "for permanent use. Consider creating a normal user later and removing"
warn "/etc/ssh/sshd_config.d/99-allow-root.conf once everything is confirmed working."
echo
info "Just reboot this Pi now — it will boot from ${DISK_PATH} automatically:"
echo "    sudo reboot"
echo
info "After that you should be able to log in with: ssh root@<pi-ip-address>"

#!/usr/bin/env bash
#
# setup-sacd-dlna.sh
#
# Sets up the complete SACD DLNA server, with confirmation at every step:
#   1. Install Docker + Docker Compose
#   2. Create folder structure: /dlna/data, /dlna/logs, /dlna/isos
#   3. Choose the data disk, format it, and mount it on /dlna/isos
#   4. Generate docker-compose.yml (with a choice of image registry) and
#      start the container
#   5. Optimizations for the container itself (logging, ulimits, inotify)
#   6. Fan tuning for the Raspberry Pi 5 Active Cooler
#   7. Other recommended optimizations (TRIM, swappiness, log rotation)
#
# Usage:
#   sudo bash setup-sacd-dlna.sh
#
set -uo pipefail

# Prevent needrestart (present by default on Debian trixie / recent Raspberry
# Pi OS) from popping up an interactive "which services to restart?" prompt
# during apt installs below, which would otherwise make the script appear
# to hang while it's actually waiting for input.
export NEEDRESTART_MODE=a
export DEBIAN_FRONTEND=noninteractive

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${GREEN}==>${NC} $*"; }
warn()    { echo -e "${YELLOW}!!${NC} $*"; }
err()     { echo -e "${RED}ERROR:${NC} $*" >&2; }
section() { echo; echo -e "${BOLD}${CYAN}### $* ###${NC}"; echo; }

confirm() {
  local prompt="$1"
  local answer
  read -rp "$(echo -e "${YELLOW}?${NC} ${prompt} [y/N]: ")" answer
  [[ "${answer}" =~ ^[Yy]$ ]]
}

if [ "$(id -u)" -ne 0 ]; then
  err "This script must run as root. Use: sudo bash $0"
  exit 1
fi

echo -e "${BOLD}=== SACD DLNA Server Setup ===${NC}"
echo "This script walks through 7 steps. At each step you'll first see what"
echo "is about to happen, and you must explicitly confirm before it runs."
echo

# =========================================================================
# STEP 1: Install Docker
# =========================================================================
section "STEP 1: Install Docker + Docker Compose"

if command -v docker >/dev/null 2>&1; then
  info "Docker is already installed: $(docker --version)"
else
  echo "This installs Docker via the official docker.com install script"
  echo "(curl -fsSL https://get.docker.com | sh), and enables the docker service."
  if confirm "Install Docker now?"; then
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
    systemctl enable --now docker
    info "Docker installed: $(docker --version)"
  else
    err "Docker is required for the rest of this script. Stopping."
    exit 1
  fi
fi

if docker compose version >/dev/null 2>&1; then
  info "Docker Compose plugin present: $(docker compose version)"
else
  warn "Docker Compose plugin not found, attempting to install it..."
  apt update && apt install -y docker-compose-plugin
fi

# =========================================================================
# STEP 2: Create folder structure
# =========================================================================
section "STEP 2: Create folder structure"

echo "This creates the following folders (if not already present):"
echo "    /dlna/data"
echo "    /dlna/logs"
echo "    /dlna/isos"
if confirm "Create these folders?"; then
  mkdir -p /dlna/data /dlna/logs /dlna/isos
  info "Folders created under /dlna"
  ls -la /dlna
else
  err "These folders are required for the rest of the script. Stopping."
  exit 1
fi

# =========================================================================
# STEP 3: Select, format and mount the data disk
# =========================================================================
section "STEP 3: Choose the data disk, format it and mount on /dlna/isos"

info "Current disks:"
lsblk -f
echo

read -rp "Name of the data disk for the ISOs, without /dev/ (e.g. nvme0n1): " DATA_DISK
DATA_DISK_PATH="/dev/${DATA_DISK}"

if [ ! -b "${DATA_DISK_PATH}" ]; then
  err "${DATA_DISK_PATH} does not exist or is not a block device."
  exit 1
fi

CURRENT_ROOT_SRC=$(findmnt -n -o SOURCE / || true)
CURRENT_ROOT_DISK=$(lsblk -no PKNAME "${CURRENT_ROOT_SRC}" 2>/dev/null || true)
if [ "${DATA_DISK}" = "${CURRENT_ROOT_DISK}" ]; then
  err "That is the disk you are currently booted from! Choose the other (data) disk."
  exit 1
fi

echo
info "Partitions on ${DATA_DISK_PATH}:"
lsblk -f "${DATA_DISK_PATH}" || true
echo
warn "Everything on ${DATA_DISK_PATH} will be PERMANENTLY erased."
read -rp "Type FORMAT to confirm this is the correct disk to wipe: " FORMAT_CONFIRM

if [ "${FORMAT_CONFIRM}" != "FORMAT" ]; then
  err "Not confirmed. Stopping without touching the disk."
  exit 1
fi

info "Unmounting any existing mounts on ${DATA_DISK_PATH} (if active)..."
for part in $(lsblk -ln -o NAME "${DATA_DISK_PATH}" | tail -n +2); do
  umount "/dev/${part}" 2>/dev/null || true
done

info "Wiping disk and creating a new GPT partition table..."
wipefs -a "${DATA_DISK_PATH}"
parted -s "${DATA_DISK_PATH}" mklabel gpt
parted -s "${DATA_DISK_PATH}" mkpart primary ext4 0% 100%

partprobe "${DATA_DISK_PATH}" 2>/dev/null || true
udevadm settle 2>/dev/null || true
sleep 2

DATA_PART=$(lsblk -ln -o NAME "${DATA_DISK_PATH}" | sed -n '2p')
DATA_PART_PATH="/dev/${DATA_PART}"

if [ -z "${DATA_PART}" ] || [ ! -b "${DATA_PART_PATH}" ]; then
  err "Could not find the new partition on ${DATA_DISK_PATH}."
  exit 1
fi

info "New partition: ${DATA_PART_PATH}"
info "Formatting as ext4 with label 'isos'..."
mkfs.ext4 -F -L isos "${DATA_PART_PATH}"

info "Mounting on /dlna/isos..."
mount "${DATA_PART_PATH}" /dlna/isos

DATA_UUID=$(blkid -s UUID -o value "${DATA_PART_PATH}")
if [ -z "${DATA_UUID}" ]; then
  err "Could not find a UUID for ${DATA_PART_PATH}, skipping fstab entry."
else
  if grep -q "${DATA_UUID}" /etc/fstab; then
    info "fstab already contains an entry for this UUID, skipping."
  else
    # noatime/nodiratime: fewer unnecessary writes to the SSD while reading
    # ISOs / scanning the library (see step 7 for more SSD tuning)
    echo "UUID=${DATA_UUID}  /dlna/isos  ext4  defaults,noatime,nodiratime,nofail  0  2" >> /etc/fstab
    info "Entry added to /etc/fstab (with noatime to reduce write overhead)"
  fi
fi

df -h /dlna/isos
info "Data disk ready and mounted on /dlna/isos"

# =========================================================================
# STEP 4: Choose image source and generate docker-compose.yml
# =========================================================================
section "STEP 4: Choose image source, generate docker-compose.yml and start"

DEFAULT_IMAGE="markklerkx/sacdlibrary:latest"

echo "Which image source do you want to use for the SACD Library container?"
echo "  1) Docker Hub (default): ${DEFAULT_IMAGE}"
echo "  2) Custom registry (e.g. your own local registry, for faster pulls)"
echo
read -rp "Choice [1/2, default 1]: " REGISTRY_CHOICE
REGISTRY_CHOICE="${REGISTRY_CHOICE:-1}"

if [ "${REGISTRY_CHOICE}" = "2" ]; then
  echo
  echo "Enter the full image reference, including your registry host."
  echo "Example: registry.local:5000/markklerkx/sacdlibrary:latest"
  read -rp "Image reference: " CUSTOM_IMAGE
  if [ -z "${CUSTOM_IMAGE}" ]; then
    warn "No image reference entered, falling back to Docker Hub default."
    IMAGE="${DEFAULT_IMAGE}"
  else
    IMAGE="${CUSTOM_IMAGE}"
  fi
else
  IMAGE="${DEFAULT_IMAGE}"
fi

info "Using image: ${IMAGE}"

COMPOSE_FILE="/dlna/docker-compose.yml"

echo
echo "This will write the following compose file to ${COMPOSE_FILE}:"
echo
cat <<PREVIEW
services:
  sacd-dlna:
    image: ${IMAGE}
    container_name: sacd-dlna
    restart: unless-stopped
    network_mode: host
    volumes:
      - /dlna/data:/data
      - /dlna/isos:/media/isos
      - /dlna/logs:/var/log/sacd-dlna
    environment:
      - SACD_ISO_DIR=/media/isos
      - SACD_DATA_DIR=/data
      - SACD_DB_PATH=/data/library.db
      - SACD_PORT=8080
      - SACD_UPNP_PORT=8200
      - SACD_LOG_DIR=/var/log/sacd-dlna
      - SACD_AUTO_SCAN_ENABLED=true
      - SACD_AUTO_SCAN_INTERVAL_SEC=3600
      - TZ=Europe/Amsterdam
PREVIEW
echo
warn "Note: network mode is 'host' — required for UPnP/DLNA discovery (SSDP"
warn "broadcasts don't work reliably behind Docker's default bridge network)."

if confirm "Write this compose file and start the container?"; then
  cat > "${COMPOSE_FILE}" <<EOF
services:
  sacd-dlna:
    image: ${IMAGE}
    container_name: sacd-dlna
    restart: unless-stopped
    network_mode: host
    volumes:
      - /dlna/data:/data
      - /dlna/isos:/media/isos
      - /dlna/logs:/var/log/sacd-dlna
    environment:
      - SACD_ISO_DIR=/media/isos
      - SACD_DATA_DIR=/data
      - SACD_DB_PATH=/data/library.db
      - SACD_PORT=8080
      - SACD_UPNP_PORT=8200
      - SACD_LOG_DIR=/var/log/sacd-dlna
      - SACD_AUTO_SCAN_ENABLED=true
      - SACD_AUTO_SCAN_INTERVAL_SEC=3600
      - TZ=Europe/Amsterdam
EOF
  info "Compose file written to ${COMPOSE_FILE}"

  info "Pulling image and starting container (this may take a while)..."
  (cd /dlna && docker compose pull && docker compose up -d)
  info "Container started. Status:"
  docker ps --filter "name=sacd-dlna"
else
  warn "Skipped. You can do this manually later with:"
  warn "  cd /dlna && docker compose up -d"
fi

# =========================================================================
# STEP 5: Container optimizations
# =========================================================================
section "STEP 5: Optimizations for the SACD container"

echo "This adds the following optimizations to ${COMPOSE_FILE}:"
echo "  - logging: max 10MB per log file, max 3 files (prevents disk from"
echo "    filling up with endlessly growing container logs)"
echo "  - ulimits: nofile 65536 (needed because the library scan may need to"
echo "    have thousands of ISO files open at the same time)"
echo "  - increase fs.inotify.max_user_watches on the host (so the container"
echo "    can keep detecting changes in a large ISO collection without errors)"
echo

if confirm "Apply these optimizations?"; then
  if [ -f "${COMPOSE_FILE}" ] && ! grep -q "ulimits:" "${COMPOSE_FILE}"; then
    # Insert logging + ulimits under the service, preserving existing content
    python3 - "${COMPOSE_FILE}" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

addition = """    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
"""

lines = content.splitlines(keepends=True)
out = []
inserted = False
for line in lines:
    out.append(line)
    if line.strip().startswith("- TZ=Europe/Amsterdam") and not inserted:
        out.append(addition)
        inserted = True

with open(path, "w") as f:
    f.writelines(out)

print("inserted" if inserted else "not-inserted")
PYEOF
    info "logging + ulimits added to ${COMPOSE_FILE}"
  else
    info "Optimizations are already present in the compose file, or the file doesn't exist yet."
  fi

  mkdir -p /etc/sysctl.d
  cat > /etc/sysctl.d/99-dlna.conf <<'EOF'
# Increased inotify watches: needed to live-track changes in a large ISO
# library without hitting "no space left on device" inotify errors.
fs.inotify.max_user_watches=1048576
EOF
  sysctl --system >/dev/null 2>&1
  info "fs.inotify.max_user_watches increased to 1048576"

  if [ -f "${COMPOSE_FILE}" ] && docker compose -f "${COMPOSE_FILE}" ps --status running 2>/dev/null | grep -q sacd-dlna; then
    if confirm "Restart the container to apply the new compose settings?"; then
      (cd /dlna && docker compose up -d)
      info "Container restarted with the new settings."
    fi
  fi
else
  info "Container optimizations skipped."
fi

# =========================================================================
# STEP 6: Fan tuning for the Raspberry Pi 5 Active Cooler
# =========================================================================
section "STEP 6: Fan tuning (Raspberry Pi 5 Active Cooler)"

CONFIG_TXT="/boot/firmware/config.txt"

echo "A 24/7 media server in an enclosed case benefits from a slightly"
echo "earlier/more aggressive fan curve than the Raspberry Pi default,"
echo "to avoid the CPU throttling during library scans/transcodes."
echo
echo "This adds the following lines to ${CONFIG_TXT} (under [all]):"
cat <<'FANPREVIEW'
    dtparam=cooling_fan=on
    dtparam=fan_temp0=45000
    dtparam=fan_temp0_hyst=5000
    dtparam=fan_temp0_speed=60
    dtparam=fan_temp1=55000
    dtparam=fan_temp1_hyst=5000
    dtparam=fan_temp1_speed=120
    dtparam=fan_temp2=65000
    dtparam=fan_temp2_hyst=5000
    dtparam=fan_temp2_speed=180
    dtparam=fan_temp3=75000
    dtparam=fan_temp3_hyst=5000
    dtparam=fan_temp3_speed=255
FANPREVIEW
echo
warn "Only relevant if you're using the official Raspberry Pi 5 Active Cooler."
warn "Using a different fan, or none at all? Skip this step."

if confirm "Add this fan curve to config.txt?"; then
  if [ ! -f "${CONFIG_TXT}" ]; then
    err "${CONFIG_TXT} not found, skipping this step."
  elif grep -q "^dtparam=fan_temp0=" "${CONFIG_TXT}"; then
    info "A fan_temp0 setting already exists in config.txt, nothing changed."
    warn "Adjust it manually in ${CONFIG_TXT} if needed."
  else
    cp "${CONFIG_TXT}" "${CONFIG_TXT}.bak-$(date +%Y%m%d%H%M%S)"
    cat >> "${CONFIG_TXT}" <<'EOF'

# --- SACD DLNA server: slightly earlier/more aggressive fan curve ---
dtparam=cooling_fan=on
dtparam=fan_temp0=45000
dtparam=fan_temp0_hyst=5000
dtparam=fan_temp0_speed=60
dtparam=fan_temp1=55000
dtparam=fan_temp1_hyst=5000
dtparam=fan_temp1_speed=120
dtparam=fan_temp2=65000
dtparam=fan_temp2_hyst=5000
dtparam=fan_temp2_speed=180
dtparam=fan_temp3=75000
dtparam=fan_temp3_hyst=5000
dtparam=fan_temp3_speed=255
EOF
    info "Fan curve added to ${CONFIG_TXT} (backup saved alongside it)."
    warn "Takes effect only after a reboot."
  fi
else
  info "Fan tuning skipped."
fi

# =========================================================================
# STEP 7: Other recommended optimizations
# =========================================================================
section "STEP 7: Other recommended optimizations"

echo "This performs the following extra optimizations:"
echo "  - enable fstrim.timer: periodic TRIM for both NVMe disks, good for"
echo "    long-term SSD lifespan and write performance"
echo "  - lower vm.swappiness to 10: avoids unnecessary swapping to the zram"
echo "    swap (you have plenty of RAM; prefer keeping cache in RAM over swapping)"
echo "  - set Docker's global log rotation in /etc/docker/daemon.json:"
echo "    so future containers (not just sacd-dlna) can never write unlimited"
echo "    logs and fill up the disk either"
echo

if confirm "Apply these extra optimizations?"; then
  systemctl enable --now fstrim.timer
  info "fstrim.timer enabled (weekly TRIM, default systemd schedule)"

  if ! grep -q "vm.swappiness" /etc/sysctl.d/99-dlna.conf 2>/dev/null; then
    echo "vm.swappiness=10" >> /etc/sysctl.d/99-dlna.conf
    sysctl --system >/dev/null 2>&1
    info "vm.swappiness set to 10"
  else
    info "vm.swappiness was already set, nothing changed."
  fi

  if [ ! -f /etc/docker/daemon.json ]; then
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    info "/etc/docker/daemon.json created with global log rotation"
    if confirm "Restart Docker to apply this setting? (restarts all containers)"; then
      systemctl restart docker
      info "Docker restarted."
    else
      warn "Don't forget later: sudo systemctl restart docker"
    fi
  else
    info "/etc/docker/daemon.json already exists, not overwritten (avoids conflicts)."
  fi
else
  info "Extra optimizations skipped."
fi

# =========================================================================
# Done
# =========================================================================
section "Done"

info "Summary:"
echo "  - Docker             : $(command -v docker >/dev/null 2>&1 && echo present || echo NOT installed)"
echo "  - /dlna folders       : $([ -d /dlna/isos ] && echo present || echo missing)"
echo "  - Data disk mounted  : $(mountpoint -q /dlna/isos && echo yes || echo no) on /dlna/isos"
echo "  - Compose file       : ${COMPOSE_FILE}"
echo "  - Image used         : ${IMAGE:-not set}"
echo "  - Container status   : $(docker ps --filter name=sacd-dlna --format '{{.Status}}' 2>/dev/null || echo 'not found')"
echo
info "If config.txt or daemon.json were changed: a reboot is recommended"
info "to fully apply all changes (fan curve, Docker logging)."
echo "    sudo reboot"
echo
info "After the reboot, the web interface will be available at: http://<pi-ip>:8080"

#!/usr/bin/env bash
#
# setup-sacd-dlna.sh
#
# Zet de complete SACD DLNA-server op, met bevestiging per stap:
#   1. Docker + Docker Compose installeren
#   2. Mapstructuur aanmaken: /dlna/data, /dlna/logs, /dlna/isos
#   3. Datadisk kiezen, formatteren en mounten op /dlna/isos
#   4. docker-compose.yml genereren en de container starten
#   5. Optimalisaties voor de container zelf (logging, ulimits, inotify)
#   6. Fan-tuning voor de Raspberry Pi 5 Active Cooler
#   7. Overige aanbevolen optimalisaties (TRIM, swappiness, log-rotatie)
#
# Gebruik:
#   sudo bash setup-sacd-dlna.sh
#
set -uo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${GREEN}==>${NC} $*"; }
warn()    { echo -e "${YELLOW}!!${NC} $*"; }
err()     { echo -e "${RED}FOUT:${NC} $*" >&2; }
section() { echo; echo -e "${BOLD}${CYAN}### $* ###${NC}"; echo; }

confirm() {
  local prompt="$1"
  local answer
  read -rp "$(echo -e "${YELLOW}?${NC} ${prompt} [y/N]: ")" answer
  [[ "${answer}" =~ ^[Jj][Aa]?$|^[Yy]$ ]]
}

if [ "$(id -u)" -ne 0 ]; then
  err "Dit script moet als root draaien. Gebruik: sudo bash $0"
  exit 1
fi

echo -e "${BOLD}=== SACD DLNA Server Setup ===${NC}"
echo "Dit script doorloopt 7 stappen. Bij elke stap zie je eerst wat er"
echo "gaat gebeuren, en moet je expliciet bevestigen voordat het uitgevoerd wordt."
echo

# =========================================================================
# STAP 1: Docker installeren
# =========================================================================
section "STAP 1: Docker + Docker Compose installeren"

if command -v docker >/dev/null 2>&1; then
  info "Docker is al geïnstalleerd: $(docker --version)"
else
  echo "Dit installeert Docker via het officiële installatiescript van docker.com"
  echo "(curl -fsSL https://get.docker.com | sh), en zet de docker-service aan."
  if confirm "Docker nu installeren?"; then
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
    systemctl enable --now docker
    info "Docker geïnstalleerd: $(docker --version)"
  else
    err "Docker is vereist voor de rest van dit script. Stoppen."
    exit 1
  fi
fi

if docker compose version >/dev/null 2>&1; then
  info "Docker Compose plugin aanwezig: $(docker compose version)"
else
  warn "Docker Compose plugin niet gevonden, probeer alsnog te installeren..."
  apt update && apt install -y docker-compose-plugin
fi

# =========================================================================
# STAP 2: Mapstructuur aanmaken
# =========================================================================
section "STAP 2: Mapstructuur aanmaken"

echo "Dit maakt de volgende mappen aan (indien nog niet aanwezig):"
echo "    /dlna/data"
echo "    /dlna/logs"
echo "    /dlna/isos"
if confirm "Mappen aanmaken?"; then
  mkdir -p /dlna/data /dlna/logs /dlna/isos
  info "Mappen aangemaakt onder /dlna"
  ls -la /dlna
else
  err "Deze mappen zijn nodig voor de rest van het script. Stoppen."
  exit 1
fi

# =========================================================================
# STAP 3: Datadisk selecteren, formatteren en mounten
# =========================================================================
section "STAP 3: Datadisk kiezen, formatteren en mounten op /dlna/isos"

info "Huidige schijven:"
lsblk -f
echo

read -rp "Naam van de datadisk voor de ISO's, zonder /dev/ (bv. nvme0n1): " DATA_DISK
DATA_DISK_PATH="/dev/${DATA_DISK}"

if [ ! -b "${DATA_DISK_PATH}" ]; then
  err "${DATA_DISK_PATH} bestaat niet of is geen block-device."
  exit 1
fi

CURRENT_ROOT_SRC=$(findmnt -n -o SOURCE / || true)
CURRENT_ROOT_DISK=$(lsblk -no PKNAME "${CURRENT_ROOT_SRC}" 2>/dev/null || true)
if [ "${DATA_DISK}" = "${CURRENT_ROOT_DISK}" ]; then
  err "Dit is de schijf waar je nu vanaf boot! Kies de andere (data-)schijf."
  exit 1
fi

echo
info "Partities op ${DATA_DISK_PATH}:"
lsblk -f "${DATA_DISK_PATH}" || true
echo
warn "Alles op ${DATA_DISK_PATH} wordt hierbij ONHERROEPELIJK gewist."
read -rp "Typ FORMAT om te bevestigen dat dit de juiste, te wissen schijf is: " FORMAT_CONFIRM

if [ "${FORMAT_CONFIRM}" != "FORMAT" ]; then
  err "Niet bevestigd. Stoppen zonder de disk aan te passen."
  exit 1
fi

info "Bestaande mounts van ${DATA_DISK_PATH} ontkoppelen (indien actief)..."
for part in $(lsblk -ln -o NAME "${DATA_DISK_PATH}" | tail -n +2); do
  umount "/dev/${part}" 2>/dev/null || true
done

info "Schijf wissen en nieuwe GPT-partitietabel aanmaken..."
wipefs -a "${DATA_DISK_PATH}"
parted -s "${DATA_DISK_PATH}" mklabel gpt
parted -s "${DATA_DISK_PATH}" mkpart primary ext4 0% 100%

partprobe "${DATA_DISK_PATH}" 2>/dev/null || true
udevadm settle 2>/dev/null || true
sleep 2

DATA_PART=$(lsblk -ln -o NAME "${DATA_DISK_PATH}" | sed -n '2p')
DATA_PART_PATH="/dev/${DATA_PART}"

if [ -z "${DATA_PART}" ] || [ ! -b "${DATA_PART_PATH}" ]; then
  err "Kon de nieuwe partitie niet vinden op ${DATA_DISK_PATH}."
  exit 1
fi

info "Nieuwe partitie: ${DATA_PART_PATH}"
info "Formatteren als ext4 met label 'isos'..."
mkfs.ext4 -F -L isos "${DATA_PART_PATH}"

info "Mounten op /dlna/isos..."
mount "${DATA_PART_PATH}" /dlna/isos

DATA_UUID=$(blkid -s UUID -o value "${DATA_PART_PATH}")
if [ -z "${DATA_UUID}" ]; then
  err "Kon geen UUID vinden voor ${DATA_PART_PATH}, fstab-regel wordt overgeslagen."
else
  if grep -q "${DATA_UUID}" /etc/fstab; then
    info "fstab bevat al een regel voor deze UUID, sla toevoegen over."
  else
    # noatime/nodiratime: minder onnodige schrijfacties op de SSD bij het
    # lezen van ISO's/scannen van de bibliotheek (zie stap 7 voor meer SSD-tuning)
    echo "UUID=${DATA_UUID}  /dlna/isos  ext4  defaults,noatime,nodiratime,nofail  0  2" >> /etc/fstab
    info "Regel toegevoegd aan /etc/fstab (met noatime voor minder schrijf-overhead)"
  fi
fi

df -h /dlna/isos
info "Datadisk gereed en gemount op /dlna/isos"

# =========================================================================
# STAP 4: docker-compose.yml genereren en container starten
# =========================================================================
section "STAP 4: SACD Library docker-compose.yml genereren en starten"

COMPOSE_FILE="/dlna/docker-compose.yml"

echo "Dit schrijft het volgende compose-bestand naar ${COMPOSE_FILE}:"
echo
cat <<'PREVIEW'
services:
  sacd-dlna:
    image: markklerkx/sacdlibrary:latest
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
warn "Let op: netwerkmodus is 'host' — nodig voor UPnP/DLNA discovery (SSDP-broadcasts"
warn "werken niet betrouwbaar achter Docker's standaard bridge-netwerk)."

if confirm "Dit compose-bestand wegschrijven en de container starten?"; then
  cat > "${COMPOSE_FILE}" <<'EOF'
services:
  sacd-dlna:
    image: markklerkx/sacdlibrary:latest
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
  info "Compose-bestand geschreven naar ${COMPOSE_FILE}"

  info "Image pullen en container starten (dit kan even duren)..."
  (cd /dlna && docker compose pull && docker compose up -d)
  info "Container gestart. Status:"
  docker ps --filter "name=sacd-dlna"
else
  warn "Overgeslagen. Je kunt dit later handmatig doen met:"
  warn "  cd /dlna && docker compose up -d"
fi

# =========================================================================
# STAP 5: Container-optimalisaties
# =========================================================================
section "STAP 5: Optimalisaties voor de SACD-container"

echo "Dit voegt de volgende optimalisaties toe aan ${COMPOSE_FILE}:"
echo "  - logging: max 10MB per logbestand, max 3 bestanden (voorkomt volle schijf"
echo "    door eindeloos groeiende container-logs)"
echo "  - ulimits: nofile 65536 (nodig omdat de bibliotheek-scan mogelijk duizenden"
echo "    ISO-bestanden tegelijk open moet kunnen hebben)"
echo "  - fs.inotify.max_user_watches verhogen op de host (nodig zodat de container"
echo "    changes in een grote ISO-collectie kan blijven detecteren zonder errors)"
echo

if confirm "Deze optimalisaties toepassen?"; then
  if [ -f "${COMPOSE_FILE}" ] && ! grep -q "ulimits:" "${COMPOSE_FILE}"; then
    # Voeg logging + ulimits toe onder de service, met behoud van bestaande inhoud
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
    info "logging + ulimits toegevoegd aan ${COMPOSE_FILE}"
  else
    info "Optimalisaties staan al in het compose-bestand, of het bestand ontbreekt nog."
  fi

  mkdir -p /etc/sysctl.d
  cat > /etc/sysctl.d/99-dlna.conf <<'EOF'
# Verhoogde inotify-watches: nodig voor het live volgen van wijzigingen
# in een grote ISO-bibliotheek zonder "no space left on device" inotify-errors.
fs.inotify.max_user_watches=1048576
EOF
  sysctl --system >/dev/null 2>&1
  info "fs.inotify.max_user_watches verhoogd naar 1048576"

  if [ -f "${COMPOSE_FILE}" ] && docker compose -f "${COMPOSE_FILE}" ps --status running 2>/dev/null | grep -q sacd-dlna; then
    if confirm "Container herstarten om de nieuwe compose-instellingen toe te passen?"; then
      (cd /dlna && docker compose up -d)
      info "Container herstart met nieuwe instellingen."
    fi
  fi
else
  info "Container-optimalisaties overgeslagen."
fi

# =========================================================================
# STAP 6: Fan-tuning voor de Raspberry Pi 5 Active Cooler
# =========================================================================
section "STAP 6: Fan-tuning (Raspberry Pi 5 Active Cooler)"

CONFIG_TXT="/boot/firmware/config.txt"

echo "Een 24/7-mediaserver in een gesloten behuizing profiteert van een iets"
echo "eerder/agressiever aangezette fan-curve dan de Raspberry Pi-standaard,"
echo "om te voorkomen dat de CPU tijdens library-scans/transcodes gaat throttlen."
echo
echo "Dit voegt de volgende regels toe aan ${CONFIG_TXT} (onder [all]):"
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
warn "Alleen relevant als je de officiële Raspberry Pi 5 Active Cooler gebruikt."
warn "Heb je een andere/geen fan? Sla deze stap dan over."

if confirm "Deze fan-curve toevoegen aan config.txt?"; then
  if [ ! -f "${CONFIG_TXT}" ]; then
    err "${CONFIG_TXT} niet gevonden, sla deze stap over."
  elif grep -q "^dtparam=fan_temp0=" "${CONFIG_TXT}"; then
    info "Er staat al een fan_temp0-instelling in config.txt, niks gewijzigd."
    warn "Pas deze zo nodig handmatig aan in ${CONFIG_TXT}."
  else
    cp "${CONFIG_TXT}" "${CONFIG_TXT}.bak-$(date +%Y%m%d%H%M%S)"
    cat >> "${CONFIG_TXT}" <<'EOF'

# --- SACD DLNA server: iets vroegere/agressievere fan-curve ---
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
    info "Fan-curve toegevoegd aan ${CONFIG_TXT} (backup ernaast opgeslagen)."
    warn "Wordt pas actief na een reboot."
  fi
else
  info "Fan-tuning overgeslagen."
fi

# =========================================================================
# STAP 7: Overige aanbevolen optimalisaties
# =========================================================================
section "STAP 7: Overige aanbevolen optimalisaties"

echo "Dit voert de volgende extra optimalisaties door:"
echo "  - fstrim.timer inschakelen: periodieke TRIM voor beide NVMe-schijven,"
echo "    goed voor levensduur en schrijfprestaties van SSD's op de lange termijn"
echo "  - vm.swappiness verlagen naar 10: voorkomt onnodig swappen naar de zram-swap"
echo "    (je hebt RAM genoeg; liever cache in RAM houden dan wisselen)"
echo "  - Docker's globale log-rotatie instellen in /etc/docker/daemon.json:"
echo "    zodat OOK toekomstige containers (niet alleen sacd-dlna) nooit"
echo "    ongelimiteerd logs kunnen schrijven en de schijf vol laten lopen"
echo

if confirm "Deze extra optimalisaties toepassen?"; then
  systemctl enable --now fstrim.timer
  info "fstrim.timer ingeschakeld (wekelijkse TRIM, standaard systemd-schema)"

  if ! grep -q "vm.swappiness" /etc/sysctl.d/99-dlna.conf 2>/dev/null; then
    echo "vm.swappiness=10" >> /etc/sysctl.d/99-dlna.conf
    sysctl --system >/dev/null 2>&1
    info "vm.swappiness ingesteld op 10"
  else
    info "vm.swappiness stond al ingesteld, niks gewijzigd."
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
    info "/etc/docker/daemon.json aangemaakt met globale log-rotatie"
    if confirm "Docker herstarten om deze instelling toe te passen? (herstart alle containers)"; then
      systemctl restart docker
      info "Docker herstart."
    else
      warn "Vergeet niet later: sudo systemctl restart docker"
    fi
  else
    info "/etc/docker/daemon.json bestaat al, niet overschreven (voorkomt conflicten)."
  fi
else
  info "Extra optimalisaties overgeslagen."
fi

# =========================================================================
# Klaar
# =========================================================================
section "Klaar"

info "Overzicht:"
echo "  - Docker            : $(command -v docker >/dev/null 2>&1 && echo aanwezig || echo NIET geïnstalleerd)"
echo "  - Mappen /dlna       : $([ -d /dlna/isos ] && echo aanwezig || echo ontbreken)"
echo "  - Datadisk gemount   : $(mountpoint -q /dlna/isos && echo ja || echo nee) op /dlna/isos"
echo "  - Compose-bestand    : ${COMPOSE_FILE}"
echo "  - Container status   : $(docker ps --filter name=sacd-dlna --format '{{.Status}}' 2>/dev/null || echo 'niet gevonden')"
echo
info "Als config.txt of daemon.json is aangepast: een reboot wordt aangeraden"
info "om alle wijzigingen (fan-curve, Docker-logging) volledig te laten landen."
echo "    sudo reboot"
echo
info "Na de reboot is de webinterface te bereiken op: http://<pi-ip>:8080"

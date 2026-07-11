# dlnaserver
DLNA server with on-memory SACD ISO mapper

# Prepare script
Run prepare-nvme-pi.sh to prepare your Raspberry Pi 5 to boot from a NVMe disk

# Install Docker and DLNA server via script
cd ~  
wget https://raw.githubusercontent.com/MarkKlerkx/dlnaserver/refs/heads/main/install-dlna-server.sh  
chmod +x install-dlna-server.sh  
sudo bash install-dlna-server.sh

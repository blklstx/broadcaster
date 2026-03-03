#!/usr/bin/env bash
set -euo pipefail

sudo apt update
sudo apt install -y ffmpeg curl jq

sudo mkdir -p /opt/broadcaster/bin
sudo mkdir -p /etc/broadcaster

sudo cp -f bin/*.sh /opt/broadcaster/bin/
sudo chmod +x /opt/broadcaster/bin/*.sh

if [[ ! -f /etc/broadcaster/broadcaster.env ]]; then
  sudo cp etc/broadcaster.env.example /etc/broadcaster/broadcaster.env
  sudo chmod 600 /etc/broadcaster/broadcaster.env
  sudo chown root:root /etc/broadcaster/broadcaster.env
fi

sudo cp -f systemd/*.service /etc/systemd/system/
sudo cp -f systemd/*.timer /etc/systemd/system/ || true

sudo systemctl daemon-reload
sudo systemctl enable --now broadcaster.service
sudo systemctl enable --now dns-update.timer

echo "Installed. Edit: sudo nano /etc/broadcaster/broadcaster.env"
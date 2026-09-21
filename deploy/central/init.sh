#!/usr/bin/env bash
#
# Bootstraps a fresh Debian machine (developed against Debian 13 "trixie" on an
# Intel N150 mini PC) with the Milestone 1 central stack: installs Docker and
# brings up Home Assistant Core + SpeechToTextEngine (Vosk) + TextToSpeechEngine
# (Silero).
#
# Usage — clone this repo yourself first, then run the script from within it:
#   git clone https://github.com/Eaglegor/Hass.git
#   bash Hass/deploy/central/init.sh
#
# It also pre-installs HACS's files into the Home Assistant config (the same
# `wget | bash` installer, run inside the container). What it does NOT do (see
# deploy/central/README.md for these):
#   - Home Assistant onboarding (web UI, first-run wizard)
#   - HACS's one-time GitHub device-activation flow, and installing the
#     Silero TTS Enhanced integration through it
#   - Adding the Wyoming STT integration, the TTS integration, and the
#     OpenRouter conversation agent in the HA UI
#   - Setting up the Assist pipeline
#   - Adding Tier A satellites (ESPHome devices, ReSpeakers, etc.)
# These are one-time, UI-driven steps with no reliable API to script against.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\n\033[1;33m!!\033[0m %s\n' "$1"; }

if [[ "${EUID}" -eq 0 ]]; then
  warn "Running as root. This is fine, but the script uses 'sudo' internally anyway — consider running as a normal user with sudo access instead."
fi

# --- 1. Kernel version sanity check (N150/Twin Lake needs 6.11+ for full driver support) ---
kernel_version="$(uname -r | grep -oE '^[0-9]+\.[0-9]+')"
kernel_major="${kernel_version%%.*}"
kernel_minor="${kernel_version##*.}"
if (( kernel_major < 6 || (kernel_major == 6 && kernel_minor < 11) )); then
  warn "Kernel is ${kernel_version} — the N150 (Twin Lake) needs 6.11+ for full driver support (i915, power management). Consider 'sudo apt full-upgrade' or a newer Debian release before continuing."
fi

# --- 2. Install Docker Engine + Compose plugin, if not already present ---
if command -v docker &>/dev/null && docker compose version &>/dev/null; then
  log "Docker Engine + Compose plugin already installed, skipping."
else
  log "Installing Docker Engine + Compose plugin from Docker's official apt repo..."
  for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    sudo apt-get remove -y "$pkg" 2>/dev/null || true
  done

  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  write_docker_repo() {
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
      $1 stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  }

  write_docker_repo "${codename}"
  if ! sudo apt-get update; then
    warn "Docker's repo may not have packages for '${codename}' yet. Retrying against 'bookworm' packages, which work fine on newer Debian too."
    write_docker_repo "bookworm"
    sudo apt-get update
  fi
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  sudo usermod -aG docker "$USER"
  warn "Added $USER to the 'docker' group — log out and back in (or run 'newgrp docker') for that to take effect without needing sudo each time. This script will keep using sudo for the rest of this run."
fi

# --- 3. Install and enable BlueZ, for the homeassistant container's Bluetooth ---
# docker-compose.yml mounts the host's D-Bus socket and adds the capabilities
# HA's Bluetooth integration needs to talk to BlueZ -- but BlueZ itself has to
# actually be installed and running on the host, or HA fails setup with
# "[org.freedesktop.DBus.Error.ServiceUnknown] The name org.bluez was not
# provided by any .service files".
if systemctl is-active --quiet bluetooth 2>/dev/null; then
  log "BlueZ (bluetooth.service) already installed and running, skipping."
else
  log "Installing and enabling BlueZ..."
  sudo apt-get update
  sudo apt-get install -y bluez
  sudo systemctl enable --now bluetooth
fi

cd "${SCRIPT_DIR}"

# --- 4. Set up .env ---
if [[ -f .env ]]; then
  log ".env already exists, leaving it as-is."
else
  log "Creating .env from .env.example (defaults: Russian Vosk small model)..."
  cp .env.example .env
fi

# --- 5. Bring up the stack ---
log "Building and starting the stack (this takes a while the first time — the tts image builds from source, and stt downloads its Vosk model on first start)..."
sudo docker compose up -d --build

# --- 6. Pre-install HACS into the Home Assistant config ---
# This only lays down HACS's files via the same installer script we'd otherwise
# run by hand inside the container — it still needs a one-time GitHub
# device-activation flow in the HA UI afterward (Settings -> Devices & Services
# -> Add Integration -> HACS), which can't be scripted.
if [[ -d config/homeassistant/custom_components/hacs ]]; then
  log "HACS already installed in config/homeassistant, skipping."
else
  # The container being "running" just means the process started — HACS's own
  # installer looks for a .HA_VERSION marker file, which Home Assistant itself
  # only writes once it finishes its first-boot initialization. That can take
  # a good while on a fresh /config, so wait for the marker directly rather
  # than for the container state.
  log "Waiting for Home Assistant to finish first-boot initialization (up to 3 minutes)..."
  ha_ready=false
  for _ in $(seq 1 180); do
    if [[ -f config/homeassistant/.HA_VERSION ]]; then
      ha_ready=true
      break
    fi
    sleep 1
  done

  if [[ "${ha_ready}" != "true" ]]; then
    warn "Home Assistant didn't finish first-boot initialization within 3 minutes (no .HA_VERSION yet) — skipping the HACS pre-install. Re-run this script once it has, or follow the manual HACS install steps in README.md."
  else
    log "Installing HACS into the Home Assistant config..."
    sudo docker compose exec -T homeassistant bash -c "cd /config && wget -O - https://get.hacs.xyz | bash -"

    log "Restarting Home Assistant to pick up HACS..."
    sudo docker compose restart homeassistant
  fi
fi

# --- 7. Install a systemd unit to refresh DNS on every boot ---
# homeassistant/matter-server run with network_mode: host, and Docker only
# writes their /etc/resolv.conf once, at container creation. Because they use
# `restart: unless-stopped`, a reboot just restarts the *same* container
# instead of recreating it, so a stale (sometimes loopback-pointing) DNS
# snapshot from whenever it was first created persists across every reboot
# since -- confirmed on real hardware. refresh-dns.sh force-recreates both
# containers once the host's own DNS (dhcpcd-managed) is actually up, and this
# unit runs it on every boot so it's automatic instead of a manual fix.
unit_path="/etc/systemd/system/hass-dns-refresh.service"
if [[ -f "${unit_path}" ]]; then
  log "hass-dns-refresh.service already installed, skipping."
else
  log "Installing hass-dns-refresh.service to refresh DNS on every boot..."
  sudo tee "${unit_path}" > /dev/null <<EOF
[Unit]
Description=Force-recreate Home Assistant containers to pick up fresh DNS after boot
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${SCRIPT_DIR}/refresh-dns.sh

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable hass-dns-refresh.service
fi

log "Waiting for containers to report healthy status..."
sleep 5
sudo docker compose ps

cat <<'EOF'

================================================================================
Containers are starting. Remaining steps are manual (UI-driven, see
deploy/central/README.md for full detail on each):

  1. Open http://<this-machine-ip>:8123 and complete Home Assistant onboarding.
  2. Settings -> Devices & Services -> Add Integration -> Wyoming Protocol
     -> host "localhost", port 10300 (SpeechToTextEngine).
  3. HACS's files are already installed. Finish its one-time setup: Settings
     -> Devices & Services -> Add Integration -> HACS -> follow the GitHub
     device-activation flow. Then in HACS, add the
     indevor/silero-tts-enhanced-hacs custom repository (as an Integration),
     install it, and configure it with server URL "http://localhost:8014".
     Do NOT use navatusein/silero-tts-service or the marytts platform --
     both are dead ends (see README for why).
  4. Add an OpenRouter (or OpenAI Conversation pointed at OpenRouter's
     base URL) integration with your API key.
  5. Settings -> Voice assistants -> build a pipeline using the STT, TTS,
     and conversation agent from steps 2-4.
  6. Add your Tier A satellite(s) (ESPHome devices, e.g. a ReSpeaker) --
     no reflashing needed, just network reachability plus (if API
     encryption is on) the device's own encryption key.

Known gotchas already worked around in docker-compose.yml, documented in
README.md in case you hit them anyway:
  - wyoming-vosk needs --sentences-dir even without sentence
    correction/limiting, or it crash-loops on --preload-language.
  - vosk-model-ru-0.54 ("the big Russian model") is NOT Vosk-API-compatible
    -- don't bother trying it, see README for why.
  - Reboots refresh DNS automatically now (hass-dns-refresh.service, step 7
    above). If you change this host's network (Wi-Fi, subnet, VLAN) *without*
    rebooting, run `bash refresh-dns.sh` (or
    `sudo docker compose up -d --force-recreate homeassistant matter-server`)
    manually afterward -- a plain restart reuses the container's original
    /etc/resolv.conf, which goes stale and breaks DNS (including to
    OpenRouter) until recreated.
================================================================================
EOF

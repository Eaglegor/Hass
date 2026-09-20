#!/usr/bin/env bash
#
# Bootstraps a fresh Debian machine (developed against Debian 13 "trixie" on an
# Intel N150 mini PC) with the Milestone 1 central stack: installs Docker, clones
# this repo, and brings up Home Assistant Core + SpeechToTextEngine (Vosk) +
# TextToSpeechEngine (Silero).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Eaglegor/Hass/main/deploy/central/init.sh | bash
# or, if you've already cloned the repo:
#   bash deploy/central/init.sh
#
# What this script does NOT do (see deploy/central/README.md for these):
#   - Home Assistant onboarding (web UI, first-run wizard)
#   - Installing HACS and the Silero TTS Enhanced integration
#   - Adding the Wyoming STT integration, the TTS integration, and the
#     OpenRouter conversation agent in the HA UI
#   - Setting up the Assist pipeline
#   - Adding Tier A satellites (ESPHome devices, ReSpeakers, etc.)
# These are one-time, UI-driven steps with no reliable API to script against —
# this script only gets the containers running and reachable.

set -euo pipefail

REPO_URL="https://github.com/Eaglegor/Hass.git"
REPO_DIR="${HOME}/Hass"

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
  sudo apt-get install -y ca-certificates curl git
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

# --- 3. Clone (or update) the repo ---
if [[ -d "${REPO_DIR}/.git" ]]; then
  log "Repo already cloned at ${REPO_DIR}, pulling latest..."
  git -C "${REPO_DIR}" pull
elif [[ -e "${REPO_DIR}" ]]; then
  echo "ERROR: ${REPO_DIR} exists and isn't a git repo. Move it aside or set REPO_DIR to a different path before re-running." >&2
  exit 1
else
  log "Cloning ${REPO_URL} into ${REPO_DIR}..."
  git clone "${REPO_URL}" "${REPO_DIR}"
fi

cd "${REPO_DIR}/deploy/central"

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
  3. Install HACS (see README's "TTS -- HACS custom integration" section),
     then add the indevor/silero-tts-enhanced-hacs custom repository and
     install/configure it with server URL "http://localhost:8014".
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
  - If you ever change this host's network (Wi-Fi, subnet, VLAN), you must
    run `sudo docker compose up -d --force-recreate homeassistant`
    afterward -- a plain restart or reboot reuses the container's original
    /etc/resolv.conf, which goes stale and breaks DNS (including to
    OpenRouter) until recreated.
================================================================================
EOF

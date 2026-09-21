#!/usr/bin/env bash
#
# Bootstraps a fresh Debian machine (developed against Debian 13 "trixie" on an
# Intel N150 mini PC) with the Milestone 1 central stack: installs Docker and
# brings up Home Assistant Core + SpeechToTextEngine (Vosk) + TextToSpeechEngine
# (Silero) + the LargeLanguageModelConnector (LiteLLM proxy, Milestone 2).
#
# Usage — clone this repo yourself first, then run the script from within it:
#   git clone https://github.com/Eaglegor/Hass.git
#   bash Hass/deploy/central/init.sh
# It prompts for your OpenRouter API key; to skip the prompt (or run without a
# terminal), pass it in the environment: OPENROUTER_API_KEY=sk-or-... bash ...
#
# It also pre-installs HACS's files into the Home Assistant config (the same
# `wget | bash` installer, run inside the container). What it does NOT do (see
# deploy/central/README.md for these):
#   - Home Assistant onboarding (web UI, first-run wizard)
#   - HACS's one-time GitHub device-activation flow, and installing the
#     Silero TTS Enhanced integration through it
#   - Adding the Wyoming STT integration, the TTS integration, and the
#     LiteLLM conversation agent in the HA UI
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

# --- 4. Work around a known rtw88/RTL8821CE Wi-Fi/Bluetooth combo-chip bug ---
# The RTL8821CE combo Wi-Fi/BT chip (common on N150 mini PCs) has a
# well-documented rtw88 driver issue: its firmware stops answering the driver's
# H2C commands, flooding the kernel log with "failed to send h2c command" and
# "firmware failed to leave lps state" (and, per an LKML report on this exact
# chip, it can escalate to a hard system freeze when LPS deep-sleep combines
# with PCIe ASPM): https://lkml.iu.edu/2603.2/04736.html
# Skips cleanly on machines without this chip. Two parts, with different
# confidence -- measured on real hardware (~160 h2c errors/min at baseline):
#   a) Wi-Fi power save OFF (udev rule below) -- the one thing that measurably
#      helped: "failed to leave lps state" errors went to zero and h2c errors
#      roughly halved. Takes effect immediately.
#   b) modprobe options disable_lps_deep / disable_aspm -- aimed at the freeze
#      risk from the LKML report. Set live, neither reduced the log spam by
#      itself, so treat these as freeze insurance, not a spam fix. They need a
#      reboot (they only apply when the module loads).
# What's left over is roughly one burst of h2c errors every 2 s (the driver's
# watchdog) that persisted with Bluetooth fully off, HA stopped, ASPM off and
# deep LPS off -- i.e. it is NOT caused by Bluetooth activity, as first
# assumed. Harmless log noise as far as observed; only using Ethernet instead
# of this Wi-Fi chip (or a different Wi-Fi card) removes it entirely.
rtw88_conf="/etc/modprobe.d/rtw88-h2c-fix.conf"
rtw88_conf_desired="$(cat <<'EOF'
# Works around rtw88's LPS-deep/ASPM interaction with Bluetooth coexistence on
# the RTL8821CE combo Wi-Fi/BT chip -- floods dmesg with "failed to send h2c
# command" and can hard-freeze the system per
# https://lkml.iu.edu/2603.2/04736.html. See deploy/central/README.md.
options rtw88_core disable_lps_deep=Y
options rtw88_pci disable_aspm=Y
EOF
)"
if ! lsmod | grep -q '^rtw88_core'; then
  log "rtw88 driver not loaded on this machine (different Wi-Fi hardware), skipping h2c/LPS workaround."
elif [[ -f "${rtw88_conf}" ]] && diff -q <(echo "${rtw88_conf_desired}") "${rtw88_conf}" &>/dev/null; then
  log "rtw88 h2c/LPS-deep workaround already applied, skipping."
else
  log "Applying rtw88 h2c/LPS-deep workaround (requires a reboot to take effect)..."
  echo "${rtw88_conf_desired}" | sudo tee "${rtw88_conf}" > /dev/null
  sudo update-initramfs -u
  warn "rtw88 workaround written to ${rtw88_conf} -- reboot this machine when convenient for it to take effect (it does NOT apply to the currently-loaded module)."
fi

# (a) Wi-Fi power save off, re-applied whenever the interface appears. Uses
# iwconfig (wireless-tools) -- that's what was verified on real hardware.
if lsmod | grep -q '^rtw88_core'; then
  rtw88_udev="/etc/udev/rules.d/70-rtw88-wifi-power-save.rules"
  rtw88_udev_desired="$(cat <<'EOF'
# Disable Wi-Fi power save on the RTL8821CE: it removes the "firmware failed to
# leave lps state" errors and about halves "failed to send h2c command". See
# deploy/central/README.md.
ACTION=="add|change", SUBSYSTEM=="net", DRIVERS=="rtw*_8821ce", RUN+="/usr/sbin/iwconfig %k power off"
EOF
)"
  if [[ -f "${rtw88_udev}" ]] && diff -q <(echo "${rtw88_udev_desired}") "${rtw88_udev}" &>/dev/null; then
    log "rtw88 Wi-Fi power-save udev rule already installed, skipping."
  else
    log "Disabling Wi-Fi power save on the RTL8821CE (udev rule, applies immediately)..."
    sudo apt-get install -y wireless-tools
    echo "${rtw88_udev_desired}" | sudo tee "${rtw88_udev}" > /dev/null
    sudo udevadm control --reload
    sudo udevadm trigger --action=change --subsystem-match=net
  fi
fi

# --- 5. Configure systemd-resolved for stable DNS (host + containers) ---
# homeassistant/matter-server run with network_mode: host, and Docker only
# writes their /etc/resolv.conf once, at container creation -- it's never kept
# in sync afterward. Recreating those containers on every boot to work around
# that is fragile (it still depends on winning a race against dhcpcd at boot,
# confirmed flaky on real hardware) and treats the symptom, not the cause.
# The actual fix is to stop putting a *dynamic* nameserver IP in resolv.conf
# at all: point it at systemd-resolved's stub listener (127.0.0.53), a fixed
# address that's always there regardless of reboots or network changes, and
# let systemd-resolved -- which dhcpcd feeds the real upstream server(s) to
# dynamically via its built-in hook -- do the actual forwarding. Once
# /etc/resolv.conf says "ask 127.0.0.53", a container's one-time DNS snapshot
# never goes stale again, because that address itself never changes.
if systemctl is-active --quiet systemd-resolved 2>/dev/null && \
   [[ "$(readlink -f /etc/resolv.conf 2>/dev/null)" == "/run/systemd/resolve/stub-resolv.conf" ]]; then
  log "systemd-resolved already configured as the stable resolver, skipping."
else
  log "Installing and enabling systemd-resolved..."
  sudo apt-get update
  sudo apt-get install -y systemd-resolved
  sudo systemctl enable --now systemd-resolved

  if [[ -f /etc/resolv.conf && ! -L /etc/resolv.conf ]]; then
    sudo cp /etc/resolv.conf /etc/resolv.conf.pre-systemd-resolved.bak
    log "Backed up the old /etc/resolv.conf to /etc/resolv.conf.pre-systemd-resolved.bak"
  fi
  sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

  log "Verifying DNS still resolves through the stub (up to 15s for dhcpcd to hand systemd-resolved the upstream server)..."
  dns_ok=false
  for _ in $(seq 1 15); do
    if getent hosts github.com &>/dev/null; then
      dns_ok=true
      break
    fi
    sleep 1
  done

  if [[ "${dns_ok}" != "true" ]]; then
    warn "DNS isn't resolving through systemd-resolved's stub yet. Debian's dhcpcd ships a hook that should hand it the upstream server automatically -- check 'resolvectl status' and 'systemctl status systemd-resolved'. To roll back: sudo ln -sf /etc/resolv.conf.pre-systemd-resolved.bak /etc/resolv.conf"
  else
    log "DNS resolves correctly through systemd-resolved's stub."
  fi
fi

# Clean up the old per-boot recreate unit from an earlier version of this
# script, if present -- systemd-resolved above replaces the need for it.
if [[ -f /etc/systemd/system/hass-dns-refresh.service ]]; then
  log "Removing the old hass-dns-refresh.service (superseded by systemd-resolved)..."
  sudo systemctl disable --now hass-dns-refresh.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/hass-dns-refresh.service
  sudo systemctl daemon-reload
fi

# If homeassistant/matter-server already exist, their DNS snapshot predates
# the fix above -- recreate them once now so it takes effect immediately,
# rather than waiting for the next incidental recreate.
if sudo docker compose ps -q homeassistant matter-server 2>/dev/null | grep -q .; then
  log "Force-recreating homeassistant/matter-server once to pick up the new resolver config..."
  sudo docker compose up -d --force-recreate homeassistant matter-server
fi

# --- 6. Set up .env ---
if [[ -f .env ]]; then
  log ".env already exists, leaving it as-is."
else
  log "Creating .env from .env.example (defaults: Russian Vosk small model)..."
  cp .env.example .env
fi

# Read/write a single KEY=value line in .env. Values here are all URL-safe
# tokens/interface names, so no quoting/escaping is needed.
env_get() { grep -E "^$1=" .env | tail -n1 | cut -d= -f2- || true; }
env_set() {
  local tmp
  tmp="$(mktemp)"
  grep -vE "^$1=" .env > "${tmp}" || true
  printf '%s=%s\n' "$1" "$2" >> "${tmp}"
  cat "${tmp}" > .env
  rm -f "${tmp}"
}

# docker-compose.yml refuses to start without these, so fill them in now
# instead of letting `docker compose up` fail with a bare "variable not set".

# The real LAN/WiFi interface, for matter-server -- the default route's
# interface is right on a normal single-uplink box; check `ip link show` and
# edit .env by hand if this machine is unusual.
if [[ -z "$(env_get MATTER_PRIMARY_INTERFACE)" ]]; then
  matter_iface="$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')"
  if [[ -z "${matter_iface}" ]]; then
    warn "Couldn't detect the default network interface. Set MATTER_PRIMARY_INTERFACE in .env (see 'ip link show'), then re-run."
    exit 1
  fi
  log "Setting MATTER_PRIMARY_INTERFACE=${matter_iface} (default route's interface)."
  env_set MATTER_PRIMARY_INTERFACE "${matter_iface}"
fi

# Shared secret between HA's `litellm` integration and the LiteLLM proxy --
# only needs to be consistent, so generate one rather than asking.
if [[ -z "$(env_get LITELLM_MASTER_KEY)" ]]; then
  log "Generating LITELLM_MASTER_KEY."
  env_set LITELLM_MASTER_KEY "sk-litellm-$(head -c 32 /dev/urandom | base64 | tr -d '\n=+/' | head -c 43)"
fi

# The one thing that can't be generated. Take it from the environment
# (OPENROUTER_API_KEY=... bash init.sh) or prompt for it.
if [[ -z "$(env_get OPENROUTER_API_KEY)" ]]; then
  if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    env_set OPENROUTER_API_KEY "${OPENROUTER_API_KEY}"
  elif [[ -t 0 ]]; then
    read -r -s -p "OpenRouter API key (https://openrouter.ai/keys): " openrouter_key
    echo
    [[ -n "${openrouter_key}" ]] || { warn "No key entered."; exit 1; }
    env_set OPENROUTER_API_KEY "${openrouter_key}"
  else
    warn "OPENROUTER_API_KEY isn't set. Put it in .env, or run: OPENROUTER_API_KEY=sk-or-... bash init.sh"
    exit 1
  fi
fi

# --- 7. Bring up the stack ---
log "Building and starting the stack (this takes a while the first time — the tts image builds from source, and stt downloads its Vosk model on first start)..."
sudo docker compose up -d --build

# --- 8. Pre-install HACS into the Home Assistant config ---
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
  4. Add the LiteLLM integration (the LLM conversation agent): URL
     "http://localhost:4000", API key = LITELLM_MASTER_KEY from .env. Then
     add a conversation agent to it, pick the "assistant" model, and enable
     "Control Home Assistant" (Assist) if it should operate devices. To
     change the underlying model/provider later, edit
     config/litellm/config.yaml and `docker compose restart llm-connector`
     -- nothing to change in HA.
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
  - DNS stability: this script points /etc/resolv.conf at systemd-resolved's
    stub (127.0.0.53) instead of a raw, DHCP-assigned nameserver IP, so
    homeassistant/matter-server's one-time DNS snapshot never goes stale
    across reboots or network changes -- no periodic container recreation
    needed. See README.md's Operational notes if you ever see DNS failures
    (OpenRouter, DCL, etc.) despite this.
================================================================================
EOF

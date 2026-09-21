#!/usr/bin/env bash
#
# Force-recreates the host-networked containers (homeassistant, matter-server)
# so they pick up a fresh /etc/resolv.conf snapshot. Docker only writes that
# file once, at container creation -- and since these containers use
# `restart: unless-stopped`, a reboot just restarts the *same* container
# instead of recreating it, so a stale/loopback DNS snapshot from whenever it
# was first created persists across every reboot since. Installed as a
# systemd unit (see init.sh) that runs this once network is up on every boot.
#
# Safe to run by hand too, e.g. after switching Wi-Fi networks mid-session --
# this is the same fix documented in README.md's Operational notes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

has_real_nameserver() {
  local ip
  while read -r _ ip _; do
    [[ "${ip}" != 127.* && "${ip}" != "::1" ]] && return 0
  done < <(grep '^nameserver' /etc/resolv.conf 2>/dev/null)
  return 1
}

# Wait for the host's own resolv.conf (dhcpcd-managed) to have a real
# nameserver before recreating -- avoids capturing an early-boot placeholder
# into the containers' snapshot, which is exactly the bug this script exists
# to work around in the first place.
for _ in $(seq 1 60); do
  has_real_nameserver && break
  sleep 1
done

docker compose up -d --force-recreate homeassistant matter-server

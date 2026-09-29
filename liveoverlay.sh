#!/usr/bin/env bash
#
# LiveOverlay — one command to install and run the appliance on a Linux mini-PC.
#
# Needs NO source code: copy just this file onto a fresh mini-PC and run
#   bash liveoverlay.sh install
# It installs Docker, logs in to the private Docker Hub repo, unpacks the release bundle
# (compose file + scripts) next to itself — or into ~/liveoverlay when it sits directly in
# your home folder — and runs the setup. Images are pulled, never built.
#
#   ./liveoverlay.sh install     first-time setup: writes docker/.env, builds/pulls, starts,
#                                enables start-on-boot, optionally sets up the TV kiosk
#   ./liveoverlay.sh up          build (if needed) and start everything
#   ./liveoverlay.sh down        stop everything
#   ./liveoverlay.sh restart     down + up
#   ./liveoverlay.sh status      container health + URLs
#   ./liveoverlay.sh logs [svc]  follow logs (all services, or one: api-service, streamer, nginx…)
#   ./liveoverlay.sh update      pull the new release (images + this bundle, or git) + restart
#   ./liveoverlay.sh registry    pull prebuilt images from Docker Hub (see ./publish.sh)
#   ./liveoverlay.sh backup      snapshot the database + media into ./backups/
#   ./liveoverlay.sh kiosk       make the mini-PC open the player full-screen on login
#   ./liveoverlay.sh cameras     list capture cards and switch HOST_VIDEO_DEVICE
#   ./liveoverlay.sh license     set/change the license server URL + activation code
#
# Only Docker (with the compose plugin) is needed on the host. Everything else —
# node, ffmpeg, nginx, mediamtx — runs in containers. The kiosk step uses the
# desktop's Chromium/Chrome; on stock Ubuntu (Firefox only) it offers to snap-install
# Chromium — a documented host exception, like the demo hotspot.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$ROOT/docker/docker-compose.prod.yml"
ENV_FILE="$ROOT/docker/.env"
PLAYER_URL="http://localhost/"
DEFAULT_REPO="ksp0/lo"
# Bundle install = unpacked from the <repo>:bundle-<tag> image (see bootstrap below):
# no git checkout, no source — images always come from Docker Hub, `update` refreshes the bundle.
BUNDLE=0; [ -d "$ROOT/.git" ] || BUNDLE=1
# The build: sections live in a separate file that only a source checkout has.
COMPOSE_FILES=(-f "$COMPOSE_FILE")
[ ! -f "$ROOT/docker/docker-compose.prod.build.yml" ] || COMPOSE_FILES+=(-f "$ROOT/docker/docker-compose.prod.build.yml")

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m✘\033[0m %s\n' "$*" >&2; exit 1; }

is_wsl() { [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; }

# HOST_VIDEO_DEVICE='none' = no capture card (e.g. WSL, or a box without the card yet):
# everything runs except the streamer, which only exists to read the card.
NOCAPTURE_FILE="$ROOT/docker/docker-compose.nocapture.yml"
no_capture() { grep -q "^HOST_VIDEO_DEVICE='none'" "$ENV_FILE" 2>/dev/null; }

# Use sudo for docker only when the user isn't in the docker group yet.
DOCKER=(docker)
compose() {
  local files=("${COMPOSE_FILES[@]}")
  if no_capture; then
    # Generated here (not shipped in the bundle) so it works with any published release.
    printf '# Written by liveoverlay.sh: no capture card, so the streamer is not started.\nservices:\n  streamer:\n    profiles: ["capture"]\n' > "$NOCAPTURE_FILE"
    files+=(-f "$NOCAPTURE_FILE")
  fi
  "${DOCKER[@]}" compose --env-file "$ENV_FILE" "${files[@]}" "$@"
}

# Start the docker daemon: systemd when it is PID 1, else the SysV wrapper (WSL without systemd).
start_docker_daemon() {
  if [ -d /run/systemd/system ]; then
    sudo systemctl enable --now docker >/dev/null 2>&1
  else
    sudo service docker start >/dev/null 2>&1
  fi
}

need_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker is not installed. Install it with:
    curl -fsSL https://get.docker.com | sudo sh
  then re-run: ./liveoverlay.sh install"
  if ! docker info >/dev/null 2>&1; then
    if sudo -n true 2>/dev/null || [ -t 0 ]; then
      sudo docker info >/dev/null 2>&1 || { start_docker_daemon; sleep 2; sudo docker info >/dev/null 2>&1; } \
        || die "Docker is installed but not running: sudo systemctl start docker  (WSL without systemd: sudo service docker start)"
      DOCKER=(sudo docker)
      warn "Using sudo for docker. To drop it: sudo usermod -aG docker \$USER  (then log out/in)"
    else
      die "Cannot talk to Docker. Add yourself to the docker group: sudo usermod -aG docker \$USER"
    fi
  fi
  "${DOCKER[@]}" compose version >/dev/null 2>&1 || die "The docker compose plugin is missing: sudo apt install docker-compose-plugin"
  # nginx/mediamtx/streamer use network_mode: host. Under Docker Desktop that is the
  # Desktop VM's network, not this machine's, unless host networking is turned on.
  if is_wsl && "${DOCKER[@]}" info --format '{{.OperatingSystem}}' 2>/dev/null | grep -qi 'docker desktop'; then
    warn "Docker Desktop detected. Turn on Settings → Resources → Network → 'Enable host networking'"
    warn "(Docker Desktop 4.34+), or http://localhost will not reach LiveOverlay."
  fi
}

need_env() {
  [ -f "$ENV_FILE" ] || die "docker/.env not found — run ./liveoverlay.sh install first."
}

lan_ip() { hostname -I 2>/dev/null | awk '{print $1}' || true; }

# Prints one capture-card path per line (stable by-id links, capture node only).
list_cameras() {
  local d
  for d in /dev/v4l/by-id/*-video-index0; do [ -e "$d" ] && echo "$d"; done
  return 0
}

pick_camera() {
  local cams=() c i choice
  while IFS= read -r c; do cams+=("$c"); done < <(list_cameras)
  while [ "${#cams[@]}" -eq 0 ]; do
    warn "No USB capture card found under /dev/v4l/by-id/."
    if is_wsl; then
      warn "This is WSL: USB devices are not visible unless attached from Windows with usbipd-win"
      warn "(https://learn.microsoft.com/windows/wsl/connect-usb). Everything else works without it."
    fi
    echo "  Plug it in and press Enter to rescan, type a device path (e.g. /dev/video0),"
    read -r -p "  or type 'none' to run without live HDMI input for now: " choice
    case "$choice" in
      "") cams=(); while IFS= read -r c; do cams+=("$c"); done < <(list_cameras) ;;
      none|skip)
        SELECTED_CAMERA=none
        warn "No capture card: everything runs except the live HDMI stream. Add one later: ./liveoverlay.sh cameras"
        return ;;
      *)
        if [ -c "$choice" ]; then SELECTED_CAMERA="$choice"; ok "Capture card: $SELECTED_CAMERA"; return; fi
        warn "$choice is not a video device (ls /dev/video* /dev/v4l/by-id/)." ;;
    esac
  done
  if [ "${#cams[@]}" -eq 1 ]; then
    SELECTED_CAMERA="${cams[0]}"
  else
    echo "Capture cards found:"
    for i in "${!cams[@]}"; do echo "  $((i+1))) ${cams[$i]}"; done
    read -r -p "Which one? [1]: " choice
    choice="${choice:-1}"
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#cams[@]}" ] || die "Invalid choice."
    SELECTED_CAMERA="${cams[$((choice-1))]}"
  fi
  ok "Capture card: $SELECTED_CAMERA"
}

# Ask for the cloud license server. Empty = licensing OFF (LICENSE_MODE=off) — a
# TEMPORARY workaround while no license server is deployed; remove before go-live.
prompt_license() {
  local url code re="^https://[^[:space:]'\"]+$"
  bold "Licensing"
  echo "  No license server yet? Leave it empty: licensing is turned OFF for now (no watermark)."
  while :; do
    read -r -p "  License server URL (e.g. https://license.yourdomain) [none]: " url
    if [ -z "$url" ]; then
      set_env LICENSE_SERVER_URL ""; set_env LICENSE_ACTIVATION_CODE ""; set_env LICENSE_MODE off
      warn "Licensing OFF (temporary). Turn it on later with: ./liveoverlay.sh license"
      return 0
    fi
    [[ "$url" =~ $re ]] && break
    warn "Must be an https:// URL (devices talk to it over mutual TLS), or empty."
  done
  read -r -p "  Activation code (optional — Enter to wait for manual approval instead): " code
  [[ "$code" != *"'"* ]] || die "Activation code can't contain a single quote."
  set_env LICENSE_SERVER_URL "${url%/}"
  set_env LICENSE_ACTIVATION_CODE "$code"
  set_env LICENSE_MODE ""
  ok "License server: ${url%/}"
}

env_has() { grep -Eq "^$1='?[^']" "$ENV_FILE" 2>/dev/null; }
license_off() { grep -q "^LICENSE_MODE='off'" "$ENV_FILE" 2>/dev/null; }
license_configured() { env_has LICENSE_SERVER_URL || license_off; }

# Set KEY='value' in docker/.env (single-quoted = literal, no $ interpolation by compose).
set_env() {
  local key="$1" val="$2" tmp
  tmp="$(mktemp)"
  grep -v "^${key}=" "$ENV_FILE" > "$tmp" || true
  printf "%s='%s'\n" "$key" "$val" >> "$tmp"
  cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
}

write_env() {
  local email pw pw2 secret
  bold "Admin account (you log in to the dashboard with this)"
  read -r -p "  Email [admin@liveoverlay.local]: " email
  email="${email:-admin@liveoverlay.local}"
  while :; do
    read -r -s -p "  Password (min 10 chars): " pw; echo
    [ "${#pw}" -ge 10 ] || { warn "Too short."; continue; }
    [[ "$pw" != *"'"* ]] || { warn "Please don't use a single quote (') in the password."; continue; }
    read -r -s -p "  Repeat password: " pw2; echo
    [ "$pw" = "$pw2" ] && break
    warn "Passwords don't match."
  done

  pick_camera

  # A database copied along with the repo already has a user, so the admin typed
  # above would never be seeded (the api seeds only an empty users table).
  local old=() f yn
  for f in "$ROOT"/config/liveoverlay.db* "$ROOT/config/license.enc"; do [ -e "$f" ] && old+=("$f"); done
  if [ "${#old[@]}" -gt 0 ]; then
    warn "config/ already holds a database (copied with the repo?). Its users would override the admin above."
    read -r -p "  Move it aside to backups/ so a fresh database is created? [Y/n]: " yn || yn=y
    if [[ ! "${yn:-y}" =~ ^[Nn] ]]; then
      local dest; dest="$ROOT/backups/pre-install-$(date +%Y%m%d-%H%M%S)"
      mkdir -p "$dest"
      for f in "${old[@]}"; do
        mv "$f" "$dest/" 2>/dev/null || sudo mv "$f" "$dest/" || die "Could not move $f"
      done
      ok "Old database moved to $dest"
    fi
  fi

  if command -v openssl >/dev/null 2>&1; then
    secret="$(openssl rand -base64 48 | tr -d '\n')"
  else
    secret="$(head -c 48 /dev/urandom | base64 | tr -d '\n')"
  fi

  umask 077
  mkdir -p "$(dirname "$ENV_FILE")"
  : > "$ENV_FILE"
  set_env JWT_SECRET "$secret"
  set_env ADMIN_EMAIL "$email"
  set_env ADMIN_PASSWORD "$pw"
  set_env HOST_VIDEO_DEVICE "$SELECTED_CAMERA"
  prompt_license
  if [ -n "${LO_BOOT_REPO:-}" ]; then
    # Handed over by bootstrap (standalone first run), which already ran docker login.
    set_env LIVEOVERLAY_IMAGE_REPO "$LO_BOOT_REPO"
    set_env LIVEOVERLAY_TAG "${LO_BOOT_TAG:-latest}"
  else
    prompt_registry
  fi
  chmod 600 "$ENV_FILE"
  ok "Wrote docker/.env (readable only by you). More settings: docker/.env.example"
}

# Registry mode = LIVEOVERLAY_IMAGE_REPO set in docker/.env: the api/dashboard/streamer
# images are pulled from Docker Hub (published with ./publish.sh) instead of built here.
registry_mode() { env_has LIVEOVERLAY_IMAGE_REPO; }

cmd_up() {
  need_docker; need_env
  mkdir -p "$ROOT/media" "$ROOT/config"
  [ "$BUNDLE" = 0 ] || registry_mode || die "No image repository set (a bundle install can't build). Run: ./liveoverlay.sh registry"
  if no_capture; then
    # A streamer left over from when a card was configured would keep crash-looping.
    "${DOCKER[@]}" rm -f liveoverlay-streamer >/dev/null 2>&1 || true
    warn "No capture card configured — starting without the live HDMI stream (./liveoverlay.sh cameras to add one)."
  fi
  if registry_mode; then
    # Pull only what's missing, so a restart works offline; `update` pulls new versions.
    bold "Starting LiveOverlay (prebuilt images from Docker Hub)…"
    compose up -d --no-build --pull missing --remove-orphans \
      || die "Could not start. Image missing on Docker Hub, or not logged in? Run: ./liveoverlay.sh registry"
  else
    bold "Building and starting LiveOverlay (first build takes a few minutes)…"
    compose up --build -d --remove-orphans
  fi
  wait_healthy
  cmd_urls
}

prompt_registry() {
  local repo tag
  bold "Prebuilt images (Docker Hub)"
  echo "  Pull the images published with ./publish.sh instead of building them here."
  [ "$BUNDLE" = 1 ] || echo "  Leave empty to build locally on this mini-PC."
  read -r -p "  Repository (<user>/liveoverlay) [${LIVEOVERLAY_IMAGE_REPO_CUR:-none}]: " repo
  repo="${repo:-${LIVEOVERLAY_IMAGE_REPO_CUR:-}}"
  if [ -z "$repo" ] || [ "$repo" = none ]; then
    [ "$BUNDLE" = 0 ] || die "This install has no source code to build from — a repository is required."
    set_env LIVEOVERLAY_IMAGE_REPO ""; set_env LIVEOVERLAY_TAG ""
    ok "Images will be built locally."; return 0
  fi
  [[ "$repo" =~ ^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._/-]*$ ]] || die "Must look like <user>/liveoverlay (lowercase)."
  read -r -p "  Tag to run (latest, or a pinned version like v1.4.0) [latest]: " tag
  tag="${tag:-latest}"
  [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || die "Invalid tag: $tag"
  echo "  The repository is private: log in with a Docker Hub access token (Read-only scope is enough)."
  "${DOCKER[@]}" login || die "docker login failed."
  set_env LIVEOVERLAY_IMAGE_REPO "$repo"
  set_env LIVEOVERLAY_TAG "$tag"
  ok "Images: $repo:<service>-$tag"
}

cmd_registry() {
  need_docker; need_env
  LIVEOVERLAY_IMAGE_REPO_CUR="$(grep -E "^LIVEOVERLAY_IMAGE_REPO=" "$ENV_FILE" | cut -d"'" -f2 || true)"
  prompt_registry
  ok "Apply it with: ./liveoverlay.sh update"
}

wait_healthy() {
  local i unhealthy
  printf 'Waiting for services to become healthy'
  for i in $(seq 1 60); do
    unhealthy="$("${DOCKER[@]}" ps --filter "name=liveoverlay-" --format '{{.Names}} {{.Status}}' \
      | grep -E 'starting|unhealthy|Restarting' || true)"
    [ -z "$unhealthy" ] && { echo; ok "All services healthy."; return 0; }
    printf '.'; sleep 3
  done
  echo; warn "Some services are not healthy yet:"; echo "$unhealthy"
  warn "Check with: ./liveoverlay.sh logs"
}

cmd_urls() {
  local ip; ip="$(lan_ip)"
  echo
  bold "LiveOverlay is running"
  echo "  TV / player (on this mini-PC):  $PLAYER_URL"
  echo "  Dashboard:                      http://localhost/dashboard/"
  if is_wsl; then
    echo "  (WSL: open these in your Windows browser. Other devices on the LAN need WSL mirrored"
    echo "   networking — networkingMode=mirrored in %UserProfile%\\.wslconfig — or a port proxy.)"
  elif [ -n "$ip" ]; then
    echo "  Dashboard from another device:  http://$ip/dashboard/"
  fi
  echo
}

cmd_down()   { need_docker; need_env; compose down; }
cmd_status() {
  need_docker; need_env; compose ps; cmd_urls
  local lic
  lic="$( { wget -qO- http://127.0.0.1/api/license/status || curl -fs http://127.0.0.1/api/license/status; } 2>/dev/null     | grep -o '"state":"[a-z]*"' | cut -d'"' -f4 || true)"
  case "$lic" in
    active)  if license_off; then warn "License: OFF (temporary LICENSE_MODE=off — no license server yet)"
             else ok "License: active"; fi ;;
    grace)   warn "License: grace period (can't reach the license server — check internet)" ;;
    "")      warn "License: unknown (api not reachable)" ;;
    *)       warn "License: $lic — the TV shows the unlicensed watermark. Approve this device in the license admin, or run ./liveoverlay.sh license" ;;
  esac
}

cmd_license() {
  need_env
  prompt_license
  ok "Apply it with: ./liveoverlay.sh restart"
}
cmd_logs()   { need_docker; need_env; compose logs -f --tail=200 "$@"; }

env_get() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | sed "s/^'//; s/'$//"; }

# Unpack an already-pulled <repo>:bundle-<tag> (compose file + scripts) into $2. Each file
# is renamed into place (same filesystem → atomic, new inode), so this very script — which
# bash is still reading — is never modified under it. docker/.env, config/, media/ untouched.
unpack_bundle() {
  local img="$1" dir="$2" tmp f
  mkdir -p "$dir"
  tmp="$(mktemp -d "$dir/.bundle.XXXXXX")"
  "${DOCKER[@]}" run --rm "$img" | tar -xf - -C "$tmp" || { rm -rf "$tmp"; die "Could not unpack $img."; }
  (cd "$tmp" && find . -type f) | while IFS= read -r f; do
    mkdir -p "$dir/$(dirname "$f")"; mv -f "$tmp/$f" "$dir/$f"
  done
  rm -rf "$tmp"
}

refresh_bundle() {
  local img
  img="$(env_get LIVEOVERLAY_IMAGE_REPO):bundle-$(env_get LIVEOVERLAY_TAG)"
  "${DOCKER[@]}" pull -q "$img" >/dev/null || die "Could not pull $img (not logged in? tag not published?). Nothing was restarted."
  unpack_bundle "$img" "$ROOT"
  ok "Updated compose file + scripts from $img"
}

# Standalone = this script was copied alone onto the mini-PC (no compose file next to it):
# install Docker, log in to Docker Hub, unpack the release bundle, then run ./prod from it.
# Re-running on an installed box is harmless (docker/.env is kept).
bootstrap() {
  local dir="$ROOT" repo tag r t img self
  local sudo=(); [ "$(id -u)" -eq 0 ] || sudo=(sudo)
  [ "$(uname -s)" = Linux ] || die "The appliance runs on a Linux mini-PC. (For development on Windows/macOS use: pnpm dev)"
  case "$(uname -m)" in x86_64|amd64) ;; *) die "The images are built for x86_64; this machine is $(uname -m)." ;; esac
  [ -t 0 ] || die "Run it in a terminal — it asks questions (over SSH: ssh -t)."
  # Never spill docker/, scripts/, prod… straight into the home folder.
  [ "$ROOT" != "$HOME" ] || dir="$HOME/liveoverlay"
  bold "No release files next to this script — installing LiveOverlay from Docker Hub into $dir"

  if ! command -v docker >/dev/null 2>&1; then
    bold "Installing Docker Engine (the only thing installed on this machine)"
    command -v curl >/dev/null 2>&1 || { "${sudo[@]}" apt-get update && "${sudo[@]}" apt-get install -y curl; } \
      || die "curl is missing and could not be installed."
    curl -fsSL https://get.docker.com | "${sudo[@]}" sh || die "Docker install failed — see https://docs.docker.com/engine/install/"
  fi
  if [ -d /run/systemd/system ]; then
    "${sudo[@]}" systemctl enable --now docker >/dev/null 2>&1 || warn "Could not enable the docker service on boot."
  elif ! docker info >/dev/null 2>&1 && ! "${sudo[@]}" docker info >/dev/null 2>&1; then
    # WSL without systemd: no unit manager, start the daemon via its init script.
    "${sudo[@]}" service docker start >/dev/null 2>&1 || warn "Could not start docker (sudo service docker start)."
    ! is_wsl || warn "WSL without systemd: docker won't start by itself. Add [boot] systemd=true to /etc/wsl.conf, then: wsl --shutdown"
  fi
  # Continue as a docker-group member, so the Hub login lands in THIS user's ~/.docker
  # (where every later ./liveoverlay.sh update looks), not root's.
  if ! docker info >/dev/null 2>&1; then
    [ "$(id -u)" -ne 0 ] || die "Docker is installed but not running: systemctl start docker"
    id -nG | tr ' ' '\n' | grep -qx docker || { "${sudo[@]}" usermod -aG docker "$USER" && ok "Added $USER to the docker group."; }
    command -v sg >/dev/null 2>&1 || die "Log out and back in (docker group), then re-run: bash $0 install"
    [ -z "${LO_REEXEC:-}" ] || die "Still can't talk to Docker. Log out and back in, then re-run: bash $0 install"
    self="$ROOT/$(basename "${BASH_SOURCE[0]}")"
    exec sg docker -c "LO_REEXEC=1 bash $(printf '%q ' "$self" "$@")" </dev/tty
  fi
  docker compose version >/dev/null 2>&1 || die "The docker compose plugin is missing: sudo apt-get install docker-compose-plugin"
  ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) with compose $(docker compose version --short)"

  repo="${LIVEOVERLAY_IMAGE_REPO:-}"; tag="${LIVEOVERLAY_TAG:-}"
  if [ -z "$repo" ]; then read -r -p "Docker Hub repository [$DEFAULT_REPO]: " r; repo="${r:-$DEFAULT_REPO}"; fi
  if [ -z "$tag" ]; then read -r -p "Release to run (latest, or a version like v1.2.0) [latest]: " t; tag="${t:-latest}"; fi
  [[ "$repo" =~ ^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._/-]*$ ]] || die "Repository must look like <user>/<name>, got: $repo"
  [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || die "Invalid release tag: $tag"

  img="$repo:bundle-$tag"
  if ! docker pull -q "$img" >/dev/null 2>&1; then
    bold "Docker Hub login (the repository is private)"
    echo "  Username = the Docker Hub account; password = an access token with READ-ONLY scope"
    echo "  (hub.docker.com → Account settings → Personal access tokens)."
    docker login || die "docker login failed."
    docker pull -q "$img" >/dev/null || die "Could not pull $img — is release '$tag' published (./publish.sh)?"
  fi
  unpack_bundle "$img" "$dir"
  ok "Release $img unpacked into $dir"
  [ "$dir" = "$ROOT" ] || echo "  From now on: cd $dir && ./liveoverlay.sh status | update | logs | backup"

  # Re-run on an installed box: switch release if asked, keep every other setting.
  if [ -f "$dir/docker/.env" ]; then
    sed -i -e "/^LIVEOVERLAY_IMAGE_REPO=/d" -e "/^LIVEOVERLAY_TAG=/d" "$dir/docker/.env"
    printf "LIVEOVERLAY_IMAGE_REPO='%s'\nLIVEOVERLAY_TAG='%s'\n" "$repo" "$tag" >> "$dir/docker/.env"
  fi
  cd "$dir"
  LO_BOOT_REPO="$repo" LO_BOOT_TAG="$tag" exec ./prod
}

cmd_update() {
  need_docker; need_env
  if [ "$BUNDLE" = 1 ]; then
    registry_mode || die "No image repository set. Run: ./liveoverlay.sh registry"
    bold "Pulling the release…"
    refresh_bundle
  else
    git -C "$ROOT" pull --ff-only || die "git pull failed (local changes?). Nothing was restarted."
  fi
  if registry_mode; then
    bold "Pulling images…"
    compose pull || die "docker pull failed (not logged in? tag not published?). Nothing was restarted. See: ./liveoverlay.sh registry"
  fi
  cmd_up
  "${DOCKER[@]}" image prune -f >/dev/null || true
}

cmd_backup() {
  need_docker; need_env
  local dir="$ROOT/backups" file
  file="$dir/liveoverlay-$(date +%Y%m%d-%H%M%S).tar.gz"
  mkdir -p "$dir"
  # Stop the api for a few seconds so the SQLite file (WAL mode) is consistent on disk.
  # The api container runs as root, so config/ holds root-only files (license.enc 0600).
  local tarc=(tar)
  [ -z "$(find "$ROOT/config" "$ROOT/media" ! -readable -print -quit 2>/dev/null)" ] || tarc=(sudo tar)
  compose stop api-service >/dev/null
  "${tarc[@]}" -C "$ROOT" -czf "$file" config media docker/.env || { compose start api-service >/dev/null; die "Backup failed."; }
  compose start api-service >/dev/null
  [ "${tarc[0]}" = tar ] || sudo chown "$(id -u):$(id -g)" "$file"
  chmod 600 "$file"
  ok "Backup written: $file"
  echo "  Restore: ./liveoverlay.sh down && sudo tar -C \"$ROOT\" -xzf \"$file\" && ./liveoverlay.sh up"
}

cmd_cameras() {
  need_env
  pick_camera
  set_env HOST_VIDEO_DEVICE "$SELECTED_CAMERA"
  ok "Saved. Apply it with: ./liveoverlay.sh restart"
}

cmd_kiosk() {
  local browser="" b yn autostart="$HOME/.config/autostart"
  # Box provisioned by scripts/provision-appliance.sh: Openbox already opens the player.
  # Its getty autologin marker is world-readable (the kiosk user's home is not).
  if grep -qs "$PLAYER_URL" "$HOME/.config/openbox/autostart" \
     || [ -f /etc/systemd/system/getty@tty1.service.d/autologin.conf ]; then
    ok "Kiosk already set up by provision-appliance.sh (Openbox autostart)."
    return 0
  fi
  # No desktop at all (e.g. Ubuntu Server): nothing to autostart a browser in.
  if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}${XDG_CURRENT_DESKTOP:-}" ] \
     && ! systemctl is-enabled --quiet display-manager 2>/dev/null \
     && [ ! -e /etc/X11/default-display-manager ]; then
    warn "No desktop/display manager on this machine, so the TV would only show a text console."
    warn "Set up the TV kiosk with: sudo bash ./scripts/provision-appliance.sh   (then reboot)"
    return 1
  fi
  for b in chromium chromium-browser google-chrome google-chrome-stable; do
    command -v "$b" >/dev/null 2>&1 && { browser="$b"; break; }
  done
  # Stock Ubuntu Desktop ships only Firefox. A kiosk browser is a documented host
  # exception (like the demo hotspot) — nothing else is installed on the host.
  if [ -z "$browser" ] && command -v snap >/dev/null 2>&1; then
    read -r -p "  No Chromium/Chrome found. Install Chromium for the TV kiosk? [Y/n]: " yn || yn=n
    if [[ ! "${yn:-y}" =~ ^[Nn] ]] && sudo snap install chromium; then
      browser="$(command -v chromium || echo /snap/bin/chromium)"
    fi
  fi
  if [ -z "$browser" ]; then
    for b in firefox firefox-esr; do
      command -v "$b" >/dev/null 2>&1 && { browser="$b"; break; }
    done
    [ -z "$browser" ] || warn "Using $browser for the kiosk (Chromium is recommended: videos with sound may not autoplay)."
  fi
  if [ -z "$browser" ]; then
    warn "No browser found. Install Chromium ('sudo snap install chromium' or your distro's"
    warn "package), then run: ./liveoverlay.sh kiosk"
    return 1
  fi
  local flags="--kiosk --noerrdialogs --disable-infobars --no-first-run --disable-translate \
  --disable-session-crashed-bubble --autoplay-policy=no-user-gesture-required --password-store=basic"
  case "$(basename "$browser")" in firefox*) flags="--kiosk" ;; esac
  local launcher="$HOME/.local/bin/liveoverlay-kiosk"
  mkdir -p "$autostart" "$(dirname "$launcher")"
  cat > "$launcher" <<EOF
#!/bin/sh
# Written by liveoverlay.sh kiosk. Waits for the stack, then opens the player full-screen.
# Keep the TV from blanking/locking (GNOME) at every login — liveoverlay.sh's own
# gsettings calls no-op when it runs over SSH (no D-Bus session bus).
if command -v gsettings >/dev/null 2>&1; then
  gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null
  gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null
fi
i=0
while [ \$i -lt 60 ]; do
  { wget -q -O /dev/null $PLAYER_URL || curl -fs -o /dev/null $PLAYER_URL; } 2>/dev/null && break
  i=\$((i+1)); sleep 2
done
exec $browser $flags $PLAYER_URL
EOF
  chmod +x "$launcher"
  cat > "$autostart/liveoverlay-kiosk.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=LiveOverlay Kiosk
Comment=Full-screen LiveOverlay player on the TV output
Exec=$launcher
X-GNOME-Autostart-enabled=true
EOF
  # Keep the TV from blanking (GNOME). Harmless no-op elsewhere.
  if command -v gsettings >/dev/null 2>&1; then
    gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
    gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null || true
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null || true
  fi
  ok "Kiosk set: $browser opens $PLAYER_URL full-screen at login."
  kiosk_autologin
  echo "  Exit the kiosk with Alt+F4. Remove it: rm $autostart/liveoverlay-kiosk.desktop $launcher"
  # Open it now too (not only at next login) when we're inside the desktop session.
  # ./prod sets LO_KIOSK_LAUNCH=0 and opens it itself after the smoke test.
  if [ "${LO_KIOSK_LAUNCH:-1}" != 0 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] \
     && ! pgrep -f "$PLAYER_URL" >/dev/null 2>&1; then
    nohup "$launcher" >/dev/null 2>&1 &
  fi
}

# The autostart entry only runs once this user is logged in — make the box log in
# by itself after a reboot so the TV shows the player, not the login screen.
kiosk_autologin() {
  local f="" yn
  for f in /etc/gdm3/custom.conf /etc/gdm3/daemon.conf ""; do [ -z "$f" ] || [ -f "$f" ] && break; done
  if [ -z "$f" ] || [ "$(id -u)" -eq 0 ]; then
    echo "  For a hands-off box, enable automatic login for this user in Settings → Users."
    return 0
  fi
  if grep -q "^AutomaticLoginEnable=true" "$f" && grep -q "^AutomaticLogin=$USER\$" "$f"; then
    ok "Automatic login already enabled for $USER."; return 0
  fi
  read -r -p "  Log in $USER automatically at boot (so the TV shows the player after a reboot)? [Y/n]: " yn || yn=n
  [[ ! "${yn:-y}" =~ ^[Nn] ]] || { echo "  Skipped — the TV shows the login screen after a reboot until someone logs in."; return 0; }
  if sudo sed -i '/^[[:space:]#]*AutomaticLogin/d' "$f" \
     && if grep -q '^\[daemon\]' "$f"; then
          sudo sed -i -e "/^\[daemon\]/a AutomaticLogin=$USER" -e '/^\[daemon\]/a AutomaticLoginEnable=true' "$f"
        else
          printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=%s\n' "$USER" | sudo tee -a "$f" >/dev/null
        fi; then
    ok "Automatic login enabled for $USER ($f)."
  else
    warn "Could not edit $f — enable automatic login in Settings → Users."
  fi
}

cmd_install() {
  [ "$(uname -s)" = "Linux" ] || die "The appliance runs on Linux. (For development on Windows/macOS use: pnpm dev)"
  need_docker
  # The api bind-mounts /etc/machine-id (license fingerprint). WSL without systemd may lack
  # it, and docker would then create an empty directory in its place.
  if [ ! -s /etc/machine-id ]; then
    { command -v systemd-machine-id-setup >/dev/null 2>&1 && sudo systemd-machine-id-setup >/dev/null 2>&1; } \
      || tr -d '-' < /proc/sys/kernel/random/uuid | sudo tee /etc/machine-id >/dev/null \
      || die "/etc/machine-id is missing and could not be created."
    ok "Created /etc/machine-id"
  fi
  if [ -f "$ENV_FILE" ]; then
    ok "docker/.env already exists — keeping it. (Delete it to re-run the questions.)"
    license_configured || prompt_license
  else
    write_env
  fi
  # Containers use restart: unless-stopped, so they come back on boot once Docker does.
  if [ -d /run/systemd/system ]; then
    { systemctl is-enabled --quiet docker 2>/dev/null || sudo systemctl enable --now docker >/dev/null 2>&1; } && ok "Docker starts on boot (LiveOverlay follows)." \
      || warn "Could not enable docker on boot: sudo systemctl enable docker"
  elif is_wsl; then
    warn "WSL without systemd: after 'wsl --shutdown' run: sudo service docker start && ./liveoverlay.sh up"
  fi
  cmd_up
  local yn=y
  if is_wsl; then
    # No TV output / login session to autostart in: the Windows browser is the player.
    set_env KIOSK off
    echo "WSL: no TV kiosk — open http://localhost/ (player) and http://localhost/dashboard/ in a Windows browser."
  else
    read -r -p "Open the player full-screen on this mini-PC's screen at login (TV kiosk)? [Y/n]: " yn || yn=n
    if [[ "${yn:-y}" =~ ^[Nn] ]]; then
      set_env KIOSK off   # remembered, so ./prod doesn't ask again
    else
      cmd_kiosk || true
    fi
  fi
  echo
  bold "Done. Log in to the dashboard with your admin email, then change the password in Settings."
}

usage() { sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'; }

# Copied alone onto the machine: fetch the release first, whatever command was asked.
if [ ! -f "$COMPOSE_FILE" ]; then
  case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac
  bootstrap "$@"
fi

case "${1:-}" in
  install) cmd_install ;;
  up|start) cmd_up ;;
  down|stop) cmd_down ;;
  restart) cmd_down; cmd_up ;;
  status|ps) cmd_status ;;
  logs) shift; cmd_logs "$@" ;;
  update) cmd_update ;;
  backup) cmd_backup ;;
  kiosk) cmd_kiosk ;;
  cameras) cmd_cameras ;;
  license) cmd_license ;;
  registry) cmd_registry ;;
  ""|-h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac

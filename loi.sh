#!/usr/bin/env bash
#
# LiveOverlay — one command to install and run the appliance on a Linux mini-PC.
#
# Needs NO source code: copy just this file onto a fresh mini-PC and run
#   bash liveoverlay.sh install
# It installs Docker (signed apt repo), logs in to the private Docker Hub repo with this
# customer's read-only token, unpacks the release bundle (compose file + scripts) next to
# itself — or into ~/liveoverlay when it sits directly in your home folder — and runs the
# setup. Images are pulled, never built. Everything runs as root (it re-runs itself with sudo):
# docker/.env, the registry token and the backups are root-only.
set -euo pipefail

usage() {
  cat <<'EOF'
LiveOverlay appliance — sudo ./liveoverlay.sh <command>

  install            first-time setup: docker/.env, time zone, images, start, TV kiosk,
                     firewall, power-cut hardening (idempotent — safe to re-run)
  up | down | restart
  status             containers, health, URLs, license, last backup, kiosk, firewall
  logs [service]     follow logs (api-service, nginx, dashboard, backup, …)
  update [version]   pull the (new) release → start → 90 s health gate → keep, or roll back
  rollback           go back to the release that ran before the last update
  backup             one backup now          restore <file>   restore one (asks first)
  backup-target DIR  copy backups off the box (USB disk / NFS / SMB mount); 'off' to stop
  kiosk [--mode desktop]   (re)install the TV kiosk (dedicated user + cage + Chrome policies)
  cameras            list capture cards; choose the one the kiosk opens
  certs [--renew]    show / regenerate the HTTPS certificate (liveoverlay.local + LAN IPs)
  firewall [apply|remove|status]    host firewall (80/443 + SSH from the LAN only)
  demo up|down|status               isolated demo hotspot, new passphrase each session
  harden             power-cut settings (journald, fsck, docker live-restore)
  timezone [Zone/City]              device time zone (schedules)
  registry [--rotate]               image repository/tag + this customer's read-only token
  license            set/change the license server URL + activation code (required; verified)
EOF
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$ROOT/$(basename "${BASH_SOURCE[0]}")"
COMPOSE_FILE="$ROOT/docker/docker-compose.prod.yml"
BUILD_FILE="$ROOT/docker/docker-compose.prod.build.yml"
ENV_FILE="$ROOT/docker/.env"
CERT_DIR="$ROOT/docker/certs"
RB_DIR="$ROOT/.rollback"
KIOSK_PLAYER_URL="http://localhost/"
DEFAULT_REPO="ksp0/lo"
# Container uid the api runs as (compose `user:`, = the api image's `node` user); owns media/
# config/ logs/ on the host (chowned on install, up, update, restore).
API_UID_DEFAULT=1000
NGINX_UID=101
HEALTH_GATE_SECONDS=90
# Bundle install = unpacked from the <repo>:bundle-<tag> image: no git checkout, no source —
# images always come from Docker Hub, `update` refreshes the bundle.
BUNDLE=0; [ -d "$ROOT/.git" ] || BUNDLE=1

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m✘\033[0m %s\n' "$*" >&2; exit 1; }

is_wsl() { [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; }
interactive() { [ -t 0 ]; }

# ── Root ────────────────────────────────────────────────────────────────────
# Everything below runs as root: docker/.env is root:root 0600 and the registry credentials
# live in root's ~/.docker (Q13, Q45). The invoking admin stays in SUDO_USER.
become_root() {
  [ "$(id -u)" -eq 0 ] && return 0
  command -v sudo >/dev/null 2>&1 || die "Run this as root (sudo is not installed)."
  exec sudo --preserve-env=LO_BOOT_REPO,LO_BOOT_TAG,LO_KIOSK_LAUNCH,LO_YES,LO_ADMIN_PASSWORD,LIVEOVERLAY_IMAGE_REPO,LIVEOVERLAY_TAG \
    bash "$SELF" "$@"
}

admin_home() { # home of the human who ran us (not /root)
  local u="${SUDO_USER:-}"
  if [ -n "$u" ] && [ "$u" != root ]; then getent passwd "$u" | cut -d: -f6; else echo "$HOME"; fi
}

# ── docker/.env helpers ─────────────────────────────────────────────────────
# Never fails (a missing key = empty), so `x="$(env_get K)"` is safe under set -e + pipefail.
env_get() { { grep -E "^$1=" "$ENV_FILE" 2>/dev/null || true; } | tail -1 | cut -d= -f2- | sed "s/^'//; s/'$//"; }
env_has() { grep -Eq "^$1='?[^']" "$ENV_FILE" 2>/dev/null; }
# Set KEY='value' (single-quoted = literal, no $ interpolation by compose). Rewrites the file
# IN PLACE (same inode) because the backup container bind-mounts it.
set_env() {
  local key="$1" val="$2" tmp
  [[ "$val" != *"'"* ]] || die "A value for $key cannot contain a single quote."
  tmp="$(mktemp)"
  grep -v "^${key}=" "$ENV_FILE" > "$tmp" 2>/dev/null || true
  printf "%s='%s'\n" "$key" "$val" >> "$tmp"
  cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
}
del_env() { local tmp; tmp="$(mktemp)"; grep -v "^$1=" "$ENV_FILE" > "$tmp" 2>/dev/null || true; cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"; }
need_env() { [ -f "$ENV_FILE" ] || die "docker/.env not found — run: sudo ./liveoverlay.sh install"; }
license_configured() { env_has LICENSE_SERVER_URL && [ -z "$(env_get LICENSE_MODE)" ]; }
registry_mode() { env_has LIVEOVERLAY_IMAGE_REPO; }
api_uid() { local u; u="$(env_get API_UID)"; echo "${u:-$API_UID_DEFAULT}"; }

# ── Docker ──────────────────────────────────────────────────────────────────
compose() {
  local files=(-f "$COMPOSE_FILE") profiles=()
  [ ! -f "$BUILD_FILE" ] || files+=(-f "$BUILD_FILE")
  [ "$(env_get MDNS)" = off ] || profiles+=(--profile mdns)
  docker compose --env-file "$ENV_FILE" "${files[@]}" "${profiles[@]}" "$@"
}

start_docker_daemon() {
  if [ -d /run/systemd/system ]; then systemctl enable --now docker >/dev/null 2>&1; else service docker start >/dev/null 2>&1; fi
}

# Docker Engine from docker.com's SIGNED apt repository (not `curl | sh`, audit OPS-17).
cmd_install_docker() {
  command -v docker >/dev/null 2>&1 && return 0
  command -v apt-get >/dev/null 2>&1 || die "No apt-get: install Docker Engine + the compose plugin (https://docs.docker.com/engine/install/), then re-run."
  # shellcheck disable=SC1091
  . /etc/os-release
  local distro="${ID:-}" codename="${VERSION_CODENAME:-}"
  case "$distro" in
    ubuntu|debian) ;;
    *) case " ${ID_LIKE:-} " in
         *" ubuntu "*) distro=ubuntu; codename="${UBUNTU_CODENAME:-$codename}" ;;
         *" debian "*) distro=debian ;;
         *) die "Automatic Docker install supports Ubuntu/Debian only. Install Docker Engine, then re-run." ;;
       esac ;;
  esac
  [ -n "$codename" ] || die "Could not detect the $distro release codename."
  local apt=(env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o DPkg::Lock::Timeout=600)
  bold "Installing Docker Engine from docker.com ($distro $codename) — the only thing installed on the host"
  "${apt[@]}" update
  "${apt[@]}" install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$distro/gpg" | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$distro $codename stable" \
    > /etc/apt/sources.list.d/docker.list
  "${apt[@]}" update
  "${apt[@]}" install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  start_docker_daemon
}

need_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker is not installed. Run: sudo ./liveoverlay.sh install   (or ./prod)"
  docker info >/dev/null 2>&1 || { start_docker_daemon; sleep 2; docker info >/dev/null 2>&1; } \
    || die "Docker is installed but not running: sudo systemctl start docker"
  docker compose version >/dev/null 2>&1 || die "The docker compose plugin is missing: sudo apt-get install docker-compose-plugin"
  if is_wsl && docker info --format '{{.OperatingSystem}}' 2>/dev/null | grep -qi 'docker desktop'; then
    warn "Docker Desktop: turn on Settings → Resources → Network → 'Enable host networking', or http://localhost will not reach LiveOverlay."
  fi
}

# Runtime dirs + ownership: api (uid API_UID) owns media/config/logs; nginx (uid 101) owns the
# certificate dir; backups + .rollback are root-only. Also migrates installs made before the
# containers went non-root (everything used to be root-owned).
prepare_dirs() {
  local uid; uid="$(api_uid)"
  [[ "$uid" =~ ^[0-9]+$ ]] || die "API_UID must be numeric"
  mkdir -p "$ROOT/media" "$ROOT/config" "$ROOT/logs" "$ROOT/backups" "$CERT_DIR"
  local d
  for d in media config logs; do
    if [ -n "$(find "$ROOT/$d" ! -uid "$uid" -print -quit 2>/dev/null)" ]; then chown -R "$uid:$uid" "$ROOT/$d"; fi
  done
  chmod 0750 "$ROOT/media"; chmod 0700 "$ROOT/config" "$ROOT/logs" "$ROOT/backups"
  chown -R "$NGINX_UID:$NGINX_UID" "$CERT_DIR"; chmod 0700 "$CERT_DIR"
  chown root:root "$ENV_FILE" 2>/dev/null || true; chmod 0600 "$ENV_FILE" 2>/dev/null || true
  rm -f "$ROOT/docker/docker-compose.nocapture.yml"   # left by releases ≤ v1.3
}

# Pre-remediation .env: HOST_VIDEO_DEVICE (streamer passthrough) → CAPTURE_DEVICE_LABEL.
# HOST_VIDEO_DEVICE and the STREAMER_* tuning vars are KEPT (unused by this compose): a rollback
# to a pre-remediation release restores a compose that requires `${HOST_VIDEO_DEVICE:?}` for its
# streamer (and reads STREAMER_VCODEC etc.) — without them that release would refuse to start.
migrate_env() {
  local dev label
  dev="$(env_get HOST_VIDEO_DEVICE)"
  if [ -n "$dev" ] && ! env_has CAPTURE_DEVICE_LABEL; then
    label="$(device_label "$dev")"
    [ -z "$label" ] || { set_env CAPTURE_DEVICE_LABEL "$label"; ok "Capture card recorded by name: $label"; }
  fi
  return 0
}

lan_ip() { hostname -I 2>/dev/null | awk '{print $1}' || true; }

# ── Capture cards (the kiosk opens them with getUserMedia, Q10) ──────────────
# The browser identifies a V4L2 card by its driver name (VIDIOC_QUERYCAP card), which is what
# /sys/class/video4linux/videoN/name holds. Only capture nodes (index 0) are listed.
device_label() { # device_label /dev/videoN|/dev/v4l/by-id/... → name
  local real n
  real="$(readlink -f "$1" 2>/dev/null || true)"; n="$(basename "$real")"
  [ -r "/sys/class/video4linux/$n/name" ] && cat "/sys/class/video4linux/$n/name"
}
list_cameras() { # "videoN<TAB>name<TAB>by-id" per capture card
  local s n idx byid l
  for s in /sys/class/video4linux/video*; do
    [ -e "$s" ] || continue
    idx="$(cat "$s/index" 2>/dev/null || echo 0)"
    [ "$idx" = 0 ] || continue
    n="$(basename "$s")"; byid=""
    for l in /dev/v4l/by-id/*; do [ "$(readlink -f "$l" 2>/dev/null)" = "/dev/$n" ] && byid="$l"; done
    printf '%s\t%s\t%s\n' "$n" "$(cat "$s/name" 2>/dev/null)" "$byid"
  done
}

pick_camera() {
  local rows=() r i choice
  while :; do
    rows=(); while IFS= read -r r; do rows+=("$r"); done < <(list_cameras)
    if [ "${#rows[@]}" -gt 0 ]; then break; fi
    warn "No capture card found (/sys/class/video4linux)."
    is_wsl && warn "WSL: USB devices need usbipd-win (https://learn.microsoft.com/windows/wsl/connect-usb)."
    interactive || { SELECTED_LABEL=""; return 0; }
    read -r -p "  Plug it in and press Enter to rescan, or type 'none' (the kiosk then uses the first camera it finds): " choice
    [ "$choice" != none ] || { SELECTED_LABEL=""; return 0; }
  done
  if [ "${#rows[@]}" -eq 1 ] || ! interactive; then
    choice=1
  else
    echo "Capture cards found:"
    for i in "${!rows[@]}"; do
      IFS=$'\t' read -r n name byid <<< "${rows[$i]}"
      echo "  $((i+1))) $name  (/dev/$n${byid:+, $byid})"
    done
    read -r -p "Which one? [1]: " choice; choice="${choice:-1}"
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#rows[@]}" ] || die "Invalid choice."
  fi
  IFS=$'\t' read -r _ SELECTED_LABEL _ <<< "${rows[$((choice-1))]}"
  ok "Capture card: $SELECTED_LABEL"
}

cmd_cameras() {
  need_env
  local r n name byid
  echo "Capture cards (capture nodes only):"
  while IFS= read -r r; do
    IFS=$'\t' read -r n name byid <<< "$r"
    echo "  /dev/$n  \"$name\"  ${byid:-}"
  done < <(list_cameras)
  echo "Current: CAPTURE_DEVICE_LABEL='$(env_get CAPTURE_DEVICE_LABEL)'"
  pick_camera
  set_env CAPTURE_DEVICE_LABEL "$SELECTED_LABEL"
  ok "Saved. Apply it with: sudo ./liveoverlay.sh restart"
}

# ── Time zone (Q24) ─────────────────────────────────────────────────────────
host_timezone() {
  local z
  z="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  [ -n "$z" ] || z="$(cat /etc/timezone 2>/dev/null || true)"
  [ -n "$z" ] || z="$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || true)"
  echo "${z:-UTC}"
}
valid_tz() { [[ "$1" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+){0,2}$ ]] && { [ -e "/usr/share/zoneinfo/$1" ] || [ ! -d /usr/share/zoneinfo ]; }; }

prompt_timezone() {
  local z="${1:-}" cur
  cur="$(env_get LIVEOVERLAY_TIMEZONE)"; [ -n "$cur" ] || cur="$(host_timezone)"
  if [ -z "$z" ] && interactive; then
    read -r -p "  Device time zone (schedules run in it) [$cur]: " z
  fi
  z="${z:-$cur}"
  valid_tz "$z" || die "Unknown time zone: $z (e.g. Africa/Casablanca, Europe/Paris)"
  set_env LIVEOVERLAY_TIMEZONE "$z"
  ok "Time zone: $z"
}
# up/update on a box whose docker/.env predates LIVEOVERLAY_TIMEZONE (v1.2.x): record the host's
# zone without prompting, so the containers get a real TZ and the api's first-boot seed uses it.
# A host left on UTC/unknown is NOT written: then the api seeds from the schedules' legacy
# offsets (keeps an upgraded box's wall-clock times) → TZ → UTC. The operator can always pick
# the zone in the dashboard (Settings) or with `sudo ./liveoverlay.sh timezone`.
ensure_timezone() {
  env_has LIVEOVERLAY_TIMEZONE && return 0
  local z; z="$(host_timezone)"
  case "$z" in
    ""|UTC|Etc/UTC|Etc/UCT|UCT|Universal|Zulu|Etc/Universal|Etc/Zulu|GMT|Etc/GMT)
      warn "Host time zone is $z — device zone left to the api (legacy schedules, else UTC). Set it: sudo ./liveoverlay.sh timezone"
      return 0 ;;
  esac
  if valid_tz "$z"; then set_env LIVEOVERLAY_TIMEZONE "$z"; ok "Time zone recorded from the host: $z"
  else warn "Host time zone '$z' not recognised — set it: sudo ./liveoverlay.sh timezone"; fi
  return 0
}
cmd_timezone() {
  need_env; prompt_timezone "${1:-}"
  echo "  Apply: sudo ./liveoverlay.sh restart   (the dashboard's Settings can also change it; the"
  echo "  api only seeds its setting from this value on first boot)"
}

# ── Licensing (required) ────────────────────────────────────────────────────
# The license server runs on ANOTHER machine (licence.sh — the owner's laptop/server), reached
# over the internet. `./licence.sh url` prints the URL, `./licence.sh code` an activation code.
# Install verifies both: the api enrolls with the code and must then validate over mutual TLS.
LICENSE_URL_RE='^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$'
LICENSE_CODE_RE='^[A-Za-z0-9][A-Za-z0-9-]{3,63}$'

# Reachability before anything starts (curl ships with Ubuntu; -k: the device only learns the
# server's CA on its first enrollment, and pins it from then on).
probe_license_server() { # probe_license_server <url> → 0 reachable
  command -v curl >/dev/null 2>&1 || { warn "curl not found — the server is checked once the stack runs."; return 0; }
  local body; body="$(curl -sk --max-time 10 "$1/health" 2>/dev/null || true)"
  case "$body" in *'"status":"ok"'*) ok "License server reachable: $1"; return 0 ;; esac
  warn "No answer from $1/health — wrong URL, the license server is down, or its router port is not forwarded."
  return 1
}

prompt_license() {
  local url code yn
  bold "Licensing (required)"
  echo "  From the license server operator: its URL (./licence.sh url) and an activation code for"
  echo "  this mini-PC (./licence.sh code)."
  while :; do
    read -r -p "  License server URL [$(env_get LICENSE_SERVER_URL)]: " url
    url="${url:-$(env_get LICENSE_SERVER_URL)}"; url="${url%/}"
    [[ "$url" =~ $LICENSE_URL_RE ]] || { warn "Must look like https://license.example.com (optionally :port)."; continue; }
    probe_license_server "$url" && break
    read -r -p "  Keep this URL anyway? [y/N]: " yn || yn=n
    [[ "$yn" =~ ^[Yy] ]] && break
  done
  while :; do
    read -r -p "  Activation code (LO-XXXX-XXXX-XXXX): " code
    code="$(printf '%s' "$code" | tr -d ' ')"
    [[ "$code" =~ $LICENSE_CODE_RE ]] && break
    warn "Enter the activation code from ./licence.sh code (or the license admin → Activation codes)."
  done
  set_env LICENSE_SERVER_URL "$url"
  set_env LICENSE_ACTIVATION_CODE "$code"
  del_env LICENSE_MODE   # the old temporary unlock switch — no longer supported
  ok "License server: $url"
}

# /api/license/status (public): state + `check` = outcome of the api's last call to the server.
license_json() { docker exec liveoverlay-nginx wget -qO- -T 5 http://127.0.0.1/api/license/status 2>/dev/null || true; }
json_str() { printf '%s' "$1" | grep -o "\"$2\":\"[a-z-]*\"" | head -1 | cut -d'"' -f4 || true; }
license_problem() {
  case "$1" in
    pending)     echo "the server answered but did NOT approve this device: the activation code is wrong, already used or expired (or approve the device in the license admin)" ;;
    unreachable) echo "the license server cannot be reached: check the URL, ./licence.sh status on the server, and its router port-forward" ;;
    certificate) echo "TLS certificate mismatch: the URL's host must be one the server was set up with (./licence.sh url)" ;;
    revoked)     echo "this device is REVOKED on the license server" ;;
    expired)     echo "this device's subscription has ended (license admin → device → subscription)" ;;
    "")          echo "no answer from the api yet (sudo ./liveoverlay.sh logs api-service)" ;;
    *)           echo "the license server returned an error (sudo ./liveoverlay.sh logs api-service)" ;;
  esac
}

# 0 = active AND validated over mTLS by the server (not just a cached licence).
verify_license() { # verify_license [seconds]
  local limit="${1:-120}" start j st="" ck="" pend=""  # pend: since when a definitive "no" is seen
  start="$(date +%s)"
  printf 'Checking the license with %s' "$(env_get LICENSE_SERVER_URL)"
  while :; do
    j="$(license_json)"; st="$(json_str "$j" state)"; ck="$(json_str "$j" check)"
    if [ "$st" = active ] && [ "$ck" = ok ]; then echo; ok "License active — validated by the license server."; return 0; fi
    case "$ck" in
      revoked|expired) break ;;
      pending|certificate) [ -n "$pend" ] || pend="$(date +%s)"; [ $(( $(date +%s) - pend )) -lt 20 ] || break ;;
    esac
    [ $(( $(date +%s) - start )) -lt "$limit" ] || break
    printf '.'; sleep 3
  done
  echo; warn "License NOT active (state=${st:-?}): $(license_problem "$ck")"
  return 1
}

# Required: loops until the server validates this device, or the operator gives up (install stops).
ensure_license() {
  local c code
  while ! verify_license; do
    interactive || return 1
    echo "  1) enter another activation code   2) change the license server URL + code   3) stop here"
    read -r -p "  Choice [1]: " c || c=3
    case "${c:-1}" in
      1) read -r -p "  Activation code: " code; code="$(printf '%s' "$code" | tr -d ' ')"
         [[ "$code" =~ $LICENSE_CODE_RE ]] || { warn "Not an activation code."; continue; }
         set_env LICENSE_ACTIVATION_CODE "$code" ;;
      2) prompt_license ;;
      *) return 1 ;;
    esac
    compose up -d --no-build --pull never api-service >/dev/null 2>&1 || warn "Could not restart the api."
  done
}

cmd_license() {
  need_docker; need_env
  prompt_license
  compose up -d --no-build --pull never api-service >/dev/null || die "Could not restart the api (sudo ./liveoverlay.sh up)."
  ensure_license || die "The license is not active — the TV shows the unlicensed watermark. Retry: sudo ./liveoverlay.sh license"
}

# The license server must never share a machine with the app (licence.sh refuses the reverse).
guard_no_license_stack() {
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Eq '^(lo-license-|liveoverlay-license-)'; then
    die "License-server containers exist on this machine. The license server runs on ANOTHER machine
  (licence.sh, reached over the internet) — remove them here first: docker ps -a --filter name=license"
  fi
}

# ── Registry: this customer's read-only Docker Hub token (Q45 / N9) ──────────
# One access token per customer (Read-only scope), rotated at every release (publish.sh prints
# the checklist). Stored by `docker login` in root's ~/.docker/config.json (0600) — never in
# docker/.env, never readable by the kiosk or admin user.
registry_login() { # registry_login <repo>
  local user token
  echo "  Docker Hub login for this device: the Hub account name + THIS customer's access token"
  echo "  (hub.docker.com → Account settings → Personal access tokens → scope: Read-only)."
  read -r -p "  Docker Hub user: " user
  [[ "$user" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "Invalid Docker Hub user name."
  read -r -s -p "  Access token (read-only): " token; echo
  [ -n "$token" ] || die "Empty token."
  printf '%s' "$token" | docker login -u "$user" --password-stdin >/dev/null || die "docker login failed (token revoked or wrong scope?)."
  chmod 600 /root/.docker/config.json 2>/dev/null || true
  [ ! -f "$ENV_FILE" ] || set_env REGISTRY_TOKEN_SET_AT "$(date +%F)"
  ok "Logged in to Docker Hub as $user (credentials root-only)."
}

prompt_registry() {
  local repo tag cur
  cur="$(env_get LIVEOVERLAY_IMAGE_REPO)"
  bold "Prebuilt images (Docker Hub)"
  [ "$BUNDLE" = 1 ] || echo "  Leave empty to build locally from this source checkout."
  read -r -p "  Repository [${cur:-$DEFAULT_REPO}]: " repo
  repo="${repo:-${cur:-$DEFAULT_REPO}}"
  if [ "$repo" = none ]; then
    [ "$BUNDLE" = 0 ] || die "This install has no source code to build from — a repository is required."
    set_env LIVEOVERLAY_IMAGE_REPO ""; set_env LIVEOVERLAY_TAG ""; ok "Images will be built locally."; return 0
  fi
  [[ "$repo" =~ ^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._/-]*$ ]] || die "Must look like <user>/<name> (lowercase)."
  cur="$(env_get LIVEOVERLAY_TAG)"
  echo "  Pin a release version (e.g. v1.4.0). 'latest' follows every publish — not recommended."
  read -r -p "  Release [${cur:-latest}]: " tag
  tag="${tag:-${cur:-latest}}"
  [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || die "Invalid tag: $tag"
  registry_login "$repo"
  set_env LIVEOVERLAY_IMAGE_REPO "$repo"
  set_env LIVEOVERLAY_TAG "$tag"
  ok "Images: $repo:<service>-$tag"
}

cmd_registry() {
  need_docker; need_env
  if [ "${1:-}" = --rotate ]; then
    bold "Rotating this device's registry token"
    registry_mode || die "No repository configured. Run: sudo ./liveoverlay.sh registry"
    registry_login "$(env_get LIVEOVERLAY_IMAGE_REPO)"
    docker pull -q "$(env_get LIVEOVERLAY_IMAGE_REPO):bundle-$(env_get LIVEOVERLAY_TAG)" >/dev/null \
      && ok "New token works (release bundle pulled). Now REVOKE the old token on Docker Hub." \
      || die "The new token cannot pull this release — check its scope/repository."
    return 0
  fi
  prompt_registry
  ok "Apply it with: sudo ./liveoverlay.sh update"
}

# ── Admin actions through the api (kiosk token, demo config, password hash) ─
# Runs a tiny node program INSIDE the api container, fed on stdin; the password travels as an
# environment variable taken from this process (`-e LO_PW` without a value), so it never
# appears on any command line. Every session it opens is logged out again.
api_admin() { # api_admin <action> → stdout; exit 3 = bad password
  LO_ACTION="$1" docker exec -i -e LO_EMAIL -e LO_PW -e LO_ACTION -e LO_BODY liveoverlay-api node - <<'JS'
const base = 'http://127.0.0.1:3000/api';
const { LO_EMAIL: email, LO_PW: password, LO_ACTION: action, LO_BODY: body } = process.env;
async function call(method, path, token, data) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = 'Bearer ' + token;
  const r = await fetch(base + path, { method, headers, body: data === undefined ? undefined : JSON.stringify(data) });
  let j = {}; try { j = await r.json(); } catch { /* not JSON */ }
  if (!r.ok || j.success === false) { const e = new Error((j && j.error) || ('HTTP ' + r.status)); e.status = r.status; throw e; }
  return j.data;
}
(async () => {
  if (action === 'hash') { process.stdout.write(require('bcryptjs').hashSync(password, 10)); return; }
  let token;
  try { token = (await call('POST', '/auth/login', null, { email, password })).token; }
  catch (e) { console.error('login failed: ' + e.message); process.exit(e.status === 401 ? 3 : 1); }
  try {
    if (action === 'kiosk-url') {
      const d = await call('POST', '/auth/kiosk-tokens', token, { label: 'TV kiosk (installed ' + new Date().toISOString().slice(0, 10) + ')' });
      process.stdout.write('http://localhost/?token=' + encodeURIComponent(d.secret));
    } else if (action === 'demo-config') {
      await call('PUT', '/demo/config', token, JSON.parse(body));
      process.stdout.write('ok');
    } else if (action === 'check') {
      process.stdout.write('ok');
    } else { throw new Error('unknown action ' + action); }
  } finally { try { await call('POST', '/auth/logout', token, {}); } catch { /* best effort */ } }
})().catch((e) => { console.error(e.message); process.exit(1); });
JS
}

# Sets LO_EMAIL + LO_PW for api_admin: the seed password from docker/.env (fresh install),
# LO_ADMIN_PASSWORD, or asks.
admin_credentials() {
  export LO_EMAIL LO_PW
  LO_EMAIL="$(env_get ADMIN_EMAIL)"
  LO_PW="${LO_ADMIN_PASSWORD:-$(env_get ADMIN_PASSWORD)}"
  if [ -z "$LO_PW" ] || [ "$(LO_PW="$LO_PW" api_admin check 2>/dev/null || echo fail)" != ok ]; then
    interactive || return 1
    read -r -s -p "  Dashboard password for $LO_EMAIL (Enter to skip): " LO_PW; echo
    [ -n "$LO_PW" ] || return 1
  fi
}

# OPS-14: after the first healthy boot keep only a bcrypt hash of the seed password.
seal_admin_password() {
  local pw hash; pw="$(env_get ADMIN_PASSWORD)"
  [ -n "$pw" ] || return 0
  hash="$(LO_PW="$pw" api_admin hash 2>/dev/null || true)"
  if [[ "$hash" =~ ^\$2[aby]\$[0-9]{2}\$.{53}$ ]]; then
    set_env ADMIN_PASSWORD_HASH "$hash"; set_env ADMIN_PASSWORD ""
    ok "Seed password removed from docker/.env (bcrypt hash kept, only used if the database is ever recreated)."
  fi
}

# ── Health ──────────────────────────────────────────────────────────────────
# The release gate (update → auto-rollback) only judges the containers the TV and the dashboard
# need: they must be running and healthy (no healthcheck: running), the one-shot api-init must
# have exited 0, AND the api must answer through nginx over HTTPS. Optional sidecars (mDNS,
# backup, device-agent telemetry, autoheal) being down is reported as a warning, never a
# failed release — e.g. mDNS can't bind 5353 next to some host avahi setups.
REQUIRED_CONTAINERS="liveoverlay-api liveoverlay-nginx liveoverlay-dashboard liveoverlay-socket-proxy"
OPTIONAL_WARNED=""
stack_ready() {
  local rows bad="" c row opt
  rows="$(docker ps -a --filter name=liveoverlay- --format '{{.Names}}|{{.State}}|{{.Status}}' | grep -v '^liveoverlay-license' || true)"
  [ -n "$rows" ] || return 1
  for c in $REQUIRED_CONTAINERS; do
    row="$(echo "$rows" | awk -F'|' -v n="$c" '$1==n')"
    if [ -z "$row" ]; then bad+="$c|missing"$'\n'; continue; fi
    echo "$row" | awk -F'|' '$2!="running" || $3 ~ /(starting|unhealthy)/ {f=1} END{exit !f}' && bad+="$row"$'\n'
  done
  row="$(echo "$rows" | awk -F'|' '$1=="liveoverlay-api-init"')"
  case "$row" in ""|*"|exited|Exited (0)"*) ;; *) bad+="$row"$'\n' ;; esac
  [ -z "$bad" ] || { LAST_NOT_READY="${bad%$'\n'}"; return 1; }
  opt="$(echo "$rows" | awk -F'|' -v req=" $REQUIRED_CONTAINERS liveoverlay-api-init " \
    'index(req, " " $1 " ")==0 && ($2!="running" || $3 ~ /unhealthy/)')"
  if [ -n "$opt" ] && [ "$opt" != "$OPTIONAL_WARNED" ]; then
    OPTIONAL_WARNED="$opt"
    echo; warn "Optional services not healthy (not a failed release):"; printf '%s\n' "$opt" | awk '{print "    " $0}' >&2
  fi
  docker exec liveoverlay-nginx wget -qO- -T 5 --no-check-certificate https://127.0.0.1/api/health >/dev/null 2>&1 \
    || { LAST_NOT_READY="https://localhost/api/health not answering"; return 1; }
}
# /api/health answers 200 even when "degraded" (e.g. the capture card is unplugged): that is
# NOT a failed release, so the gate passes — but the problems are shown.
health_problems() {
  local body
  body="$(docker exec liveoverlay-nginx wget -qO- -T 5 --no-check-certificate https://127.0.0.1/api/health 2>/dev/null || true)"
  case "$body" in
    *'"degraded"'*)
      warn "The api reports DEGRADED: $(printf '%s' "$body" | grep -o '"problems":\[[^]]*\]' | sed 's/"problems"://' || echo '(see /api/health)')" ;;
  esac
  return 0
}
wait_healthy() { # wait_healthy <seconds> → 0 ready / 1 timeout
  local limit="${1:-180}" start; start="$(date +%s)"
  LAST_NOT_READY=""
  printf 'Waiting for all services to be healthy (up to %ss)' "$limit"
  while :; do
    if stack_ready; then
      echo; ok "All services healthy, https://localhost/api/health OK."
      health_problems
      return 0
    fi
    [ $(( $(date +%s) - start )) -lt "$limit" ] || break
    printf '.'; sleep 3
  done
  echo; warn "Not healthy after ${limit}s:"; echo "$LAST_NOT_READY" | sed 's/^/    /' >&2
  return 1
}

cmd_urls() {
  local ip; ip="$(lan_ip)"
  echo
  bold "LiveOverlay is running"
  echo "  TV (kiosk on this mini-PC):   $KIOSK_PLAYER_URL"
  echo "  Dashboard from a phone / PC:  https://liveoverlay.local/dashboard/${ip:+   or https://$ip/dashboard/}"
  echo "  (self-signed certificate — accept it once; fingerprint: sudo ./liveoverlay.sh certs)"
  echo
}

# ── up / down / status / logs ───────────────────────────────────────────────
cmd_up() {
  need_docker; need_env
  guard_no_license_stack
  migrate_env; ensure_timezone
  prepare_dirs
  [ "$BUNDLE" = 0 ] || registry_mode || die "No image repository set (a bundle install can't build). Run: sudo ./liveoverlay.sh registry"
  if registry_mode; then
    bold "Starting LiveOverlay (prebuilt images)…"
    # Pull only what's missing, so a restart works offline; `update` pulls new versions.
    compose up -d --no-build --pull missing --remove-orphans \
      || die "Could not start. Image missing on Docker Hub, or not logged in? Run: sudo ./liveoverlay.sh registry"
  else
    bold "Building and starting LiveOverlay (the first build takes a few minutes)…"
    compose up --build -d --remove-orphans
  fi
  wait_healthy 180 || warn "Check with: sudo ./liveoverlay.sh logs"
  cmd_urls
}

cmd_down()   { need_docker; need_env; compose down; }
cmd_logs()   { need_docker; need_env; compose logs -f --tail=200 "$@"; }

cmd_status() {
  need_docker; need_env
  compose ps -a
  cmd_urls
  local lj lic ck
  lj="$(license_json)"; lic="$(json_str "$lj" state)"; ck="$(json_str "$lj" check)"
  case "$lic" in
    active)  if [ -z "$ck" ] || [ "$ck" = ok ]; then ok "License: active ($(env_get LICENSE_SERVER_URL))"; else warn "License: active (cached) — last check failed: $(license_problem "$ck")"; fi ;;
    grace)   warn "License: grace period — $(license_problem "${ck:-unreachable}")" ;;
    "")      warn "License: unknown (api not reachable)" ;;
    *)       warn "License: $lic — the TV shows the unlicensed watermark: $(license_problem "$ck"). Fix: sudo ./liveoverlay.sh license" ;;
  esac
  if [ -f "$ROOT/backups/last-status" ]; then
    local r t; r="$(sed -n 's/^result=//p' "$ROOT/backups/last-status")"; t="$(sed -n 's/^time=//p' "$ROOT/backups/last-status")"
    if [ "$r" = ok ]; then ok "Last backup: $t"; else warn "Last backup FAILED at $t — see: sudo ./liveoverlay.sh logs backup"; fi
  else
    warn "No backup yet (nightly at $(env_get BACKUP_AT | sed 's/^$/03:30/'))."
  fi
  env_has BACKUP_TARGET || warn "Backups stay on this disk. Off-box copy: sudo ./liveoverlay.sh backup-target <dir>"
  echo "  Kiosk: $(systemctl is-enabled liveoverlay-kiosk.service 2>/dev/null || echo 'not installed') / $(systemctl is-active liveoverlay-kiosk.service 2>/dev/null || true)"
  if command -v nft >/dev/null 2>&1 && nft list table inet liveoverlay >/dev/null 2>&1; then ok "Firewall: on"; else warn "Firewall: off (sudo ./liveoverlay.sh firewall apply)"; fi
}

# ── Bundle (repo-less install) ──────────────────────────────────────────────
# Unpack an already-pulled <repo>:bundle-<tag> into $2 (a staging dir or the install dir).
unpack_bundle_to() {
  local img="$1" dir="$2"
  mkdir -p "$dir"
  docker run --rm "$img" | tar -xf - -C "$dir" || die "Could not unpack $img."
}
# Move staged files into place, each renamed atomically (same filesystem, new inode) so this
# very script — which bash is still reading — is never modified under it. docker/.env,
# config/, media/, logs/, backups/, docker/certs untouched.
install_staged() {
  local stage="$1" f
  (cd "$stage" && find . -type f) | while IFS= read -r f; do
    mkdir -p "$ROOT/$(dirname "$f")"; mv -f "$stage/$f" "$ROOT/$f"
  done
}

# Standalone = this script was copied alone onto the mini-PC (no compose file next to it):
# install Docker, log in to Docker Hub, unpack the release bundle, then run ./prod from it.
bootstrap() {
  local dir="$ROOT" repo tag r t img home
  [ "$(uname -s)" = Linux ] || die "The appliance runs on a Linux mini-PC. (For development on Windows/macOS use: pnpm dev)"
  case "$(uname -m)" in x86_64|amd64) ;; *) die "The images are built for x86_64; this machine is $(uname -m)." ;; esac
  interactive || die "Run it in a terminal — it asks questions (over SSH: ssh -t)."
  home="$(admin_home)"
  [ "$ROOT" != "$home" ] || dir="$home/liveoverlay"
  bold "No release files next to this script — installing LiveOverlay from Docker Hub into $dir"
  cmd_install_docker
  need_docker
  ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) with compose $(docker compose version --short)"

  repo="${LIVEOVERLAY_IMAGE_REPO:-}"; tag="${LIVEOVERLAY_TAG:-}"
  if [ -z "$repo" ]; then read -r -p "Docker Hub repository [$DEFAULT_REPO]: " r; repo="${r:-$DEFAULT_REPO}"; fi
  if [ -z "$tag" ]; then read -r -p "Release to run (a version like v1.4.0) [latest]: " t; tag="${t:-latest}"; fi
  [[ "$repo" =~ ^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._/-]*$ ]] || die "Repository must look like <user>/<name>, got: $repo"
  [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || die "Invalid release tag: $tag"

  img="$repo:bundle-$tag"
  if ! docker pull -q "$img" >/dev/null 2>&1; then
    bold "Docker Hub login (the repository is private)"
    registry_login "$repo"
    docker pull -q "$img" >/dev/null || die "Could not pull $img — is release '$tag' published (./publish.sh)?"
  fi
  local stage; stage="$(mktemp -d)"
  unpack_bundle_to "$img" "$stage"
  mkdir -p "$dir"; ROOT="$dir" install_staged "$stage"; rm -rf "$stage"
  chmod 755 "$dir/liveoverlay.sh" "$dir/prod"
  ok "Release $img unpacked into $dir"
  [ "$dir" = "$ROOT" ] || echo "  From now on: cd $dir && sudo ./liveoverlay.sh status | update | logs | backup"
  if [ -f "$dir/docker/.env" ]; then
    sed -i -e "/^LIVEOVERLAY_IMAGE_REPO=/d" -e "/^LIVEOVERLAY_TAG=/d" "$dir/docker/.env"
    printf "LIVEOVERLAY_IMAGE_REPO='%s'\nLIVEOVERLAY_TAG='%s'\n" "$repo" "$tag" >> "$dir/docker/.env"
  fi
  cd "$dir"
  LO_BOOT_REPO="$repo" LO_BOOT_TAG="$tag" exec ./prod
}

# ── Update with health gate + automatic rollback (Q38 / OPS-2) ──────────────
# Before touching anything: record which image (name + ID) every container runs, the compose
# file(s), the release tag and a fresh DB backup, into .rollback/. Then pull the new release
# (staged — nothing changes if a pull fails), switch, and give it 90 s to be healthy
# (all containers healthy + https://localhost/api/health). Otherwise put the recorded images
# back under their old names, restore the old compose file, tag and pre-update database, and
# start that. The previous release's images are tagged liveoverlay-rollback:<service> so no
# prune ever removes them.
record_release() {
  local svc cid img id
  rm -rf "$RB_DIR"; install -d -m 0700 "$RB_DIR"
  cp -p "$COMPOSE_FILE" "$RB_DIR/"
  [ ! -f "$BUILD_FILE" ] || cp -p "$BUILD_FILE" "$RB_DIR/"
  [ "$BUNDLE" = 1 ] || git -C "$ROOT" rev-parse HEAD > "$RB_DIR/git-head" 2>/dev/null || true
  : > "$RB_DIR/images.tsv"
  compose ps -a --format '{{.Service}} {{.ID}}' | while read -r svc cid; do
    [ -n "$cid" ] || continue
    img="$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)"
    id="$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null || true)"
    [ -n "$id" ] || continue
    printf '%s\t%s\t%s\n' "$svc" "$img" "$id" >> "$RB_DIR/images.tsv"
    docker tag "$id" "liveoverlay-rollback:$svc" 2>/dev/null || true
  done
  # The release that is RUNNING (from the api image name), not whatever docker/.env says now —
  # `registry` may already have switched the tag. Falls back to docker/.env.
  local running
  running="$(awk -F'\t' '$1=="api-service"{print $2}' "$RB_DIR/images.tsv" | sed -n 's/.*:api-service-//p')"
  printf "%s\n" "${running:-$(env_get LIVEOVERLAY_TAG)}" > "$RB_DIR/tag"
  date -Iseconds > "$RB_DIR/when"
}

pre_update_backup() {
  local f
  f="$(docker exec liveoverlay-backup lo-backup now pre-update 2>/dev/null | tail -1 || true)"
  if [ -n "$f" ]; then
    echo "$ROOT/backups/${f#/backups/}" > "$RB_DIR/db-backup"; ok "Pre-update backup: backups/${f#/backups/}"
  else
    warn "Could not take a pre-update backup (backup container not running) — continuing."
  fi
}

restore_db_from() { # restore_db_from <backup.tar.gz> — config/*.db only, stack must be down
  local f="$1" work
  [ -f "$f" ] || return 1
  work="$(mktemp -d)"
  tar -xzf "$f" -C "$work" || { rm -rf "$work"; return 1; }
  find "$work/liveoverlay-backup/config" -name '*.db' | while IFS= read -r db; do
    local rel="${db#"$work/liveoverlay-backup/config/"}"
    rm -f "$ROOT/config/$rel-wal" "$ROOT/config/$rel-shm"
    install -m 0600 -o "$(api_uid)" -g "$(api_uid)" "$db" "$ROOT/config/$rel"
  done
  rm -rf "$work"
}

do_rollback() { # do_rollback <restore-db: yes|no>
  [ -s "$RB_DIR/images.tsv" ] || die "Nothing to roll back to (no previous update recorded in .rollback/)."
  local svc img id missing=0
  bold "Rolling back to the release recorded $(cat "$RB_DIR/when" 2>/dev/null)"
  while IFS=$'\t' read -r svc img id; do
    case "$img" in *@sha256:*) continue ;; esac   # digest-pinned third-party image: unchanged by updates
    if docker image inspect "$id" >/dev/null 2>&1; then
      docker tag "$id" "$img" || warn "Could not re-tag $svc as $img"
    else
      warn "Image for $svc is gone ($id)"; missing=1
    fi
  done < "$RB_DIR/images.tsv"
  [ "$missing" = 0 ] || warn "Some previous images are missing; compose may try to pull them."
  cp -p "$RB_DIR/$(basename "$COMPOSE_FILE")" "$COMPOSE_FILE"
  [ ! -f "$RB_DIR/$(basename "$BUILD_FILE")" ] || cp -p "$RB_DIR/$(basename "$BUILD_FILE")" "$BUILD_FILE"
  set_env LIVEOVERLAY_TAG "$(cat "$RB_DIR/tag")"
  compose down --remove-orphans >/dev/null 2>&1 || true
  if [ "$1" = yes ] && [ -f "$RB_DIR/db-backup" ]; then
    restore_db_from "$(cat "$RB_DIR/db-backup")" && ok "Database restored from the pre-update backup."
  fi
  compose up -d --no-build --pull never --remove-orphans || die "Rollback could not start the previous release."
  if wait_healthy "$HEALTH_GATE_SECONDS"; then ok "Rolled back to $(cat "$RB_DIR/tag")."; else warn "The previous release is not healthy either — see: sudo ./liveoverlay.sh logs"; fi
  [ ! -f "$RB_DIR/git-head" ] || warn "Source checkout: the code is still at the new commit (git checkout $(cat "$RB_DIR/git-head") to match)."
}

# Keep the current and the previous release's images, remove older ones of our repository.
prune_old_releases() {
  local repo cur prev ref
  repo="$(env_get LIVEOVERLAY_IMAGE_REPO)"; [ -n "$repo" ] || { docker image prune -f >/dev/null 2>&1 || true; return 0; }
  cur="$(env_get LIVEOVERLAY_TAG)"; prev="$(cat "$RB_DIR/tag" 2>/dev/null || true)"
  docker images "$repo" --format '{{.Repository}}:{{.Tag}}' | while IFS= read -r ref; do
    case "$ref" in *"-$cur"|*"-$prev"|*:"<none>") continue ;; esac
    docker rmi "$ref" >/dev/null 2>&1 || true
  done
  docker image prune -f >/dev/null 2>&1 || true   # dangling only — rollback images are tagged
}

cmd_update() { # cmd_update [version]
  need_docker; need_env
  local stage="" target="${1:-}"
  if [ -n "$target" ]; then
    [[ "$target" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || die "Invalid version: $target"
    registry_mode || die "Only a registry install can switch versions (source checkout: git)."
  fi
  guard_no_license_stack
  # Releases from the licensing go-live on have no LICENSE_MODE=off: a box installed with it
  # (or with no license URL) would show the unlicensed watermark after this update.
  local relicense=0
  if ! license_configured; then
    warn "Licensing is REQUIRED from this release on (the temporary LICENSE_MODE=off is gone)."
    if interactive; then prompt_license; relicense=1
    else warn "No license server set — after the update the TV shows the watermark until: sudo ./liveoverlay.sh license"; fi
  fi
  stack_ready || warn "The stack is not fully healthy BEFORE the update — a rollback would return to this state."
  record_release
  pre_update_backup
  [ -z "$target" ] || { set_env LIVEOVERLAY_TAG "$target"; ok "Target release: $target"; }
  if [ "$BUNDLE" = 1 ]; then
    registry_mode || die "No image repository set. Run: sudo ./liveoverlay.sh registry"
    local img; img="$(env_get LIVEOVERLAY_IMAGE_REPO):bundle-$(env_get LIVEOVERLAY_TAG)"
    bold "Fetching release $img…"
    docker pull -q "$img" >/dev/null || { set_env LIVEOVERLAY_TAG "$(cat "$RB_DIR/tag")"; die "Could not pull $img (token revoked? tag not published?). Nothing was changed."; }
    stage="$(mktemp -d)"
    unpack_bundle_to "$img" "$stage"
    bold "Pulling the release's images…"
    docker compose --env-file "$ENV_FILE" -f "$stage/docker/docker-compose.prod.yml" --profile mdns pull \
      || { rm -rf "$stage"; set_env LIVEOVERLAY_TAG "$(cat "$RB_DIR/tag")"; die "Image pull failed. Nothing was changed. (sudo ./liveoverlay.sh registry --rotate if the token expired)"; }
    install_staged "$stage"; rm -rf "$stage"
    ok "Release files updated."
  else
    git -C "$ROOT" pull --ff-only || die "git pull failed (local changes?). Nothing was changed."
    if registry_mode; then compose pull || die "docker pull failed. Nothing was restarted."; else compose build || die "Build failed. Nothing was restarted."; fi
  fi
  migrate_env; ensure_timezone; prepare_dirs
  compose up -d --no-build --pull never --remove-orphans || true
  if wait_healthy "$HEALTH_GATE_SECONDS"; then
    prune_old_releases
    ok "Update complete: $(env_get LIVEOVERLAY_TAG). Previous release kept for: sudo ./liveoverlay.sh rollback"
    cmd_urls
    # Not part of the release gate (a license-server outage must never roll back a release).
    [ "$relicense" = 0 ] || ensure_license || warn "License not active yet — fix it with: sudo ./liveoverlay.sh license"
  else
    warn "The new release did not pass the ${HEALTH_GATE_SECONDS}s health gate — rolling back automatically."
    do_rollback yes
    die "Update FAILED and was rolled back. Diagnose with: sudo ./liveoverlay.sh logs"
  fi
}

cmd_rollback() {
  need_docker; need_env
  local yn=n
  echo "Roll back to the release recorded $(cat "$RB_DIR/when" 2>/dev/null || echo '(none)') [tag $(cat "$RB_DIR/tag" 2>/dev/null || echo '?')]."
  if [ -f "$RB_DIR/db-backup" ] && interactive; then
    echo "  The database can also go back to its pre-update backup — changes made since the update are LOST."
    read -r -p "  Restore the pre-update database too? [y/N]: " yn || yn=n
  fi
  if [[ "$yn" =~ ^[Yy] ]]; then do_rollback yes; else do_rollback no; fi
}

# ── Backups (Q39) ───────────────────────────────────────────────────────────
cmd_backup() {
  need_docker; need_env
  local f
  f="$(docker exec liveoverlay-backup lo-backup now "${1:-}" | tail -1)" || die "Backup failed — see: sudo ./liveoverlay.sh logs backup"
  ok "Backup written: backups/${f#/backups/}"
  env_has BACKUP_TARGET || warn "It is on the same disk as the data. Off-box copy: sudo ./liveoverlay.sh backup-target <dir>"
}

cmd_backup_target() {
  need_env
  local dir="${1:-}"
  [ -n "$dir" ] || die "usage: sudo ./liveoverlay.sh backup-target <mounted dir>|off"
  if [ "$dir" = off ]; then set_env BACKUP_TARGET ""; ok "Off-box backup copy disabled."; compose up -d backup >/dev/null; return 0; fi
  [[ "$dir" = /* ]] || die "Give an absolute path (e.g. /media/usb/liveoverlay-backups)."
  [[ "$dir" != *"'"* && "$dir" != *" "* ]] || die "Path must not contain spaces or quotes."
  [ -d "$dir" ] || die "$dir does not exist — mount the USB disk / network share first."
  if [ "$(df -P "$dir" | awk 'NR==2{print $1}')" = "$(df -P "$ROOT" | awk 'NR==2{print $1}')" ]; then
    warn "$dir is on the SAME disk as LiveOverlay — that protects against nothing but deleting files."
  fi
  touch "$dir/.liveoverlay-backup-target" || die "Cannot write to $dir."
  set_env BACKUP_TARGET "$dir"
  compose up -d backup >/dev/null
  ok "Backups are copied to $dir after each run (only while it is mounted — the marker file"
  echo "  $dir/.liveoverlay-backup-target must be present). Media too: set BACKUP_MEDIA=1 in docker/.env."
}

cmd_restore() {
  need_docker; need_env
  local f="${1:-}" yn work keep_repo keep_tag keep_label
  [ -n "$f" ] || { echo "Backups:"; docker exec liveoverlay-backup lo-backup list 2>/dev/null | sed 's/^/  backups\//'; die "usage: sudo ./liveoverlay.sh restore <backups/…tar.gz>"; }
  [ -f "$f" ] || f="$ROOT/$f"
  [ -f "$f" ] || die "No such file: $1"
  tar -tzf "$f" liveoverlay-backup/MANIFEST >/dev/null 2>&1 || die "$f is not a LiveOverlay backup."
  tar -xzOf "$f" liveoverlay-backup/MANIFEST | sed 's/^/  /'
  warn "This REPLACES the database, config and settings with the backup's. Media files are not touched."
  read -r -p "  Type RESTORE to continue: " yn
  [ "$yn" = RESTORE ] || die "Aborted."
  bold "Taking a safety backup of the current state first…"
  cmd_backup pre-restore || die "Safety backup failed — not restoring."
  work="$(mktemp -d)"
  tar -xzf "$f" -C "$work"
  compose down
  rm -rf "$ROOT/config.pre-restore"; mv "$ROOT/config" "$ROOT/config.pre-restore"
  mkdir -p "$ROOT/config"; cp -a "$work/liveoverlay-backup/config/." "$ROOT/config/"
  if [ -f "$work/liveoverlay-backup/docker/.env" ]; then
    # Keep what belongs to THIS machine: release, registry, capture card, off-box target.
    keep_repo="$(env_get LIVEOVERLAY_IMAGE_REPO)"; keep_tag="$(env_get LIVEOVERLAY_TAG)"; keep_label="$(env_get CAPTURE_DEVICE_LABEL)"
    local keep_target; keep_target="$(env_get BACKUP_TARGET)"
    cat "$work/liveoverlay-backup/docker/.env" > "$ENV_FILE"
    set_env LIVEOVERLAY_IMAGE_REPO "$keep_repo"; set_env LIVEOVERLAY_TAG "$keep_tag"
    set_env CAPTURE_DEVICE_LABEL "$keep_label"; set_env BACKUP_TARGET "$keep_target"
  fi
  if [ -d "$work/liveoverlay-backup/docker/certs" ]; then
    rm -rf "$CERT_DIR"; cp -a "$work/liveoverlay-backup/docker/certs" "$CERT_DIR"
  fi
  rm -rf "$work"
  cmd_up
  ok "Restored from $f. The previous config is in config.pre-restore/ (delete it once all is well)."
}

# ── TLS certificate (Q21) ───────────────────────────────────────────────────
cmd_certs() {
  need_docker; need_env
  prepare_dirs
  if [ "${1:-}" = --renew ]; then
    rm -f "$CERT_DIR/tls.crt" "$CERT_DIR/tls.key"
    compose up -d --force-recreate nginx >/dev/null
    sleep 3
    ok "New certificate generated — phones must accept it again."
  fi
  docker exec liveoverlay-nginx sh -c 'openssl x509 -in /tmp/lo-tls/tls.crt -noout -subject -enddate -fingerprint -sha256 -ext subjectAltName' 2>/dev/null \
    || warn "nginx is not running (sudo ./liveoverlay.sh up)."
  echo "  Phones: open https://liveoverlay.local/dashboard/ and accept the warning once; compare the"
  echo "  SHA-256 fingerprint above with the one the browser shows. After the LAN IP changes: --renew."
}

# ── Kiosk (Q12/Q13) ─────────────────────────────────────────────────────────
cmd_kiosk() {
  need_env
  local script="$ROOT/scripts/kiosk-setup.sh" url="" args=()
  [ -f "$script" ] || die "$script is missing (update the bundle: sudo ./liveoverlay.sh update)."
  if is_wsl; then set_env KIOSK off; warn "WSL: no TV kiosk — open http://localhost/ in a Windows browser."; return 0; fi
  # A kiosk token for the player URL (the loopback bypass works without one, but a token keeps
  # the kiosk working if the loopback rule ever changes and identifies it in the dashboard).
  if docker ps --format '{{.Names}}' | grep -qx liveoverlay-api && admin_credentials; then
    url="$(api_admin kiosk-url 2>/dev/null || true)"
    [ -n "$url" ] && ok "Kiosk token issued (listed in the dashboard; revoke it there)." || warn "Could not issue a kiosk token — the kiosk uses the loopback URL."
  fi
  [ -n "$url" ] && args+=(--url "$url")
  [ "${1:-}" != --mode ] || args+=(--mode "${2:-cage}")
  [ "${LO_YES:-0}" != 1 ] || args+=(--yes)
  bash "$script" install "${args[@]}"
  set_env KIOSK on
}

# ── Firewall / hardening / demo hotspot ─────────────────────────────────────
cmd_firewall() { bash "$ROOT/scripts/firewall.sh" "${1:-apply}"; }
cmd_harden()   { bash "$ROOT/scripts/host-hardening.sh" apply; }

cmd_demo() {
  need_env
  local script="$ROOT/scripts/demo-hotspot.sh"
  case "${1:-status}" in
    up)
      local out ssid pass gw body
      out="$(bash "$script" up --print-env)" || die "Hotspot failed to start."
      ssid="$(sed -n "s/^HOTSPOT_SSID='\(.*\)'$/\1/p" <<< "$out")"
      pass="$(sed -n "s/^HOTSPOT_PASSPHRASE='\(.*\)'$/\1/p" <<< "$out")"
      gw="$(sed -n "s/^HOTSPOT_GATEWAY='\(.*\)'$/\1/p" <<< "$out")"
      echo; bold "Demo hotspot is up (isolated: no internet, no LAN, only the demo page)"
      echo "  SSID       : $ssid"
      echo "  Passphrase : $pass   ← new for this session"
      echo "  Address    : http://$gw/demo/"
      body="$(printf '{"wifiSsid":"%s","wifiPassword":"%s","publicHost":"%s"}' "$ssid" "$pass" "$gw")"
      if admin_credentials && [ "$(LO_BODY="$body" api_admin demo-config 2>/dev/null)" = ok ]; then
        ok "Saved to the dashboard's Demo Mode — print the card from there (its Wi-Fi QR is updated)."
      else
        warn "Enter these in the dashboard → Demo Mode (Wi-Fi name/password, address $gw), then print the card."
      fi ;;
    down) bash "$script" down ;;
    status) bash "$script" status ;;
    *) die "usage: sudo ./liveoverlay.sh demo up|down|status" ;;
  esac
}

# ── Install ─────────────────────────────────────────────────────────────────
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

  # A database copied along with the repo already has a user, so the admin typed above would
  # never be seeded (the api seeds only an empty users table).
  local old=() f yn
  for f in "$ROOT"/config/liveoverlay.db* "$ROOT/config/license.enc"; do [ -e "$f" ] && old+=("$f"); done
  if [ "${#old[@]}" -gt 0 ]; then
    warn "config/ already holds a database. Its users would override the admin above."
    read -r -p "  Move it aside to backups/ so a fresh database is created? [Y/n]: " yn || yn=y
    if [[ ! "${yn:-y}" =~ ^[Nn] ]]; then
      local dest; dest="$ROOT/backups/pre-install-$(date +%Y%m%d-%H%M%S)"
      mkdir -p "$dest"; for f in "${old[@]}"; do mv "$f" "$dest/"; done
      ok "Old database moved to $dest"
    fi
  fi

  secret="$(head -c 48 /dev/urandom | base64 | tr -d '\n/+=' | head -c 64)"
  umask 077
  mkdir -p "$(dirname "$ENV_FILE")"
  : > "$ENV_FILE"; chown root:root "$ENV_FILE"; chmod 600 "$ENV_FILE"
  set_env JWT_SECRET "$secret"
  set_env ADMIN_EMAIL "$email"
  set_env ADMIN_PASSWORD "$pw"
  set_env API_UID "$API_UID_DEFAULT"; set_env API_GID "$API_UID_DEFAULT"
  pick_camera
  set_env CAPTURE_DEVICE_LABEL "$SELECTED_LABEL"
  prompt_timezone
  prompt_license
  if [ -n "${LO_BOOT_REPO:-}" ]; then
    # Handed over by bootstrap (standalone first run), which already ran docker login.
    set_env LIVEOVERLAY_IMAGE_REPO "$LO_BOOT_REPO"
    set_env LIVEOVERLAY_TAG "${LO_BOOT_TAG:-latest}"
  else
    prompt_registry
  fi
  ok "Wrote docker/.env (root only). More settings: docker/.env.example"
}

cmd_install() {
  [ "$(uname -s)" = Linux ] || die "The appliance runs on Linux. (For development on Windows/macOS use: pnpm dev)"
  cmd_install_docker
  need_docker
  guard_no_license_stack
  if [ ! -s /etc/machine-id ]; then
    { command -v systemd-machine-id-setup >/dev/null 2>&1 && systemd-machine-id-setup >/dev/null 2>&1; } \
      || tr -d '-' < /proc/sys/kernel/random/uuid > /etc/machine-id \
      || die "/etc/machine-id is missing and could not be created."
    ok "Created /etc/machine-id"
  fi
  if [ -f "$ENV_FILE" ]; then
    ok "docker/.env already exists — keeping it. (Delete it to re-run the questions.)"
    migrate_env
    license_configured || prompt_license
    env_has LIVEOVERLAY_TIMEZONE || prompt_timezone
  else
    write_env
  fi
  if [ -d /run/systemd/system ]; then
    systemctl is-enabled --quiet docker 2>/dev/null || systemctl enable --now docker >/dev/null 2>&1 || warn "Could not enable docker on boot."
  fi
  cmd_up
  # The license is required: the api must have enrolled with the activation code AND validated
  # over mutual TLS before the install goes on (kiosk, firewall, hardening).
  ensure_license || die "Install stopped: the license is required. Fix it, then re-run: sudo ./liveoverlay.sh install
  (everything entered so far is kept in docker/.env)"

  if is_wsl; then
    set_env KIOSK off
    echo "WSL: no TV kiosk, firewall or host hardening — open http://localhost/ in a Windows browser."
  else
    local yn=y
    if [ "$(env_get KIOSK)" != on ]; then
      read -r -p "Set up the TV kiosk on this mini-PC's screen (dedicated locked-down user)? [Y/n]: " yn || yn=n
      if [[ "${yn:-y}" =~ ^[Nn] ]]; then set_env KIOSK off; else cmd_kiosk || warn "Kiosk setup failed — retry: sudo ./liveoverlay.sh kiosk"; fi
    fi
    read -r -p "Turn on the host firewall (80/443 + SSH from the LAN only)? [Y/n]: " yn || yn=n
    [[ "${yn:-y}" =~ ^[Nn] ]] || cmd_firewall apply || warn "Firewall not applied — retry: sudo ./liveoverlay.sh firewall apply"
    cmd_harden || warn "Hardening incomplete — retry: sudo ./liveoverlay.sh harden"
  fi
  seal_admin_password
  echo
  bold "Done. Reboot once (sudo reboot) so the kiosk and the boot settings take over the screen."
  echo "  Then log in to https://liveoverlay.local/dashboard/ with your admin email and change the password."
}

# ── Main ────────────────────────────────────────────────────────────────────
case "${1:-}" in ""|-h|--help|help) usage; exit 0 ;; esac
become_root "$@"

# Copied alone onto the machine: fetch the release first, whatever command was asked.
if [ ! -f "$COMPOSE_FILE" ]; then bootstrap "$@"; fi

cmd="$1"; shift
case "$cmd" in
  install) cmd_install ;;
  up|start) cmd_up ;;
  down|stop) cmd_down ;;
  restart) cmd_down; cmd_up ;;
  status|ps) cmd_status ;;
  logs) cmd_logs "$@" ;;
  update) cmd_update "${1:-}" ;;
  rollback) cmd_rollback ;;
  backup) cmd_backup "${1:-}" ;;
  backup-target) cmd_backup_target "${1:-}" ;;
  restore) cmd_restore "${1:-}" ;;
  kiosk) cmd_kiosk "$@" ;;
  cameras) cmd_cameras ;;
  certs) cmd_certs "${1:-}" ;;
  firewall) cmd_firewall "${1:-apply}" ;;
  demo) cmd_demo "${1:-status}" ;;
  harden) cmd_harden ;;
  timezone) cmd_timezone "${1:-}" ;;
  registry) cmd_registry "${1:-}" ;;
  license) cmd_license ;;
  install-docker) cmd_install_docker ;;
  *) usage; exit 1 ;;
esac

#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Paste release asset URLs here. Leave empty to skip a mod.
# Links must point to the file itself (/releases/download/...).
# ============================================================
METAMOD_URL=""
MULTIADDONMANAGER_URL=""   # steamrt3 build
SQL_MM_URL=""
CS2MENUS_URL=""
CS2KZ_URL=""               # full package on first install, -upgrade package for updates

LIBSSL_DEB_URL="http://deb.debian.org/debian/pool/main/o/openssl/libssl1.1_1.1.1w-0+deb11u1_amd64.deb"
CONTAINER="cs2"
# ============================================================

cd "$(dirname "$(readlink -f "$0")")"
DATA="$PWD/cs2-data"
CSGO="$DATA/game/csgo"
BIN="$DATA/game/bin/linuxsteamrt64"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -d "$CSGO" ]] || die "$CSGO not found; start the server once so the game files exist"
for c in curl tar unzip file docker; do
  command -v "$c" >/dev/null || die "missing dependency: $c"
done

SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

install_mod() {
  local name=$1 url=$2
  [[ -z $url ]] && return 0

  local archive="$TMP/$name.archive" extract="$TMP/$name"
  log "$name: downloading"
  curl -fsSL -o "$archive" "$url" || die "$name: download failed ($url)"
  mkdir -p "$extract"

  case $(file -b "$archive") in
    gzip*|XZ*|bzip2*|Zstandard*|POSIX\ tar*) tar -xf "$archive" -C "$extract" ;;
    Zip*) unzip -q -o "$archive" -d "$extract" ;;
    *) die "$name: not an archive ($(file -b "$archive" | cut -c1-50)); check the URL" ;;
  esac

  local src
  src=$(find "$extract" -type d -name addons -printf '%d %h\n' | sort -n | head -1 | cut -d' ' -f2-)
  [[ -n $src ]] || die "$name: no addons/ directory found in archive"

  log "$name: installing to game/csgo/"
  $SUDO cp -a "$src/." "$CSGO/"
}

install_libssl() {
  [[ -f "$BIN/libssl.so.1.1" && -f "$BIN/libcrypto.so.1.1" ]] && return 0
  log "libssl 1.1: missing, installing"
  local deb="$TMP/libssl.deb" out="$TMP/libssl"
  curl -fsSL -o "$deb" "$LIBSSL_DEB_URL" || die "libssl download failed; update LIBSSL_DEB_URL"
  mkdir -p "$out"
  if command -v dpkg-deb >/dev/null; then
    dpkg-deb -x "$deb" "$out"
  else
    (cd "$out" && ar x "$deb" && tar -xf data.tar.*)
  fi
  $SUDO cp "$out"/usr/lib/x86_64-linux-gnu/lib{ssl,crypto}.so.1.1 "$BIN/"
}

patch_gameinfo() {
  local gi="$CSGO/gameinfo.gi"
  if ! grep -q "csgo/addons/metamod" "$gi"; then
    log "gameinfo.gi: adding Metamod search path"
    $SUDO sed -i '/Game_LowViolence/a\\t\t\tGame\tcsgo/addons/metamod' "$gi"
  fi
}

install_prehook() {
  local pre="$DATA/pre.sh"
  [[ -f $pre ]] && grep -q "csgo/addons/metamod" "$pre" && return 0
  log "pre.sh: adding gameinfo.gi patch (survives CS2 updates)"
  [[ -f $pre ]] || echo '#!/bin/bash' | $SUDO tee "$pre" >/dev/null
  $SUDO tee -a "$pre" >/dev/null <<'EOF'
gi=/home/steam/cs2-dedicated/game/csgo/gameinfo.gi
grep -q "csgo/addons/metamod" "$gi" || sed -i '/Game_LowViolence/a\\t\t\tGame\tcsgo/addons/metamod' "$gi"
EOF
  $SUDO chmod +x "$pre"
}

was_running=false
if [[ -n $(docker ps -q -f "name=^${CONTAINER}$") ]]; then
  was_running=true
  log "stopping $CONTAINER"
  docker compose stop "$CONTAINER"
fi

backup="$PWD/backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup"
dirs=()
[[ -d "$CSGO/addons" ]] && dirs+=(addons)
[[ -d "$CSGO/cfg" ]] && dirs+=(cfg)
if ((${#dirs[@]})); then
  log "backing up ${dirs[*]} to ${backup#$PWD/}"
  $SUDO tar -czf "$backup/csgo-addons-cfg.tar.gz" -C "$CSGO" "${dirs[@]}"
fi

install_mod metamod "$METAMOD_URL"
install_mod multiaddonmanager "$MULTIADDONMANAGER_URL"
install_mod sql_mm "$SQL_MM_URL"
install_mod cs2menus "$CS2MENUS_URL"
install_mod cs2kz "$CS2KZ_URL"

install_libssl
patch_gameinfo
install_prehook

log "fixing ownership"
$SUDO chown -R 1000:1000 "$CSGO/addons" "$CSGO/cfg" "$CSGO/gameinfo.gi" \
  "$BIN"/lib{ssl,crypto}.so.1.1 "$DATA/pre.sh"

if $was_running; then
  log "starting $CONTAINER"
  docker compose start "$CONTAINER"
  [[ -x ./workshop.sh ]] && { log "loading workshop collection"; ./workshop.sh || warn "workshop.sh failed"; }
  log "done; verify with: meta list"
else
  log "done; start with: docker compose up -d"
fi

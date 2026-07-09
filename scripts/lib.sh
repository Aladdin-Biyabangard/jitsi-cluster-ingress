#!/usr/bin/env bash
# Shared helpers for remote setup scripts

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Root lazımdır: sudo $0"
    exit 1
  fi
}

wait_apt() {
  # fuser yoxdursa (psmisc) — kilidi yoxlamadan davam
  if ! command -v fuser >/dev/null 2>&1; then
    return 0
  fi
  local n=0
  while fuser --quiet /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock 2>/dev/null; do
    warn "apt kilidi gözlənilir..."
    sleep 5
    n=$((n + 1))
    if (( n > 60 )); then
      warn "apt kilidi 5 dəq-dən çox — davam edilir"
      break
    fi
  done
}

ensure_packages() {
  # Əskik paket varsa apt ilə quraşdır (artıq olanları keç)
  local missing=()
  local pkg
  for pkg in "$@"; do
    if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
      missing+=("${pkg}")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    log "Paketlər quraşdırılır: ${missing[*]}"
    wait_apt
    apt-get install -y -qq "${missing[@]}"
  fi
}

ensure_cmds() {
  # Əmrlər yoxdursa — paket adları ilə quraşdır (cmd:pkg cütləri)
  # Nümunə: ensure_cmds curl:curl jq:jq "python3:python3"
  local pair cmd pkg need=()
  for pair in "$@"; do
    cmd="${pair%%:*}"
    pkg="${pair##*:}"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      need+=("${pkg}")
    fi
  done
  if (( ${#need[@]} > 0 )); then
    ensure_packages "${need[@]}"
  fi
}

install_base() {
  export DEBIAN_FRONTEND=noninteractive
  wait_apt
  apt-get update -qq
  apt-get install -y -qq \
    apt-transport-https ca-certificates curl gnupg2 \
    software-properties-common ufw jq unzip \
    dnsutils openssl python3 psmisc
}

# Recorder VM: Jibri + Chrome + Xvfb + ALSA + upload asılılıqları
install_recorder_deps() {
  export DEBIAN_FRONTEND=noninteractive
  ensure_cmds \
    curl:curl \
    jq:jq \
    python3:python3 \
    ffmpeg:ffmpeg \
    Xvfb:xvfb
  ensure_packages alsa-utils

  # snd-aloop üçün kernel extra (GCP Ubuntu-da bəzən ayrı paketdir)
  local kextra="linux-modules-extra-$(uname -r)"
  if ! modinfo snd-aloop >/dev/null 2>&1; then
    if apt-cache show "${kextra}" >/dev/null 2>&1; then
      ensure_packages "${kextra}" || warn "${kextra} quraşdırıla bilmədi — ALSA loopback yoxlanacaq"
    fi
  fi

  # Google Chrome (Jibri dependency) — yoxdursa quraşdır
  if ! command -v google-chrome-stable >/dev/null 2>&1 && ! command -v google-chrome >/dev/null 2>&1; then
    log "Google Chrome quraşdırılır..."
    mkdir -p /usr/share/keyrings
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
      | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list
    wait_apt
    apt-get update -qq
    apt-get install -y google-chrome-stable
  fi

  # Chrome binary symlink (bəzi Jibri versiyaları google-chrome gözləyir)
  if command -v google-chrome-stable >/dev/null 2>&1 && [[ ! -e /usr/bin/google-chrome ]]; then
    ln -sf /usr/bin/google-chrome-stable /usr/bin/google-chrome
  fi
}

add_jitsi_repo() {
  if [[ ! -f /usr/share/keyrings/jitsi-keyring.gpg ]]; then
    curl -fsSL https://download.jitsi.org/jitsi-key.gpg.key \
      | gpg --dearmor -o /usr/share/keyrings/jitsi-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/jitsi-keyring.gpg] https://download.jitsi.org stable/" \
      > /etc/apt/sources.list.d/jitsi-stable.list
    apt-get update -qq
  fi
}

apply_sysctl() {
  local src="${1:-/tmp/jitsi-cluster/config/sysctl-jitsi.conf}"
  if [[ -f "$src" ]]; then
    cp "$src" /etc/sysctl.d/99-jitsi.conf
    sysctl -p /etc/sysctl.d/99-jitsi.conf >/dev/null || true
  fi
}

ufw_base() {
  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH
}

metadata() {
  # GCP instance metadata
  curl -s -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/${1}" 2>/dev/null || true
}

private_ip() {
  hostname -I | awk '{print $1}'
}

public_ip() {
  curl -4 -s --max-time 5 ifconfig.me || curl -4 -s --max-time 5 icanhazip.com || true
}

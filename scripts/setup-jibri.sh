#!/usr/bin/env bash
# Recorder VM: bir neçə Jibri prosesi (systemd jibri@N) → Bunny upload → delete
# JIBRI_PER_VM=5 → eyni hostda 5 paralel recording slot
# Default cluster: 2 VM × 5 = 10 eyni anda recording

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_root

DOMAIN="${DOMAIN:?}"
CONTROL_PRIVATE_IP="${CONTROL_PRIVATE_IP:?}"
JIBRI_RECORDER_PASS="${JIBRI_RECORDER_PASS:?}"
JIBRI_XMPP_PASS="${JIBRI_XMPP_PASS:?}"
RECORDER_HOST_ID="${RECORDER_HOST_ID:-$(hostname -s)}"
JIBRI_PER_VM="${JIBRI_PER_VM:-5}"
BUNNY_LIBRARY_ID="${BUNNY_LIBRARY_ID:-}"
BUNNY_API_KEY="${BUNNY_API_KEY:-}"
BUNNY_CDN_HOSTNAME="${BUNNY_CDN_HOSTNAME:-}"

if ! [[ "${JIBRI_PER_VM}" =~ ^[0-9]+$ ]] || (( JIBRI_PER_VM < 1 || JIBRI_PER_VM > 20 )); then
  err "JIBRI_PER_VM 1–20 arası olmalıdır (indi: ${JIBRI_PER_VM})"
  exit 1
fi

log "Recorder setup: host=${RECORDER_HOST_ID} slots=${JIBRI_PER_VM} control=${CONTROL_PRIVATE_IP}"

install_base
add_jitsi_repo
install_recorder_deps
apply_sysctl "${SCRIPT_DIR}/../config/sysctl-jitsi.conf"

hostnamectl set-hostname "${RECORDER_HOST_ID}.${DOMAIN}"
grep -q "${DOMAIN}" /etc/hosts || echo "${CONTROL_PRIVATE_IP} ${DOMAIN}" >> /etc/hosts
grep -q "auth.${DOMAIN}" /etc/hosts || echo "${CONTROL_PRIVATE_IP} auth.${DOMAIN}" >> /etc/hosts
grep -q "recorder.${DOMAIN}" /etc/hosts || echo "${CONTROL_PRIVATE_IP} recorder.${DOMAIN}" >> /etc/hosts

# ALSA loopback — hər Jibri slot üçün ayrı kart
ALOOP_ENABLE="$(python3 - <<PY
n = int("${JIBRI_PER_VM}")
print(",".join(["1"] * n))
PY
)"
ALOOP_INDEX="$(python3 - <<PY
n = int("${JIBRI_PER_VM}")
print(",".join(str(i) for i in range(n)))
PY
)"
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/alsa-loopback.conf <<EOF
options snd-aloop enable=${ALOOP_ENABLE} index=${ALOOP_INDEX}
EOF
if ! grep -q '^snd-aloop' /etc/modules; then
  echo "snd-aloop" >> /etc/modules
fi
modprobe -r snd-aloop 2>/dev/null || true
if ! modprobe snd-aloop; then
  warn "snd-aloop yüklənmədi — audio loopback olmadan davam (recording səssiz ola bilər)"
fi

# Jibri paketi
wait_apt
apt-get install -y jibri
ensure_cmds jq:jq curl:curl Xvfb:xvfb ffmpeg:ffmpeg

# Default single jibri.service — multi-instance istifadə edirik
systemctl stop jibri 2>/dev/null || true
systemctl disable jibri 2>/dev/null || true

mkdir -p /srv/recordings /opt/jitsi-jibri /etc/jitsi/jibri/instances /var/log/jitsi
chown jibri:jibri /srv/recordings
# Finalize / upload logları — jibri user yazabilsin (5 paralel slot)
touch /var/log/jitsi/recording-finalize.log /var/log/jitsi/bunny-uploads.jsonl
chown -R jibri:jibri /var/log/jitsi
chmod 755 /var/log/jitsi
chmod 644 /var/log/jitsi/recording-finalize.log /var/log/jitsi/bunny-uploads.jsonl

cat > /opt/jitsi-jibri/bunny.env <<ENV
BUNNY_LIBRARY_ID=${BUNNY_LIBRARY_ID}
BUNNY_API_KEY=${BUNNY_API_KEY}
BUNNY_CDN_HOSTNAME=${BUNNY_CDN_HOSTNAME}
ENV
chmod 600 /opt/jitsi-jibri/bunny.env
chown jibri:jibri /opt/jitsi-jibri/bunny.env

cp "${SCRIPT_DIR}/bunny-upload.sh" /opt/jitsi-jibri/bunny-upload.sh
cp "${SCRIPT_DIR}/finalize_recording.sh" /opt/jitsi-jibri/finalize_recording.sh
chmod 755 /opt/jitsi-jibri/bunny-upload.sh /opt/jitsi-jibri/finalize_recording.sh
chown jibri:jibri /opt/jitsi-jibri/*.sh

# launch.sh path — Debian/Ubuntu paketində fərqli ola bilər
LAUNCH=""
for p in /opt/jitsi/jibri/launch.sh /usr/share/jibri/launch.sh; do
  if [[ -x "${p}" ]]; then
    LAUNCH="${p}"
    break
  fi
done
if [[ -z "${LAUNCH}" ]]; then
  if [[ -f /lib/systemd/system/jibri.service ]]; then
    LAUNCH="$(grep -E '^ExecStart=' /lib/systemd/system/jibri.service | head -1 | cut -d= -f2- | awk '{print $1}')"
  fi
fi
if [[ -z "${LAUNCH}" || ! -x "${LAUNCH}" ]]; then
  err "Jibri launch.sh tapılmadı"
  exit 1
fi

# Wrapper: hər slot üçün ayrı HOME / Xvfb DISPLAY / ALSA
# (paket launch.sh tez-tez DISPLAY=:0 hardcode edir — ona görə Xvfb-ni özümüz idarə edirik)
cat > /opt/jitsi-jibri/run-jibri-slot.sh <<WRAP
#!/usr/bin/env bash
set -euo pipefail
SLOT="\${1:?slot}"
export HOME="/var/lib/jibri/slot-\${SLOT}"
export DISPLAY=":\${SLOT}"
export JAVA_SYS_PROPS="-Dconfig.file=/etc/jitsi/jibri/instances/\${SLOT}.conf"
mkdir -p "\${HOME}" "/tmp/jibri-chrome-\${SLOT}" "/tmp/.X11-unix" "/tmp/jibri-upload-\${SLOT}"

# Slot üçün Xvfb (əgər yoxdursa)
if ! pgrep -f "Xvfb :\${SLOT} " >/dev/null 2>&1; then
  if ! command -v Xvfb >/dev/null 2>&1; then
    echo "Xvfb yoxdur — xvfb paketini quraşdırın" >&2
    exit 1
  fi
  Xvfb ":\${SLOT}" -screen 0 1280x720x24 -ac +extension RANDR >/tmp/xvfb-\${SLOT}.log 2>&1 &
  sleep 1
fi

# launch.sh içində DISPLAY=:0 varsa — müvəqqəti patch edilmiş nüsxə
LAUNCH_SRC="${LAUNCH}"
LAUNCH_COPY="/opt/jitsi-jibri/launch-slot-\${SLOT}.sh"
cp "\${LAUNCH_SRC}" "\${LAUNCH_COPY}"
chmod 755 "\${LAUNCH_COPY}"
# Hardcoded :0 → bu slotun display-i
sed -i -E "s/DISPLAY=:0/DISPLAY=:\${SLOT}/g; s/Xvfb :0/Xvfb :\${SLOT}/g; s/:0 /:\${SLOT} /g" "\${LAUNCH_COPY}" || true
# Əgər launch artıq Xvfb başladırsa, ikinci dəfə uğursuz ola bilər — ignore
exec "\${LAUNCH_COPY}"
WRAP
chmod 755 /opt/jitsi-jibri/run-jibri-slot.sh

cat > /etc/systemd/system/jibri@.service <<UNIT
[Unit]
Description=Jitsi Jibri instance %i
After=network.target sound.target
Wants=network-online.target

[Service]
User=jibri
Group=jibri
UMask=0022
Type=simple
Environment=HOME=/var/lib/jibri/slot-%i
ExecStart=/opt/jitsi-jibri/run-jibri-slot.sh %i
Restart=on-failure
RestartSec=5
# 5 paralel Chrome+ffmpeg üçün kifayət qədər limit
LimitNOFILE=65536
LimitNPROC=4096
TasksMax=infinity
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT

ufw_base
ufw allow from 10.0.0.0/8
ufw --force enable
usermod -aG adm,audio,video,plugdev jibri 2>/dev/null || true

systemctl daemon-reload

# Köhnə instance-ları söndür (JIBRI_PER_VM azalıbsa)
shopt -s nullglob
for old in /etc/jitsi/jibri/instances/*.conf; do
  idx="$(basename "${old}" .conf)"
  if ! [[ "${idx}" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > JIBRI_PER_VM )); then
    systemctl disable --now "jibri@${idx}" 2>/dev/null || true
    rm -f "${old}"
  fi
done
shopt -u nullglob

ACTIVE=0
for i in $(seq 1 "${JIBRI_PER_VM}"); do
  NICK="${RECORDER_HOST_ID}-slot-${i}"
  EXT_PORT=$((2222 + i - 1))
  INT_PORT=$((3333 + i - 1))
  REC_DIR="/srv/recordings/slot-${i}"
  SLOT_HOME="/var/lib/jibri/slot-${i}"
  # ALSA kart indeksi 0-based
  CARD=$((i - 1))
  mkdir -p "${REC_DIR}" "${SLOT_HOME}" "/tmp/jibri-chrome-${i}" "/tmp/jibri-upload-${i}"
  chown -R jibri:jibri "${REC_DIR}" "${SLOT_HOME}" "/tmp/jibri-chrome-${i}" "/tmp/jibri-upload-${i}"

  # Hər slot öz loopback kartına bağlanır
  cat > "${SLOT_HOME}/.asoundrc" <<ASOUND
pcm.!default {
  type plug
  slave.pcm "dsnoop_${CARD}"
}
pcm.dsnoop_${CARD} {
  type dsnoop
  ipc_key $((8000 + CARD))
  slave {
    pcm "hw:${CARD},0,0"
    channels 2
  }
}
ctl.!default {
  type hw
  card ${CARD}
}
ASOUND
  chown jibri:jibri "${SLOT_HOME}/.asoundrc"

  cat > "/etc/jitsi/jibri/instances/${i}.conf" <<JIBRI
jibri {
  id = "${NICK}"
  single-use-mode = false

  recording {
    recordings-directory = "${REC_DIR}"
    finalize-script = "/opt/jitsi-jibri/finalize_recording.sh"
  }

  api {
    http {
      external-api-port = ${EXT_PORT}
      internal-api-port = ${INT_PORT}
    }
    xmpp {
      environments = [
        {
          name = "prod"
          xmpp-server-hosts = [ "${CONTROL_PRIVATE_IP}" ]
          xmpp-domain = "${DOMAIN}"

          control-muc {
            domain = "internal.auth.${DOMAIN}"
            room-name = "JibriBrewery"
            nickname = "${NICK}"
          }

          control-login {
            domain = "auth.${DOMAIN}"
            username = "jibri"
            password = "${JIBRI_XMPP_PASS}"
          }

          call-login {
            domain = "recorder.${DOMAIN}"
            username = "recorder"
            password = "${JIBRI_RECORDER_PASS}"
          }

          strip-from-room-domain = "conference."
          usage-timeout = 0
          trust-all-xmpp-certs = true
        }
      ]
    }
  }

  chrome {
    flags = [
      "--use-fake-ui-for-media-stream",
      "--start-maximized",
      "--kiosk",
      "--enabled",
      "--disable-infobars",
      "--autoplay-policy=no-user-gesture-required",
      "--ignore-certificate-errors",
      "--user-data-dir=/tmp/jibri-chrome-${i}"
    ]
  }

  ffmpeg {
    resolution = "1280x720"
  }
}
JIBRI
  chown jibri:jibri "/etc/jitsi/jibri/instances/${i}.conf"

  systemctl enable "jibri@${i}"
  systemctl restart "jibri@${i}"
  sleep 2
  if systemctl is-active --quiet "jibri@${i}"; then
    log "Jibri aktiv: ${NICK} (DISPLAY=:${i} ports ${EXT_PORT}/${INT_PORT})"
    ACTIVE=$((ACTIVE + 1))
  else
    warn "Jibri start olmadı: jibri@${i} — journalctl -u jibri@${i} -n 40"
    journalctl -u "jibri@${i}" --no-pager -n 25 || true
  fi
done

log "Recorder ${RECORDER_HOST_ID}: ${ACTIVE}/${JIBRI_PER_VM} Jibri slot aktiv"
if (( ACTIVE < 1 )); then
  err "Heç bir Jibri slot işə düşmədi"
  exit 1
fi
if (( ACTIVE < JIBRI_PER_VM )); then
  warn "Yalnız ${ACTIVE}/${JIBRI_PER_VM} slot işləyir — paralel capacity azalacaq"
fi

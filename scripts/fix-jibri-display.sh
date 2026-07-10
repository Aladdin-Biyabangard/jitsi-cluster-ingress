#!/usr/bin/env bash
# Fix: Jibri Java often has DISPLAY=:0 → ffmpeg x11grab fails.
# Wrap ffmpeg to rewrite :0.0 → :N.0 from HOME slot / X socket.
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "root lazımdır" >&2
  exit 1
fi

# Real ffmpeg
if [[ ! -x /usr/bin/ffmpeg.real ]]; then
  if [[ -x /usr/bin/ffmpeg && ! -L /usr/bin/ffmpeg ]]; then
    mv /usr/bin/ffmpeg /usr/bin/ffmpeg.real
  fi
fi

cat > /usr/local/bin/jibri-ffmpeg-wrapper <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail

SLOT=""
if [[ "${HOME:-}" =~ slot-([0-9]+) ]]; then
  SLOT="${BASH_REMATCH[1]}"
elif [[ -f "${HOME:-}/.jibri-slot" ]]; then
  SLOT="$(cat "${HOME}/.jibri-slot")"
fi
if [[ -z "$SLOT" ]]; then
  for n in 1 2 3 4 5; do
    if [[ -S "/tmp/.X11-unix/X${n}" ]]; then
      SLOT="$n"
      break
    fi
  done
fi
SLOT="${SLOT:-1}"
export DISPLAY=":${SLOT}"

# Rewrite args: :0.0+0,0 or :0.0 → :N.0+0,0
ARGS=()
for a in "$@"; do
  case "$a" in
    :0|:0.0|:0.0+0,0|*:0.0+0,0)
      ARGS+=(":${SLOT}.0+0,0")
      ;;
    *)
      # also replace embedded :0.0
      a="${a//:0.0+0,0/:${SLOT}.0+0,0}"
      a="${a//:0.0/:${SLOT}.0}"
      ARGS+=("$a")
      ;;
  esac
done

echo "$(date -Iseconds) DISPLAY=${DISPLAY} SLOT=${SLOT} ffmpeg ${ARGS[*]}" >> /tmp/jibri-ffmpeg-wrapper.log 2>/dev/null || true

REAL="/usr/bin/ffmpeg.real"
[[ -x "$REAL" ]] || REAL="/usr/bin/ffmpeg"
exec "$REAL" "${ARGS[@]}"
WRAP
chmod 755 /usr/local/bin/jibri-ffmpeg-wrapper

# Prefer wrapper on PATH ahead of /usr/bin
ln -sfn /usr/local/bin/jibri-ffmpeg-wrapper /usr/local/bin/ffmpeg
# Also replace /usr/bin/ffmpeg if not already real
if [[ -L /usr/bin/ffmpeg ]] || [[ ! -e /usr/bin/ffmpeg.real ]]; then
  :
fi
if [[ -x /usr/bin/ffmpeg.real ]]; then
  ln -sfn /usr/local/bin/jibri-ffmpeg-wrapper /usr/bin/ffmpeg
fi

# Ensure chrome wrapper still forces slot DISPLAY (not :0)
cat > /usr/local/bin/jibri-chrome-wrapper <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
SLOT=""
for arg in "$@"; do
  case "$arg" in
    --user-data-dir=/tmp/jibri-chrome-*)
      s="${arg##*-}"
      [[ "$s" =~ ^[0-9]+$ ]] && SLOT="$s"
      ;;
  esac
done
if [[ -z "$SLOT" && "${HOME:-}" =~ slot-([0-9]+) ]]; then
  SLOT="${BASH_REMATCH[1]}"
fi
if [[ -z "$SLOT" && -f "${HOME:-}/.jibri-slot" ]]; then
  SLOT="$(cat "${HOME}/.jibri-slot")"
fi
if [[ -n "$SLOT" ]]; then
  export DISPLAY=":${SLOT}"
elif [[ -z "${DISPLAY:-}" || "${DISPLAY}" == ":0" ]]; then
  for n in 1 2 3 4 5; do
    [[ -S "/tmp/.X11-unix/X${n}" ]] && { export DISPLAY=":${n}"; break; }
  done
fi
export DISPLAY="${DISPLAY:-:1}"
REAL="/usr/bin/google-chrome-stable.real"
[[ -x "$REAL" ]] || REAL="/opt/google/chrome/google-chrome"
exec "$REAL" "$@"
WRAP
chmod 755 /usr/local/bin/jibri-chrome-wrapper
ln -sfn /usr/local/bin/jibri-chrome-wrapper /usr/bin/google-chrome-stable
ln -sfn /usr/local/bin/jibri-chrome-wrapper /usr/bin/google-chrome

# Make sure run-jibri-slot puts /usr/local/bin first and DISPLAY correct
cat > /opt/jitsi-jibri/run-jibri-slot.sh <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
SLOT="${1:?slot}"
CONF="/etc/jitsi/jibri/instances/${SLOT}.conf"
export HOME="/var/lib/jibri/slot-${SLOT}"
export DISPLAY=":${SLOT}"
mkdir -p "${HOME}" "/tmp/jibri-chrome-${SLOT}" "/tmp/.X11-unix" "/tmp/jibri-upload-${SLOT}"
echo "${SLOT}" > "${HOME}/.jibri-slot"

pkill -f "Xvfb :${SLOT} " >/dev/null 2>&1 || true
sleep 0.3
Xvfb ":${SLOT}" -screen 0 1920x1080x24 -ac +extension RANDR >/tmp/xvfb-${SLOT}.log 2>&1 &
for _ in $(seq 1 15); do
  [[ -S "/tmp/.X11-unix/X${SLOT}" ]] && break
  sleep 0.4
done

LAUNCH_SRC="/opt/jitsi/jibri/launch.sh"
LAUNCH_COPY="/opt/jitsi-jibri/launch-slot-${SLOT}.sh"
cp "${LAUNCH_SRC}" "${LAUNCH_COPY}"
chmod 755 "${LAUNCH_COPY}"
sed -i -E "s|-Dconfig.file=[^ ]*|-Dconfig.file=${CONF}|g" "${LAUNCH_COPY}" || true
sed -i -E "s|config.file=\"/etc/jitsi/jibri/jibri.conf\"|config.file=\"${CONF}\"|g" "${LAUNCH_COPY}" || true
sed -i -E "s/DISPLAY=:0/DISPLAY=:${SLOT}/g; s/Xvfb :0/Xvfb :${SLOT}/g; s/:0 /:${SLOT} /g" "${LAUNCH_COPY}" || true

exec env -i \
  PATH="/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin" \
  HOME="${HOME}" \
  DISPLAY=":${SLOT}" \
  USER=jibri \
  LOGNAME=jibri \
  LANG="${LANG:-C.UTF-8}" \
  "${LAUNCH_COPY}"
WRAP
chmod 755 /opt/jitsi-jibri/run-jibri-slot.sh
chown jibri:jibri /opt/jitsi-jibri/run-jibri-slot.sh

# Disable prejoin for recorder UX is client-side; also ensure chrome has no-sandbox flags
python3 - <<'PY'
from pathlib import Path
for p in Path("/etc/jitsi/jibri/instances").glob("*.conf"):
    t = p.read_text()
    if "--no-sandbox" not in t:
        t = t.replace('      "--enabled",\n', "")
        t = t.replace(
            '      "--ignore-certificate-errors",',
            '      "--ignore-certificate-errors",\n      "--no-sandbox",\n      "--disable-dev-shm-usage",\n      "--disable-gpu",',
            1,
        )
        p.write_text(t)
        print("patched", p)
    else:
        print("ok", p)
PY

systemctl daemon-reload
for i in 1 2 3 4 5; do
  systemctl restart "jibri@${i}" || true
done
sleep 5
systemctl is-active jibri@1 jibri@2 jibri@3 jibri@4 jibri@5

# Smoke ffmpeg wrapper
sudo -u jibri env HOME=/var/lib/jibri/slot-4 DISPLAY=:0 \
  /usr/bin/ffmpeg -f x11grab -video_size 1920x1080 -i :0.0+0,0 -frames:v 1 -y /tmp/ffmpeg-smoke.mp4 \
  >/tmp/ffmpeg-smoke.out 2>&1 || true
echo "ffmpeg wrapper log:"; tail -3 /tmp/jibri-ffmpeg-wrapper.log 2>/dev/null || true
if grep -q "Cannot open display" /tmp/ffmpeg-smoke.out 2>/dev/null; then
  echo FFMPEG_SMOKE_FAIL
  tail -10 /tmp/ffmpeg-smoke.out
else
  echo FFMPEG_SMOKE_OK
  ls -la /tmp/ffmpeg-smoke.mp4 2>/dev/null || true
fi
echo "fix done on $(hostname)"

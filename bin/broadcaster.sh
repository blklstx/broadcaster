#!/usr/bin/env bash
set -euo pipefail

# ---- URLs ----
PUBLIC_STREAM_URL="${PUBLIC_STREAM_URL:-}"
ICECAST_URL="${ICECAST_URL:-}"

# ---- Discord ----
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"  # recommend: export in env or systemd EnvironmentFile
STREAM_PUBLIC_URL="${PUBLIC_STREAM_URL:-}" # included in Discord notifications so listeners can easily click to listen when stream goes online

# ---- Local capture (Traktor Audio 6) ----
ALSA_DEVICE="${ALSA_DEVICE:-plughw:CARD=T6,DEV=0}"
RATE="${RATE:-44100}" # e.g. 44100 or 48000, should match the capture device sample rate for best results
IN_FMT="${IN_FMT:-S32_LE}" # e.g. "S32_LE" for 32-bit signed little-endian (Traktor Audio 6), "S16_LE" for 16-bit signed little-endian, etc. Check with `arecord -L` and `arecord -D <device> --dump-hw-params` for your device.
IN_CH="${IN_CH:-2}" # e.g. 2 for stereo, 1 for mono. If your device is stereo but you want mono, you can set IN_CH=1 and ffmpeg will automatically downmix to mono.

# ---- Encode ----
BITRATE="${BITRATE:-256k}" # e.g. "256k" for MP3, ignored for WAV

OUTPUT_CODEC="pcm_s16le"  # e.g. "libmp3lame" for MP3, "pcm_s16le" for WAV (for debugging)
OUTPUT_CONTENT_TYPE="audio/wav"  # e.g. "audio/mpeg" for MP3, "audio/wav" for WAV (for debugging)
OUTPUT_FORMAT="${OUTPUT_FORMAT:-wav}"  # e.g. "mp3" or "wav" (for debugging)

# ---- Gain / safety ----
# Start conservative: 6 dB gain + limiter. If still quiet, bump GAIN_DB to 9dB or 12dB.
GAIN_DB="${GAIN_DB:-6dB}" # e.g. "6dB", "9dB", "12dB", etc. Adjust based on your input levels and desired output volume. If your input is already hot (e.g. -10 dB max), you might want to set GAIN_DB=0dB or even a negative gain to avoid clipping. If your input is very quiet (e.g. -40 dB max), you can try 6dB, 9dB, or 12dB gain to boost the volume, but be careful with clipping if the input suddenly gets louder.
#LIMITER="${LIMITER:-alimiter=limit=-1.0dB:level=true}" # hard limit at -1.0 dB to prevent clipping, with "level=true" it will also reduce gain if input is too hot, otherwise it would just hard clip and sound bad. Note that the limiter adds some latency (e.g. 100-200ms) so if you need very low latency, you can try removing the limiter and just use a fixed gain, but be careful with clipping.
LIMITER="${LIMITER:-}" # for very low latency, you can try removing the limiter and just use a fixed gain, but be careful with clipping. If you have enough headroom in your input levels, you can also keep the limiter for safety and set a higher gain (e.g. 9dB or 12dB) to get more volume without clipping.

# ---- Start detection (local input) ----
ACTIVE_THRESHOLD_DB="${ACTIVE_THRESHOLD_DB:--45}"        # start if local max_volume > this

# ---- Stop detection (public stream silence) ----
REMOTE_SILENCE_THRESHOLD_DB="${REMOTE_SILENCE_THRESHOLD_DB:--55}"   # if public stream max_volume <= this => "silent"
CHECK_EVERY_SECONDS="${CHECK_EVERY_SECONDS:-60}"
STOP_AFTER_SILENCE_MINUTES="${STOP_AFTER_SILENCE_MINUTES:-5}"

# ---- Runtime ----
PIDFILE="/tmp/broadcaster.pid"     # stores "FFMPEG_PID"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

notify_discord() {
  local state="$1"  # ONLINE / OFFLINE
  local msg="$2"

  [[ -z "${DISCORD_WEBHOOK_URL}" ]] && return 0

  # Debounce: don't send same state twice
  local statefile="/tmp/state"
  local prev=""
  [[ -f "$statefile" ]] && prev="$(cat "$statefile" 2>/dev/null || true)"
  if [[ "$prev" == "$state" ]]; then
    return 0
  fi
  echo "$state" > "$statefile"

  curl -sS -H "Content-Type: application/json" \
    -d "{\"content\":\"${msg}\"}" \
    "$DISCORD_WEBHOOK_URL" >/dev/null || true
}

notify_online() {
  notify_discord "ONLINE" "🟢 **LIVE ON AIR**\nKuuntele: ${STREAM_PUBLIC_URL}"
}

notify_offline() {
  notify_discord "OFFLINE" "🔴 **LIVE OFFLINE**\n(Stopped after 5 min silence / source disconnect)"
}

read_pid() {
  [[ -f "$PIDFILE" ]] || return 1
  local ffpid
  read -r ffpid < "$PIDFILE" 2>/dev/null || return 1
  [[ "${ffpid:-}" =~ ^[0-9]+$ ]] || return 1
  echo "$ffpid"
}

is_running() {
  local ffpid
  ffpid="$(read_pid)" || return 1
  kill -0 "$ffpid" 2>/dev/null
}

broadcaster_stop() {
  if [[ ! -f "$PIDFILE" ]]; then
    return 0
  fi

  local ffpid
  if ffpid="$(read_pid)"; then
    log "Stopping broadcaster (ffmpeg=$ffpid) ..."
    kill "$ffpid" 2>/dev/null || true
    sleep 0.3
    kill -9 "$ffpid" 2>/dev/null || true
  else
    log "Stopping broadcaster (pidfile unreadable) ..."
  fi

  rm -f "$PIDFILE" 2>/dev/null || true
  log "Broadcaster stopped."
  notify_offline
}

cleanup() {
  log "Exiting..."
  broadcaster_stop
  exit 0
}
trap cleanup INT TERM

broadcaster_start() {
  if is_running; then
    local ffpid
    ffpid="$(read_pid)" || true
    log "Broadcaster already running (ffmpeg=$ffpid)."
    return 0
  fi

  log "Starting broadcaster: ${ALSA_DEVICE} (${IN_FMT}/${IN_CH}ch/${RATE}) -> ${OUTPUT_FORMAT} ${BITRATE} (gain ${GAIN_DB})"
  notify_online

  ffmpeg -hide_banner -nostdin -loglevel warning \
    -f alsa -thread_queue_size 16384 \
    -ac "${IN_CH}" -ar "${RATE}" -sample_fmt s32 \
    -i "${ALSA_DEVICE}" \
    -af "volume=${GAIN_DB},${LIMITER},aresample=async=1:first_pts=0" \
    -codec:a "${OUTPUT_CODEC}" -b:a "${BITRATE}" -minrate "${BITRATE}" -maxrate "${BITRATE}" -bufsize 512k \
    -content_type "${OUTPUT_CONTENT_TYPE}" \
    -f "${OUTPUT_FORMAT}" "${ICECAST_URL}" >/dev/null 2>&1 &

  local ffpid=$!
  echo "$ffpid" > "$PIDFILE"
  log "Broadcaster started (ffmpeg=$ffpid)."
}

measure_local_max_db() {
  # Returns local max_volume (e.g. -26.3) or "-999" on failure
  local out mv
  out="$(
    timeout 10s bash -lc \
      "ffmpeg -hide_banner -nostdin -loglevel info \
        -f alsa -thread_queue_size 4096 \
        -ac '${IN_CH}' -ar '${RATE}' -sample_fmt s32 \
        -i '${ALSA_DEVICE}' -t 5 \
        -af volumedetect -f null - 2>&1"
  )" || true

  mv="$(echo "$out" | awk -F': ' '/max_volume/ {print $2}' | awk '{print $1}' | tail -n 1)"
  [[ -n "${mv:-}" ]] && echo "$mv" || echo "-999"
}

measure_remote_max_db() {
  # Returns PUBLIC stream max_volume or "-999" on failure.
  local out mv
  out="$(
    timeout 15s bash -lc \
      "ffmpeg -hide_banner -nostdin -loglevel info \
        -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
        -i '${PUBLIC_STREAM_URL}' -t 5 \
        -af volumedetect -f null - 2>&1"
  )" || true

  mv="$(echo "$out" | awk -F': ' '/max_volume/ {print $2}' | awk '{print $1}' | tail -n 1)"
  [[ -n "${mv:-}" ]] && echo "$mv" || echo "-999"
}

log "Broadcaster db measurer started."

silence_minutes=0

while true; do
  if is_running; then
    rmax="$(measure_remote_max_db)"
    if [[ "$rmax" == "-999" ]]; then
      log "Remote probe failed (-999 dB). Not stopping (network/CF/etc)."
      sleep "$CHECK_EVERY_SECONDS"
      continue
    fi

    log "Remote max_volume: ${rmax} dB"
    is_silent="$(awk -v r="$rmax" -v t="$REMOTE_SILENCE_THRESHOLD_DB" 'BEGIN{print (r<=t) ? 1 : 0}')"

    if [[ "$is_silent" == "1" ]]; then
      silence_minutes=$((silence_minutes + 1))
      log "Remote silence minute ${silence_minutes}/${STOP_AFTER_SILENCE_MINUTES}"
      if (( silence_minutes >= STOP_AFTER_SILENCE_MINUTES )); then
        log "Remote silent for ${STOP_AFTER_SILENCE_MINUTES} minutes -> stopping stream."
        broadcaster_stop
        silence_minutes=0
      fi
    else
      silence_minutes=0
    fi

    sleep "$CHECK_EVERY_SECONDS"
    continue
  fi

  # Not streaming: check local once per minute
  lmax="$(measure_local_max_db)"
  if [[ "$lmax" == "-999" ]]; then
    log "Local measure failed (-999 dB) -> skipping"
    sleep "$CHECK_EVERY_SECONDS"
    continue
  fi

  is_active="$(awk -v r="$lmax" -v t="$ACTIVE_THRESHOLD_DB" 'BEGIN{print (r>t) ? 1 : 0}')"
  
  log "Local max_volume: ${lmax} dB -> active: ${is_active}"

  if [[ "$is_active" == "1" ]]; then
    broadcaster_start
  fi

  sleep "$CHECK_EVERY_SECONDS"
done

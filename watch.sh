#!/bin/sh
# audioout - watch-folder audio extractor
#
# Polls $WATCH_DIR/inbox for video files, extracts the audio track into
# $WATCH_DIR/audio, optionally trimming trailing silence. Runs entirely
# offline - no network access is needed at runtime.

set -u

WATCH_DIR="${WATCH_DIR:-/watch}"
INBOX="$WATCH_DIR/inbox"
OUTPUT="$WATCH_DIR/audio"
PROCESSED="$WATCH_DIR/processed"
FAILED="$WATCH_DIR/failed"

OUTPUT_FORMAT="${OUTPUT_FORMAT:-copy}"            # copy = keep original audio codec (lossless, fast); mp3 = re-encode
MP3_QUALITY="${MP3_QUALITY:-2}"                   # libmp3lame VBR quality, 0 (best, ~245kbps) .. 9 (worst)
TRIM_SILENCE="${TRIM_SILENCE:-true}"              # remove silence at the end of the file
SILENCE_THRESHOLD="${SILENCE_THRESHOLD:--50dB}"   # anything quieter than this counts as silence
SILENCE_MIN_DURATION="${SILENCE_MIN_DURATION:-2}" # quiet must last at least this many seconds to be trimmed
SILENCE_PADDING="${SILENCE_PADDING:-0.5}"         # seconds of the silence kept so the ending doesn't cut abruptly
CUT_LAST_SECONDS="${CUT_LAST_SECONDS:-0}"         # always chop this many seconds off the end (e.g. end credits); 0 = off
ON_SUCCESS="${ON_SUCCESS:-move}"                  # move source to processed/ | delete it
POLL_INTERVAL="${POLL_INTERVAL:-30}"              # seconds between inbox scans
STABLE_SECONDS="${STABLE_SECONDS:-10}"            # file must be unmodified this long before processing
PUID="${PUID:-}"                                  # optional: chown outputs to this uid
PGID="${PGID:-}"                                  # optional: chown outputs to this gid

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

is_video_ext() {
  case "$1" in
    mp4|m4v|mkv|webm|mov|avi|wmv|flv|mpg|mpeg|ts|mts|m2ts|3gp|vob) return 0 ;;
    *) return 1 ;;
  esac
}

# Prints the length (seconds) to keep if the audio (up to second $2) ends in
# silence, else nothing. Works by scanning with the silencedetect filter and
# checking whether the last detected silence runs to the end of that region.
find_cut_point() {
  in="$1"
  dur="$2"
  ffmpeg -nostdin -hide_banner -i "$in" -map 0:a:0 -vn -sn -dn \
    -af "silencedetect=noise=${SILENCE_THRESHOLD}:d=${SILENCE_MIN_DURATION}" \
    -t "$dur" -f null - 2>&1 \
  | awk -v dur="$dur" -v pad="$SILENCE_PADDING" '
      /silence_start:/ { for (i = 1; i <= NF; i++) if ($i == "silence_start:") start = $(i+1) }
      /silence_end:/   { for (i = 1; i <= NF; i++) if ($i == "silence_end:")   end   = $(i+1) }
      END {
        if (start == "") exit
        # Trailing silence: the last silence never ended, or ended at EOF.
        if (end == "" || end + 0 < start + 0 || dur - end <= 1) {
          cut = start + pad
          if (cut > 1 && cut < dur) printf "%.3f", cut
        }
      }'
}

process_file() {
  src="$1"
  name="$(basename "$src")"
  stem="${name%.*}"

  # A [cutNN] tag in the filename overrides CUT_LAST_SECONDS for this file,
  # e.g. "show s01e02 [cut85].mkv" chops the last 85 seconds (end credits).
  cut_last="$CUT_LAST_SECONDS"
  tag="$(printf '%s' "$stem" | sed -n 's/.*\[cut\([0-9][0-9]*\)\].*/\1/p')"
  if [ -n "$tag" ]; then
    cut_last="$tag"
    stem="$(printf '%s' "$stem" | sed 's/ *\[cut[0-9][0-9]*\]//')"
  fi

  dur="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$src")"
  acodec="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$src")"
  if [ -z "$acodec" ]; then
    log "ERROR: $name has no audio stream"
    return 1
  fi

  mode="$OUTPUT_FORMAT"
  ext=mp3
  if [ "$mode" = copy ]; then
    case "$acodec" in
      aac|alac)  ext=m4a ;;
      mp3)       ext=mp3 ;;
      opus)      ext=opus ;;
      vorbis)    ext=ogg ;;
      flac)      ext=flac ;;
      *) log "$name: codec '$acodec' has no standalone audio container; re-encoding to mp3"
         mode=mp3 ;;
    esac
  fi

  # Region to keep after chopping the end credits (if configured).
  keep="$dur"
  if [ -n "$dur" ] && [ "$cut_last" != 0 ]; then
    keep="$(awk -v d="$dur" -v c="$cut_last" 'BEGIN { k = d - c; if (k > 1) printf "%.3f", k }')"
    if [ -z "$keep" ]; then
      log "$name: cut of last ${cut_last}s ignored (file is only ${dur}s long)"
      keep="$dur"
    else
      log "$name: cutting last ${cut_last}s (credits), keeping first ${keep}s of ${dur}s"
    fi
  fi

  cut=""
  if [ "$TRIM_SILENCE" = true ] && [ -n "$keep" ]; then
    cut="$(find_cut_point "$src" "$keep")"
    [ -n "$cut" ] && log "$name: trailing silence found, keeping first ${cut}s"
  fi
  if [ -z "$cut" ] && [ "$keep" != "$dur" ]; then
    cut="$keep"
  fi

  out="$OUTPUT/$stem.$ext"
  [ -e "$out" ] && out="$OUTPUT/$stem.$(date +%s).$ext"
  tmp="$OUTPUT/.tmp.$$.$ext"

  set -- -map 0:a:0 -vn -sn -dn -map_metadata 0
  if [ "$mode" = copy ]; then
    set -- "$@" -c:a copy
  else
    set -- "$@" -c:a libmp3lame -q:a "$MP3_QUALITY"
  fi
  [ -n "$cut" ] && set -- "$@" -t "$cut"

  if ! ffmpeg -nostdin -hide_banner -loglevel error -y -i "$src" "$@" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$out"
  chmod 664 "$out"
  [ -n "$PUID" ] && chown "${PUID}:${PGID:-$PUID}" "$out" 2>/dev/null
  log "$name -> ${out#"$WATCH_DIR"/}"
}

mkdir -p "$INBOX" "$OUTPUT" "$PROCESSED" "$FAILED"
log "audioout started (format=$OUTPUT_FORMAT trim_silence=$TRIM_SILENCE threshold=$SILENCE_THRESHOLD min_silence=${SILENCE_MIN_DURATION}s poll=${POLL_INTERVAL}s)"
log "drop video files into ${INBOX}"

while :; do
  touch "$WATCH_DIR/.heartbeat"
  find "$INBOX" -maxdepth 1 -type f | while IFS= read -r f; do
    name="$(basename "$f")"
    case "$name" in
      .*|*.part|*.tmp|*.crdownload) continue ;;
    esac
    ext="$(printf '%s' "${name##*.}" | tr '[:upper:]' '[:lower:]')"
    is_video_ext "$ext" || continue

    # Skip files that are still being copied in over the network.
    now=$(date +%s)
    mtime=$(stat -c %Y "$f" 2>/dev/null) || continue
    if [ $((now - mtime)) -lt "$STABLE_SECONDS" ]; then
      log "$name: recently modified, waiting for copy to finish"
      continue
    fi
    s1=$(stat -c %s "$f")
    sleep 2
    s2=$(stat -c %s "$f" 2>/dev/null) || continue
    if [ "$s1" != "$s2" ]; then
      log "$name: still growing, waiting"
      continue
    fi

    log "processing $name"
    if process_file "$f"; then
      if [ "$ON_SUCCESS" = delete ]; then
        rm -f "$f"
        log "$name: done, source deleted"
      else
        mv "$f" "$PROCESSED/"
        log "$name: done, source moved to processed/"
      fi
    else
      mv "$f" "$FAILED/" 2>/dev/null
      log "$name: FAILED, source moved to failed/ (see log above)"
    fi
  done
  sleep "$POLL_INTERVAL"
done

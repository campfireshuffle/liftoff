#!/usr/bin/env bash
# Cuts a recorded take into a post-ready clip (1080p60 by default), with the soundtrack
# lined up so its big hit lands on the touchdown.
set -euo pipefail

usage() {
  cat <<'EOF'
Cut a recorded Liftoff take into a 60fps clip for posting (1080p unless WIDTH says otherwise).

Usage:
  scripts/cut-demo.sh <take.mov> <touchdown-seconds> <soundtrack> [output.mp4]
  scripts/cut-demo.sh -h | --help

<touchdown-seconds> is when the window touches down in the take; the take and soundtrack are
trimmed so the soundtrack's hit at HIT seconds (default 12.26, the big hit in the hover demo's
track) lands on it.
The thruster hiss from the take is mixed in underneath.

Environment:
  HIT=12.26      Time of the soundtrack hit to land on the touchdown.
  START=…        Where in the take the video starts. By default it starts wherever lines the
                 soundtrack up from its beginning; set it earlier to keep a long lead-in, and the
                 soundtrack comes in a little after the video starts.
  CROP_TOP=60    Pixels to cut from the top of the 4K take (the menu bar).
  SKY=0x0f0f11   Colour that fills the strip the crop leaves at the top.
  WIDTH=1920     Output width; 16:9 height follows (3840 for a 4K master).
EOF
}

case "${1:-}" in -h | --help | help | "") usage; exit 0 ;; esac
[[ $# -ge 3 ]] || { usage >&2; exit 2; }

take="$1" touchdown="$2" soundtrack="$3"
out="${4:-${take%.*}-cut.mp4}"
hit="${HIT:-12.26}" crop_top="${CROP_TOP:-60}" sky="${SKY:-0x0f0f11}"
width="${WIDTH:-1920}" height=$(( ${WIDTH:-1920} * 9 / 16 ))

# The video starts at `start` in the take. The soundtrack either starts `offset` seconds into the
# track, or comes in `delay` seconds into the video; one of those is zero.
read -r offset delay start length < <(python3 - "$take" "$soundtrack" "$touchdown" "$hit" "${START:-}" <<'PY'
import subprocess, sys
take, track, touchdown, hit = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
duration = lambda f: float(subprocess.check_output(
    ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", f]))
start = float(sys.argv[5]) if sys.argv[5] else max(touchdown - hit, 0)
lead = touchdown - start - hit  # when the soundtrack's own start falls in the video
offset, delay = max(-lead, 0), max(lead, 0)
print(f"{offset:.3f} {delay:.3f} {start:.3f} {min(duration(take) - start, delay + duration(track) - offset):.3f}")
PY
)
delay_ms=$(awk -v d="$delay" 'BEGIN { printf "%d", d * 1000 }')

fade_out=$(awk -v l="$length" 'BEGIN { printf "%.3f", l - 0.5 }')
ffmpeg -v error -y -ss "$start" -i "$take" -ss "$offset" -i "$soundtrack" -filter_complex "
[0:v]crop=iw:ih-${crop_top}:0:${crop_top},scale=${width}:-2:flags=lanczos,pad=${width}:${height}:0:(oh-ih):color=${sky},fps=60,format=yuv420p,fade=t=in:st=0:d=0.4,fade=t=out:st=${fade_out}:d=0.5[v];
[0:a]volume=18dB,highpass=f=120[hiss];
[1:a]adelay=${delay_ms}:all=1[music];
[music][hiss]amix=inputs=2:normalize=0:duration=longest,afade=t=out:st=${fade_out}:d=0.5[a]" \
  -map "[v]" -map "[a]" -t "$length" \
  -c:v libx264 -preset slow -crf 17 -profile:v high -c:a aac -b:a 192k -movflags +faststart "$out"
echo "$out (${length}s, take from ${start}s, soundtrack from ${offset}s coming in at ${delay}s)"

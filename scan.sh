#!/bin/zsh
# One-shot scan: scan -> auto-trim -> PNG in $OUT_DIR.
set -euo pipefail

# --- Tuning knobs -----------------------------------------------------------
DPI=600                 # scan resolution
THRESHOLD="50%"         # brightness cut between background and object (paper ~100%, ES-60W backing ~12%)
BLUR=4                  # blur radius before thresholding; hides dust and streaks on the backing
BACKGROUND="black"      # "black" (ES-60W feeder backing) or "white" (flatbed lid)
SHAVE=0                 # pixels shaved off every edge first (kills scanner-edge artefacts)
DESKEW_MIN=0.05         # degrees; skews smaller than this aren't worth resampling for
PAD=0                   # pixels of white padding added back after trimming
BLACK_POINT="0%"        # greys this dark or darker become black; raise (e.g. 30%) for punchier lines
GAMMA=0.7               # <1 darkens midtones (pencil), 1 = off; paper is already clipped white
SOURCE="feeder"         # "feeder" (sheet-fed, e.g. ES-60W) or "flatbed"
SCANNER=""              # exact scanner name; empty = first one found
OUT_DIR="${OUT_DIR:-$HOME/Scans}"
REVEAL=${REVEAL:-1}     # 1 = reveal the result in Finder
# ---------------------------------------------------------------------------

# Shortcuts/launchd run with a bare PATH.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

die() {
  print -u2 "scan: $1"
  osascript -e "display notification \"$1\" with title \"Scan failed\"" 2>/dev/null || true
  exit 1
}

command -v scanline >/dev/null || die "scanline not installed"
command -v magick   >/dev/null || die "ImageMagick not installed (brew install imagemagick)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

scan() {
  local args=(-tiff -resolution "$DPI" -dir "$tmp" -name raw)
  [[ $SOURCE == flatbed ]] && args+=(-flatbed)
  [[ -n $SCANNER ]] && args+=(-scanner "$SCANNER" -exactname)
  # scanline exits 0 even when it fails, so judge it by the file it leaves behind.
  scanline "${args[@]}" >"$tmp/scanline.log" 2>&1 || true
  local file=$(print -l "$tmp"/raw*.tif(N) | head -1)
  [[ -n $file ]] || die "scan failed: $(grep -iE 'error|fail|no scanner' "$tmp/scanline.log" | head -1)"
  print "$file"
}

# ./scan.sh <image> re-trims an existing scan (handy while tuning); no arg = scan.
if (( $# )); then
  [[ -f $1 ]] || die "no such file: $1"
  raw=$1
elif [[ -z ${SCANBUTTON:-} ]] && pkill -USR1 -x ScanButton; then
  # ScanButton.app holds the scanner session; let it run this scan for us.
  print "scan: handed off to ScanButton"
  exit 0
else
  raw=$(scan)
fi

mkdir -p "$OUT_DIR"
out="$OUT_DIR/scan-$(date +%Y%m%d-%H%M%S).png"

# The feeder driver pads short pages to Letter with pure white; strip that off the
# bottom first (zero fuzz, so real paper with sensor noise survives).
magick "$raw" -shave "${SHAVE}x${SHAVE}" -define trim:edges=south -trim +repage \
  -bordercolor "$BACKGROUND" -border 1 "$tmp/framed.tif"

# mask_info <image> <format>: evaluate <format> on a blurred, thresholded mask of the
# sheet (sheet = white). The mask is framed in black *after* blurring so measurements
# never key off a sheet touching the edge.
negate=(); [[ $BACKGROUND == white ]] && negate=(-negate)
mask_info() {
  magick "$1" -colorspace gray "${negate[@]}" -blur "0x$BLUR" -threshold "$THRESHOLD" \
    -shave 1x1 -bordercolor black -border 1 -format "$2" info:
}

# Warn when the sheet reaches the edge of the scan window: whatever lay beyond it
# was never scanned, so the output will be smaller than the sheet.
read fw fh bw bh bx by <<<"$(mask_info "$tmp/framed.tif" '%w %h %@' | tr 'x+' '  ')"
(( bw > 1 && bh > 1 )) || die "no sheet found; check BACKGROUND/THRESHOLD"
if (( bx <= 1 || by <= 1 || bx + bw >= fw - 1 || by + bh >= fh - 1 )); then
  print -u2 "scan: warning: sheet touches the scan edge, part of it may be missing; feed it straighter or more centred"
fi

# Straighten: rotate by the angle that makes the sheet's minimum-area rectangle upright.
# The rectangle's angle is ambiguous by 90°, so fold it into [-45°, 45°].
angle=$(mask_info "$tmp/framed.tif" '%[minimum-bounding-box:unrotate]')
(( angle > 45 )) && (( angle -= 90 ))
(( angle < -45 )) && (( angle += 90 ))
if (( ${angle#-} >= DESKEW_MIN )); then
  magick "$tmp/framed.tif" -background "$BACKGROUND" -rotate "$angle" +repage "$tmp/straight.tif"
else
  mv "$tmp/framed.tif" "$tmp/straight.tif"
fi

# Crop to the straightened sheet: its own size, whatever paper it is.
box=$(mask_info "$tmp/straight.tif" '%@')
magick "$tmp/straight.tif" -crop "$box" +repage \
  -level "$BLACK_POINT,100%,$GAMMA" \
  -bordercolor white -border "$PAD" -strip "$out"
size=$(magick identify -format '%wx%h' "$out")

print "$out ($size)"
(( REVEAL )) && open -R "$out"
exit 0

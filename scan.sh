#!/bin/zsh
# One-shot scan: scan -> auto-trim -> PNG in $OUT_DIR.
set -euo pipefail

# --- Tuning knobs -----------------------------------------------------------
DPI=600                 # scan resolution
THRESHOLD="50%"         # brightness cut between background and object (paper ~100%, ES-60W backing ~12%)
BLUR=4                  # blur radius before thresholding; hides dust and streaks on the backing
BACKGROUND="black"      # "black" (ES-60W feeder backing) or "white" (flatbed lid)
SHAVE=0                 # pixels shaved off every edge first (kills scanner-edge artefacts)
PAD=0                   # pixels of white padding added back after trimming
SOURCE="feeder"         # "feeder" (sheet-fed, e.g. ES-60W) or "flatbed"
SCANNER=""              # exact scanner name; empty = first one found
OUT_DIR="$HOME/Scans"
REVEAL=1                # 1 = reveal the result in Finder
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
else
  raw=$(scan)
fi

mkdir -p "$OUT_DIR"
out="$OUT_DIR/scan-$(date +%Y%m%d-%H%M%S).png"

# The feeder driver pads short pages to Letter with pure white; strip that off the
# bottom first (zero fuzz, so real paper with sensor noise survives).
magick "$raw" -shave "${SHAVE}x${SHAVE}" -define trim:edges=south -trim +repage \
  -bordercolor "$BACKGROUND" -border 1 "$tmp/framed.tif"

# Bounding box of a blurred, thresholded mask (object = white). Frame the mask in
# black *after* blurring so the box never keys off an object touching the edge.
negate=(); [[ $BACKGROUND == white ]] && negate=(-negate)
box=$(magick "$tmp/framed.tif" -colorspace gray "${negate[@]}" -blur "0x$BLUR" \
  -threshold "$THRESHOLD" -shave 1x1 -bordercolor black -border 1 -format '%@' info:)
[[ $box == 0x0* || $box == 1x1* ]] && die "no object found; check BACKGROUND/THRESHOLD"

magick "$tmp/framed.tif" -crop "$box" +repage \
  -bordercolor white -border "$PAD" -strip "$out"
size=$(magick identify -format '%wx%h' "$out")

print "$out ($size)"
(( REVEAL )) && open -R "$out"
exit 0

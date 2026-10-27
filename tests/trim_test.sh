#!/bin/zsh
# Regression tests for scan.sh's trim: synthetic ES-60W-style raw scans go through
# `scan.sh <file>`; the output must be the whole sheet, straightened, at its true size.
set -euo pipefail

root=${0:A:h:h}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export OUT_DIR="$tmp/out" REVEAL=0
failures=0

# raw <file> <sheet-w> <sheet-h> <angle> <centre-x> <centre-y>
# Letter-sized (600 dpi) black backing with streaks and dust, a pencil-marked white
# sheet, and the driver's pure-white padding below the scanned length.
raw() {
  local file=$1 w=$2 h=$3 a=$4 cx=$5 cy=$6
  local scanned=$(( cy + h / 2 + 150 ))
  magick -size 5100x6600 xc:'#1c1c1c' \
    -fill '#2a2a2a' -draw 'rectangle 1200,0 1203,6599' -draw 'rectangle 3900,0 3901,6599' \
    -fill '#b8b8b8' -draw 'rectangle 4500,800 4502,802' -draw 'rectangle 300,5200 301,5201' \
    -fill white -draw "translate $cx,$cy rotate $a rectangle $(( -w / 2 )),$(( -h / 2 )) $(( w / 2 - 1 )),$(( h / 2 - 1 ))" \
    -fill '#777777' -draw "translate $cx,$cy rotate $a rectangle -300,-200 300,-190" \
    -fill white -draw "rectangle 0,$scanned 5099,6599" \
    "$file"
}

# expect <name> <file> <w> <h> [warn]: output within 4 px of w×h, sheet up to every edge.
expect() {
  local name=$1 file=$2 w=$3 h=$4 warn=${5:-}
  local log="$tmp/$name.log" out
  "$root/scan.sh" "$file" >"$log" 2>&1 || { print "FAIL $name: scan.sh failed: $(cat $log)"; (( ++failures )); return; }
  out=$(ls -t "$OUT_DIR"/*.png | head -1)
  local gw gh; read gw gh <<<"$(magick identify -format '%w %h' "$out")"
  local problems=()
  (( gw >= w - 4 && gw <= w + 4 )) || problems+=("width $gw, want $w")
  (( gh >= h - 4 && gh <= h + 4 )) || problems+=("height $gh, want $h")
  # Edge strips just inside the 1-2 px anti-aliased paper edge, skipping the corners,
  # must be paper: a leftover skew would show up there as a wedge of backing.
  local strip mean
  for strip in "2x$(( gh * 8 / 10 ))+3+$(( gh / 10 ))" "2x$(( gh * 8 / 10 ))+$(( gw - 5 ))+$(( gh / 10 ))" \
               "$(( gw * 8 / 10 ))x2+$(( gw / 10 ))+3" "$(( gw * 8 / 10 ))x2+$(( gw / 10 ))+$(( gh - 5 ))"; do
    mean=$(magick "$out" -crop "$strip" -colorspace gray -format '%[fx:mean]' info:)
    (( mean > 0.9 )) || problems+=("backing at edge $strip (mean $mean)")
  done
  if [[ -n $warn ]]; then
    grep -q "touches the scan edge" "$log" || problems+=("no edge warning")
  fi
  rm -f "$out"
  if (( ${#problems} )); then print "FAIL $name: ${(j:; :)problems}"; (( ++failures ))
  else print "ok   $name (${gw}x${gh})"; fi
}

raw "$tmp/a6-cw.tif"        2480 3508  1.2 1500 1900; expect a6-portrait-skewed-cw   "$tmp/a6-cw.tif"        2480 3508
raw "$tmp/a6-ccw.tif"       2480 3508 -0.8 2600 1950; expect a6-portrait-skewed-ccw  "$tmp/a6-ccw.tif"       2480 3508
raw "$tmp/a6-land.tif"      3508 2480  0   1900 1400; expect a6-landscape-straight   "$tmp/a6-land.tif"      3508 2480
raw "$tmp/a5.tif"           3496 4960  0.6 2200 2600; expect a5-portrait-skewed      "$tmp/a5.tif"           3496 4960
raw "$tmp/receipt.tif"      1890 5000 -1.5 1100 2600; expect receipt-long-skewed     "$tmp/receipt.tif"      1890 5000
# Sheet hanging 100 px off the left of the scan window: keep what was scanned, and warn.
raw "$tmp/clipped.tif"      2480 3508  0   1140 1900; expect clipped-left-warns      "$tmp/clipped.tif"      2380 3508 warn

(( failures == 0 )) && print "all trim tests passed" || { print "$failures failed"; exit 1; }

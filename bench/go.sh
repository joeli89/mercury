#!/bin/bash
# Mercury compression benchmark.
#
# Compares the current pipeline (real-time HEVC ~0.025 bpp → x265) against
# alternatives, scoring every candidate against a near-lossless reference.
#
# Usage (from the repo root):
#   bash bench/go.sh               # uses the newest .mov/.mp4 on your Desktop
#   bash bench/go.sh path/to/clip  # uses a specific clip
#
# Make the clip with Cmd+Shift+5 → Record Entire Screen, ~60s of scrolling,
# typing, switching apps and dragging windows.
#
# Output: bench/out/results.md (+ results.csv, logs, encoded files).
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

FPS=60
W=1920; H=1080
cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="$ROOT/bench/out"
mkdir -p "$OUT/logs"
grep -qx 'bench/out/' .gitignore 2>/dev/null || printf '\n# Compression benchmark output\nbench/out/\n' >> .gitignore

now() { python3 -c 'import time; print(time.time())'; }
has_encoder() { ffmpeg -hide_banner -encoders 2>/dev/null | grep " $1 " >/dev/null; }
has_filter()  { ffmpeg -hide_banner -filters  2>/dev/null | grep " $1 " >/dev/null; }

command -v ffmpeg >/dev/null || { echo "ffmpeg not found — brew install ffmpeg"; exit 1; }
has_encoder libx265 || { echo "ffmpeg lacks libx265"; exit 1; }
HAS_VT=0; has_encoder hevc_videotoolbox && HAS_VT=1
HAS_VMAF=0; has_filter libvmaf && HAS_VMAF=1
[ $HAS_VMAF = 0 ] && echo "note: ffmpeg has no libvmaf — reporting SSIM/PSNR only (brew install ffmpeg with libvmaf for VMAF)"

# ── 1. Reference ──────────────────────────────────────────────────────────
# Uses the clip passed as $1, otherwise the newest .mov/.mp4 on the Desktop
# (e.g. a ⌘⇧5 screen recording).
REF="$OUT/reference.mov"
SRC_CLIP="${1:-}"
if [ -z "$SRC_CLIP" ]; then
  SRC_CLIP=$(python3 -c 'import glob,os; f=[p for p in glob.glob(os.path.expanduser("~/Desktop/*")) if p.lower().endswith((".mov",".mp4"))]; print(max(f,key=os.path.getmtime) if f else "")')
fi
[ -f "$SRC_CLIP" ] || { echo "No recording found. Record one with Cmd+Shift+5 (saves to Desktop), then re-run."; exit 1; }
echo "== Using: $SRC_CLIP =="
echo "== Converting to ${W}x${H}@${FPS} ProRes HQ reference =="
ffmpeg -hide_banner -loglevel error -y -i "$SRC_CLIP" -an \
  -vf "scale=${W}:${H}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2,fps=${FPS}" \
  -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le "$REF" || exit 1
SRC_MBPS=$(ffprobe -v quiet -show_entries format=bit_rate -of default=nw=1:nk=1 "$SRC_CLIP")
echo "   source bitrate: $(( ${SRC_MBPS:-0} / 1000000 )) Mbps"
REF_DUR=$(ffprobe -v quiet -show_entries format=duration -of default=nw=1:nk=1 "$REF")
echo "Reference: $REF (${REF_DUR}s)"

# ── 2. Encoders (mirror the app) ───────────────────────────────────────────
X265_PARAMS="keyint=$((FPS*10)):min-keyint=${FPS}:bframes=8:no-open-gop=1:aq-mode=4:sao=0:strong-intra-smoothing=0:rect=0"
CUR_KBPS=$(( W * H * FPS * 25 / 1000 / 1000 ))   # MovieWriter: w*h*fps*0.025

# name|input|description|ffmpeg video args|stage (live|post)
CANDIDATES=(
  "cur_live|REF|Current: real-time HEVC ${CUR_KBPS}kbps, GOP 2s|-c:v hevc_videotoolbox -realtime 1 -b:v ${CUR_KBPS}k -g $((FPS*2)) -pix_fmt nv12 -tag:v hvc1|live"
  "cur_final|cur_live|Current: x265 CRF28 from ↑|-c:v libx265 -crf 28 -preset medium -x265-params $X265_PARAMS -pix_fmt yuv420p10le -tag:v hvc1|post"
  "A_live|REF|A: real-time HEVC 25Mbps (clean intermediate)|-c:v hevc_videotoolbox -realtime 1 -b:v 25M -g $((FPS*2)) -pix_fmt nv12 -tag:v hvc1|live"
  "A_final|A_live|A: x265 CRF28 from ↑|-c:v libx265 -crf 28 -preset medium -x265-params $X265_PARAMS -pix_fmt yuv420p10le -tag:v hvc1|post"
  "A_final_slow|A_live|A: x265 CRF28 preset slow from A_live|-c:v libx265 -crf 28 -preset slow -x265-params $X265_PARAMS -pix_fmt yuv420p10le -tag:v hvc1|post"
  "B_q55|REF|B: real-time HEVC quality 55, GOP 10s|-c:v hevc_videotoolbox -realtime 1 -q:v 55 -g $((FPS*10)) -pix_fmt nv12 -tag:v hvc1|live"
  "B_q65|REF|B: real-time HEVC quality 65, GOP 10s|-c:v hevc_videotoolbox -realtime 1 -q:v 65 -g $((FPS*10)) -pix_fmt nv12 -tag:v hvc1|live"
  "B_q75|REF|B: real-time HEVC quality 75, GOP 10s|-c:v hevc_videotoolbox -realtime 1 -q:v 75 -g $((FPS*10)) -pix_fmt nv12 -tag:v hvc1|live"
  "ideal_x265|REF|Ceiling: x265 CRF28 straight from reference|-c:v libx265 -crf 28 -preset medium -x265-params $X265_PARAMS -pix_fmt yuv420p10le -tag:v hvc1|post"
)

CSV="$OUT/results.csv"
echo "name,description,stage,size_mb,mbps,encode_s,vmaf,ssim,psnr" > "$CSV"

score() { # $1=distorted → sets VMAF SSIM PSNR
  local d="$1"
  local log="$OUT/logs/$(basename "$d" .mp4)"
  VMAF="-"; SSIM="-"; PSNR="-"
  local norm="[0:v]scale=${W}:${H},format=yuv420p,setpts=PTS-STARTPTS"
  local rnorm="[1:v]format=yuv420p,setpts=PTS-STARTPTS"
  ffmpeg -hide_banner -nostats -i "$d" -i "$REF" -lavfi \
    "${norm},split[d1][d2];${rnorm},split[r1][r2];[d1][r1]ssim;[d2][r2]psnr" -f null - 2> "$log.metrics.txt"
  SSIM=$(sed -n 's/.*SSIM.* All:\([0-9.]*\).*/\1/p' "$log.metrics.txt" | tail -1)
  PSNR=$(sed -n 's/.*PSNR.* average:\([0-9.inf]*\).*/\1/p' "$log.metrics.txt" | tail -1)
  if [ $HAS_VMAF = 1 ]; then
    ffmpeg -hide_banner -nostats -i "$d" -i "$REF" -lavfi \
      "${norm}[d];${rnorm}[r];[d][r]libvmaf=n_threads=8:log_fmt=json:log_path=$log.vmaf.json" -f null - 2>/dev/null
    VMAF=$(python3 -c "import json;print(round(json.load(open('$log.vmaf.json'))['pooled_metrics']['vmaf']['mean'],2))" 2>/dev/null || echo "-")
  fi
}

for c in "${CANDIDATES[@]}"; do
  IFS='|' read -r NAME SRC DESC ARGS STAGE <<< "$c"
  IN="$REF"; [ "$SRC" != "REF" ] && IN="$OUT/$SRC.mp4"
  DST="$OUT/$NAME.mp4"
  echo "== $NAME — $DESC =="
  if [[ "$ARGS" == *videotoolbox* && $HAS_VT = 0 ]]; then echo "   skipped (no VideoToolbox)"; continue; fi
  [ -f "$IN" ] || { echo "   skipped (input $SRC missing)"; continue; }
  T0=$(now)
  # shellcheck disable=SC2086
  if ! ffmpeg -hide_banner -loglevel error -y -i "$IN" -an $ARGS -movflags +faststart "$DST" 2> "$OUT/logs/$NAME.encode.txt"; then
    echo "   FAILED — see bench/out/logs/$NAME.encode.txt"; rm -f "$DST"; continue
  fi
  T1=$(now)
  SIZE=$(python3 -c "import os,sys;print(os.path.getsize(sys.argv[1]))" "$DST")
  SEC=$(python3 -c "print(round($T1-$T0,1))")
  MB=$(python3 -c "print(round($SIZE/1048576,1))")
  MBPS=$(python3 -c "print(round($SIZE*8/1e6/$REF_DUR,2))")
  score "$DST"
  echo "   ${MB} MB  ${MBPS} Mbps  ${SEC}s  VMAF ${VMAF}  SSIM ${SSIM}  PSNR ${PSNR}"
  echo "$NAME,\"$DESC\",$STAGE,$MB,$MBPS,$SEC,$VMAF,$SSIM,$PSNR" >> "$CSV"
done

# ── 3. Report ─────────────────────────────────────────────────────────────
python3 - "$CSV" "$REF_DUR" "$OUT/results.md" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
dur = float(sys.argv[2])
with open(sys.argv[3], "w") as f:
    f.write(f"# Mercury compression benchmark\n\nReference: {dur:.0f}s screen recording normalised to 1920x1080@60. Scores are against the reference (higher is better).\n")
    f.write("`live` = happens during recording. `post` = extra wait after stop.\n\n")
    f.write("| Candidate | Stage | Size (MB) | Mbps | MB/hour | Encode (s) | VMAF | SSIM | PSNR |\n|---|---|---|---|---|---|---|---|---|\n")
    for r in rows:
        mbh = round(float(r["mbps"]) * 3600 / 8)
        f.write(f"| {r['description']} (`{r['name']}`) | {r['stage']} | {r['size_mb']} | {r['mbps']} | {mbh} | {r['encode_s']} | {r['vmaf']} | {r['ssim']} | {r['psnr']} |\n")
print(open(sys.argv[3]).read())
PY
echo "Saved: bench/out/results.md"

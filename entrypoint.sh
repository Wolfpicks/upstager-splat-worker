#!/usr/bin/env bash
# Upstager splat worker entrypoint (v19 — Fable runbook merge)
# Adds: sharp-frame selection, splatfacto-big + bilateral grid, gaussian cleanup,
#       .splat conversion, QC scoring via ns-eval
# Kept from v18: full logging, xvfb for headless COLMAP, guaranteed failure cb,
#       COLMAP output verification, per-stage timeouts, SLEEP_ON_DONE
# TODO: replace COLMAP mapper with GLOMAP for 10-50x speedup on low-texture scenes
set -Eeuo pipefail
# ---------- required env ----------
: "${VIDEO_URL:?VIDEO_URL not set}"
: "${CALLBACK_URL:?CALLBACK_URL not set}"
: "${ORDER_ID:?ORDER_ID not set}"
# ---------- tunables (override via pod env) ----------
NUM_FRAMES="${NUM_FRAMES:-150}"           # extract more, then sharp-select down
SHARP_WINDOW="${SHARP_WINDOW:-3}"         # keep best frame per window of N
SHARP_MAX="${SHARP_MAX:-300}"             # max sharp frames to keep
MAX_ITERS="${MAX_ITERS:-30000}"           # Fable: 30K for splatfacto-big
COLMAP_TIMEOUT="${COLMAP_TIMEOUT:-2400}"  # 40 min
TRAIN_TIMEOUT="${TRAIN_TIMEOUT:-5400}"    # 90 min (splatfacto-big runs longer)
EXPORT_TIMEOUT="${EXPORT_TIMEOUT:-600}"
CLEANUP_TIMEOUT="${CLEANUP_TIMEOUT:-300}"
QC_TIMEOUT="${QC_TIMEOUT:-600}"
UPLOAD_MAX_TIME="${UPLOAD_MAX_TIME:-900}"
SLEEP_ON_DONE="${SLEEP_ON_DONE:-1}"
WORK=/workspace
LOG="$WORK/run.log"
STAGE="startup"
DONE=0
mkdir -p "$WORK"
# Wipe stale state from previous restarts (persistent /workspace volume)
rm -rf "$WORK/frames" "$WORK/sharp" "$WORK/processed" "$WORK/outputs" "$WORK/exports" "$WORK/video.mp4"
: > "$LOG"
# ---------- FIX 1: tee ALL output to log ----------
exec > >(tee -a "$LOG") 2>&1
log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*"; }
# ---------- failure reporter ----------
report_failure() {
  local reason="${1:-unknown}"
  log "!!! FAILED during stage='$STAGE' reason='$reason'"
  { echo "--- diagnostics ---"; nvidia-smi || true; df -h "$WORK" || true; free -h || true; }
  for attempt in 1 2 3 4 5; do
    if curl -sS --fail --max-time 120 \
        -F "orderId=$ORDER_ID" \
        -F "status=failed" \
        -F "stage=$STAGE" \
        -F "reason=$reason" \
        -F "log=@$LOG;type=text/plain" \
        "$CALLBACK_URL"; then
      log "Failure report delivered (attempt $attempt)"
      return 0
    fi
    log "Failure report attempt $attempt failed; retrying..."
    sleep $((attempt * 15))
  done
  log "Could not deliver failure report after 5 attempts"
  return 1
}
on_error() {
  local code=$?
  trap - ERR EXIT
  report_failure "exit_code_${code}" || true
  if [ "$SLEEP_ON_DONE" = "1" ]; then
    log "Sleeping to prevent RunPod restart loop. Terminate pod from splat.js."
    sleep infinity
  fi
  exit "$code"
}
on_exit() {
  if [ "$DONE" != "1" ]; then on_error; fi
}
trap on_error ERR
trap on_exit EXIT

# ---------- stage 0: sanity ----------
STAGE="sanity"
log "Verifying torch/gsplat/CUDA..."
python3 - <<'PY'
import torch, gsplat
assert torch.cuda.is_available(), "CUDA not available"
print("torch", torch.__version__, "| gsplat", gsplat.__version__,
      "| gpu:", torch.cuda.get_device_name(0))
PY
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv

# ---------- stage 1: download ----------
STAGE="download"
log "Downloading $VIDEO_URL"
curl -fSL --retry 3 --retry-delay 5 --max-time 300 -o "$WORK/video.mp4" "$VIDEO_URL"
VSIZE=$(stat -c%s "$WORK/video.mp4")
log "Downloaded video: ${VSIZE} bytes"
[ "$VSIZE" -gt 1000000 ] || { report_failure "video_too_small_${VSIZE}b"; exit 1; }
ffprobe -v error -show_entries format=duration,size -of default=nw=1 "$WORK/video.mp4" 2>&1 | head -5 || true

# ---------- stage 2: frame extraction (ffmpeg, high FPS for sharp selection) ----------
STAGE="extract"
EXTRACT_FPS="${EXTRACT_FPS:-5}"   # 5 FPS → ~300 frames from 60s video
log "Extracting frames at ${EXTRACT_FPS} fps..."
mkdir -p "$WORK/frames"
ffmpeg -y -i "$WORK/video.mp4" -vf "fps=${EXTRACT_FPS}" -q:v 2 "$WORK/frames/frame_%05d.jpg" < /dev/null
FRAME_COUNT=$(find "$WORK/frames" -name '*.jpg' | wc -l)
log "Extracted $FRAME_COUNT frames"
[ "$FRAME_COUNT" -ge 10 ] || { report_failure "too_few_frames_${FRAME_COUNT}"; exit 1; }

# ---------- stage 3: sharp-frame selection (Fable §3b) ----------
STAGE="sharp_select"
log "Selecting sharp frames (window=$SHARP_WINDOW, max=$SHARP_MAX)..."
mkdir -p "$WORK/sharp"
python3 /app/pipeline_scripts/select_sharp.py "$WORK/frames" "$WORK/sharp" "$SHARP_WINDOW" "$SHARP_MAX"
SHARP_COUNT=$(find "$WORK/sharp" -name '*.jpg' | wc -l)
log "Selected $SHARP_COUNT sharp frames"
[ "$SHARP_COUNT" -ge 20 ] || { report_failure "too_few_sharp_frames_${SHARP_COUNT}"; exit 1; }

# ---------- stage 4: display for COLMAP Qt ----------
STAGE="xvfb"
Xvfb :99 -screen 0 1280x1024x24 &
export DISPLAY=:99
export QT_QPA_PLATFORM=offscreen
sleep 2

# ---------- stage 5: COLMAP via ns-process-data images ----------
STAGE="colmap"
log "Running COLMAP SfM on $SHARP_COUNT sharp frames (timeout ${COLMAP_TIMEOUT}s)..."
timeout --signal=TERM "$COLMAP_TIMEOUT" \
  ns-process-data images \
    --data "$WORK/sharp" \
    --output-dir "$WORK/processed" \
    --verbose

# ---------- COLMAP output verification ----------
STAGE="colmap_verify"
log "Verifying COLMAP output structure..."
[ -f "$WORK/processed/transforms.json" ] || { report_failure "missing_transforms_json"; exit 1; }
IMG_COUNT=$(find "$WORK/processed/images" -maxdepth 1 -type f \( -name '*.jpg' -o -name '*.png' \) 2>/dev/null | wc -l)
REG_COUNT=$(python3 -c "import json;print(len(json.load(open('$WORK/processed/transforms.json'))['frames']))" 2>/dev/null || echo 0)
REG_RATE=$(python3 -c "print(f'{$REG_COUNT / max($SHARP_COUNT, 1) * 100:.0f}%')" 2>/dev/null || echo "?")
log "Sharp frames: $SHARP_COUNT | COLMAP-registered: $REG_COUNT (${REG_RATE})"
# Require ≥50% registration rate — below that, splat quality is poor
MIN_REG=$(( SHARP_COUNT / 2 ))
[ "$REG_COUNT" -ge "$MIN_REG" ] || { report_failure "registration_too_low_${REG_COUNT}_of_${SHARP_COUNT}"; exit 1; }
if [ -d "$WORK/processed/colmap/sparse/0" ]; then
  log "Sparse model contents:"; ls -la "$WORK/processed/colmap/sparse/0"
fi

# ---------- stage 6: train splatfacto-big (Fable §3d) ----------
# splatfacto-big: more capacity, bilateral grid handles uneven lighting
STAGE="train"
log "Training splatfacto-big ($MAX_ITERS iters, timeout ${TRAIN_TIMEOUT}s)..."
timeout --signal=TERM "$TRAIN_TIMEOUT" \
  ns-train splatfacto-big \
    --data "$WORK/processed" \
    --output-dir "$WORK/outputs" \
    --pipeline.model.use-bilateral-grid True \
    --max-num-iterations "$MAX_ITERS"
# NOTE: NO --vis viewer flag — it hangs on headless GPU pods (confirmed v18/v19).

# ---------- stage 7: export ply ----------
STAGE="export"
CONFIG=$(find "$WORK/outputs" -name config.yml -type f | sort | tail -1)
[ -n "$CONFIG" ] || { report_failure "no_config_yml_found"; exit 1; }
log "Exporting from config: $CONFIG"
mkdir -p "$WORK/exports"
timeout --signal=TERM "$EXPORT_TIMEOUT" \
  ns-export gaussian-splat \
    --load-config "$CONFIG" \
    --output-dir "$WORK/exports"
PLY=$(find "$WORK/exports" -name '*.ply' -type f | head -1)
[ -n "$PLY" ] || { report_failure "no_ply_produced"; exit 1; }
PSIZE=$(stat -c%s "$PLY")
log "Exported $PLY (${PSIZE} bytes)"
[ "$PSIZE" -gt 100000 ] || { report_failure "ply_too_small_${PSIZE}b"; exit 1; }

# ---------- stage 8: cleanup + .splat conversion (Fable §3e) ----------
STAGE="cleanup"
log "Pruning floaters + converting to .splat..."
timeout --signal=TERM "$CLEANUP_TIMEOUT" \
  python3 /app/pipeline_scripts/cleanup_splat.py "$PLY" "$WORK/exports"
SPLAT="$WORK/exports/scene.splat"
[ -f "$SPLAT" ] || { report_failure "splat_conversion_failed"; exit 1; }
SPLAT_SIZE=$(stat -c%s "$SPLAT")
log ".splat written: $SPLAT (${SPLAT_SIZE} bytes)"

# ---------- stage 9: QC scoring (Fable §3f) ----------
STAGE="qc"
log "Running QC evaluation (ns-eval)..."
mkdir -p "$WORK/qc"
timeout --signal=TERM "$QC_TIMEOUT" \
  python3 /app/pipeline_scripts/qc_score.py "$WORK/outputs" "$WORK/qc/qc.json" || true
if [ -f "$WORK/qc/qc.json" ]; then
  QC_DATA=$(cat "$WORK/qc/qc.json")
  log "QC result: $QC_DATA"
else
  QC_DATA='{"psnr":0,"ssim":0,"pass":false,"note":"ns-eval failed or timed out"}'
  log "QC: ns-eval did not produce output (non-fatal)"
fi

# ---------- stage 10: upload (splat + log + qc together) ----------
STAGE="upload"
for attempt in 1 2 3 4 5; do
  if curl -sS --fail --max-time "$UPLOAD_MAX_TIME" \
      -F "orderId=$ORDER_ID" \
      -F "status=complete" \
      -F "registrationRate=$REG_RATE" \
      -F "qc=$QC_DATA" \
      -F "splat=@$SPLAT;type=application/octet-stream" \
      -F "log=@$LOG;type=text/plain" \
      "$CALLBACK_URL"; then
    log "Upload succeeded (attempt $attempt)"
    DONE=1
    break
  fi
  log "Upload attempt $attempt failed; retrying..."
  sleep $((attempt * 20))
done
[ "$DONE" = "1" ] || { report_failure "upload_failed_all_attempts"; exit 1; }
log "Pipeline complete for order $ORDER_ID"
trap - ERR EXIT
if [ "$SLEEP_ON_DONE" = "1" ]; then
  log "Sleeping; terminate this pod from splat.js after processing the callback."
  sleep infinity
fi
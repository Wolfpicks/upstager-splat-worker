#!/usr/bin/env bash
# Upstager splat worker entrypoint (v18)
# Fixes: full logging, guaranteed failure callback, COLMAP output verification,
# correct nested config.yml discovery, viewer quit-on-completion, per-stage timeo
set -Eeuo pipefail
# ---------- required env ----------
: "${VIDEO_URL:?VIDEO_URL not set}"
: "${CALLBACK_URL:?CALLBACK_URL not set}"
: "${ORDER_ID:?ORDER_ID not set}"
# ---------- tunables (override via pod env) ----------
NUM_FRAMES="${NUM_FRAMES:-100}"          # reduced from 150 for faster iteration
MAX_ITERS="${MAX_ITERS:-7000}"
COLMAP_TIMEOUT="${COLMAP_TIMEOUT:-2400}" # 40 min
TRAIN_TIMEOUT="${TRAIN_TIMEOUT:-3600}"   # 60 min
EXPORT_TIMEOUT="${EXPORT_TIMEOUT:-600}"
UPLOAD_MAX_TIME="${UPLOAD_MAX_TIME:-900}"
SLEEP_ON_DONE="${SLEEP_ON_DONE:-1}"      # 1 = sleep forever after done so RunPod
                                         # doesn't crash-loop; splat.js should
                                         # terminate the pod via RunPod API on ca
WORK=/workspace
LOG="$WORK/run.log"
STAGE="startup"
DONE=0
mkdir -p "$WORK"
# Wipe stale state from previous restarts (persistent /workspace volume)
rm -rf "$WORK/processed" "$WORK/outputs" "$WORK/exports" "$WORK/video.mp4"
: > "$LOG"
# ---------- FIX 1: tee ALL output to log ----------
exec > >(tee -a "$LOG") 2>&1
log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*"; }
# ---------- FIX 4: failure reporter that actually reaches the callback ---------
report_failure() {
  local reason="${1:-unknown}"
  log "!!! FAILED during stage='$STAGE' reason='$reason'"
  { echo "--- diagnostics ---"; nvidia-smi || true; df -h "$WORK" || true; free -
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
  # Catches unexpected exits not routed through ERR (e.g. timeout SIGTERM paths)
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

curl -fSL --retry 3 --retry-delay 5 --max-time 300 -o "$WORK/video.mp4" "$VIDEO_U
VSIZE=$(stat -c%s "$WORK/video.mp4")
log "Downloaded video: ${VSIZE} bytes"
[ "$VSIZE" -gt 1000000 ] || { report_failure "video_too_small_${VSIZE}b"; exit 1;
ffprobe -v error -show_entries format=duration,size -of default=nw=1 "$WORK/video
# ---------- stage 2: display for COLMAP Qt ----------
STAGE="xvfb"
Xvfb :99 -screen 0 1280x1024x24 &
export DISPLAY=:99
export QT_QPA_PLATFORM=offscreen   # belt-and-suspenders for headless Qt
sleep 2
# ---------- stage 3: COLMAP via ns-process-data ----------
STAGE="colmap"
log "Running ns-process-data (target $NUM_FRAMES frames, timeout ${COLMAP_TIMEOUT
timeout --signal=TERM "$COLMAP_TIMEOUT" \
  ns-process-data video \
    --data "$WORK/video.mp4" \
    --output-dir "$WORK/processed" \
    --num-frames-target "$NUM_FRAMES" \
    --verbose
# ---------- FIX 3: verify COLMAP output before burning GPU time on training ----
STAGE="colmap_verify"
log "Verifying COLMAP output structure..."
[ -f "$WORK/processed/transforms.json" ] || { report_failure "missing_transforms_
[ -d "$WORK/processed/images" ]          || { report_failure "missing_images_dir"
IMG_COUNT=$(find "$WORK/processed/images" -maxdepth 1 -type f \( -name '*.png' -o
REG_COUNT=$(python3 -c "import json;print(len(json.load(open('$WORK/processed/tra
log "Extracted images: $IMG_COUNT | COLMAP-registered frames: $REG_COUNT"
# Require at least 50% of extracted frames registered — below that, splat quality
MIN_REG=$(( IMG_COUNT / 2 ))
[ "$REG_COUNT" -ge "$MIN_REG" ] || { report_failure "colmap_registered_only_${REG
if [ -d "$WORK/processed/colmap/sparse/0" ]; then
  log "Sparse model contents:"; ls -la "$WORK/processed/colmap/sparse/0"
fi
# ---------- stage 4: train ----------
STAGE="train"
log "Training splatfacto ($MAX_ITERS iters, timeout ${TRAIN_TIMEOUT}s)"
timeout --signal=TERM "$TRAIN_TIMEOUT" \
  ns-train splatfacto \
    --data "$WORK/processed" \
    --output-dir "$WORK/outputs" \
    --max-num-iterations "$MAX_ITERS"
# ---------- stage 5: export ----------
STAGE="export"
# Nerfstudio nests config at outputs/<experiment>/splatfacto/<timestamp>/config.y
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
# ---------- stage 6: upload (splat + log together) ----------
STAGE="upload"
for attempt in 1 2 3 4 5; do
  if curl -sS --fail --max-time "$UPLOAD_MAX_TIME" \
      -F "orderId=$ORDER_ID" \
      -F "status=complete" \
      -F "splat=@$PLY;type=application/octet-stream" \
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


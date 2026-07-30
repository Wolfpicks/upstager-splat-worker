#!/bin/bash
set -euo pipefail

report_failure() {
  echo "FAILED at stage: $1 — $2"
  curl -s -X POST \
    -F "orderId=${ORDER_ID:-unknown}" \
    -F "status=failed" \
    -F "stage=$1" \
    -F "error=$2" \
    "${CALLBACK_URL:-}" >/dev/null 2>&1 || true
  exit 1
}

echo "=== Upstager GPU Worker (prebuilt v1) ==="
echo "torch=$(python3 -c 'import torch;print(torch.__version__)') gsplat=$(python3 -c 'import gsplat;print(gsplat.__version__)') CUDA=$(python3 -c 'import torch;print(torch.cuda.is_available())')"

# Download video
echo "[1/3] Downloading video..."
mkdir -p /workspace
curl -fsSL --connect-timeout 60 --max-time 300 --retry 3 --retry-delay 10 \
    -o /workspace/video.mp4 "$VIDEO_URL" \
    || report_failure "download" "video download failed"
echo "[1/3] Video: $(ls -lh /workspace/video.mp4 | awk '{print $5}')"

# Start Xvfb for COLMAP
export DISPLAY=:99
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null || true
Xvfb :99 -screen 0 1024x768x24 -ac +extension GLX +render &>/dev/null &
sleep 2

# COLMAP
echo "[2/3] COLMAP..."
ns-process-data video \
    --data /workspace/video.mp4 \
    --output-dir /workspace/processed \
    --num-frames-target 150 \
    || report_failure "colmap" "COLMAP processing failed"

# Train + export
echo "[2/3] Training gsplat (7000 iters)..."
ns-train splatfacto \
    --viewer.quit-on-train-completion True \
    --data /workspace/processed \
    --output-dir /workspace/outputs \
    --max-num-iterations 7000 \
    --pipeline.model.cull-alpha-thresh 0.005 \
    --pipeline.model.densify-grad-thresh 0.0002 \
    || report_failure "train" "gsplat training failed"

echo "[2/3] Exporting .ply..."
CONFIG=$(ls /workspace/outputs/*/config.yml 2>/dev/null | head -1)
[ -z "$CONFIG" ] && report_failure "export" "no config.yml found"
ns-export gaussian-splat --load-config "$CONFIG" --output-dir /workspace/exports/ \
    || report_failure "export" ".ply export failed"

PLY=$(find /workspace/exports -name "*.ply" 2>/dev/null | head -1)
[ -z "$PLY" ] && report_failure "export" "no .ply produced"
echo "[2/3] Splat: $(ls -lh "$PLY" | awk '{print $5}')"

# Upload
echo "[3/3] Uploading to $CALLBACK_URL..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 60 --max-time 300 --retry 3 --retry-delay 10 \
    -X POST \
    -F "splat=@$PLY" \
    -F "orderId=$ORDER_ID" \
    "$CALLBACK_URL")

[ "$HTTP_CODE" != "200" ] && report_failure "upload" "callback returned HTTP $HTTP_CODE"

echo "=== DONE ==="
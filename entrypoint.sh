#!/bin/bash
# RunPod GPU worker — video → 3D Gaussian Splat (.ply)
set -euo pipefail

# Activate conda environment (required for ns-* tools)
source /opt/conda/etc/profile.d/conda.sh 2>/dev/null || true
conda activate nerfstudio 2>/dev/null || conda activate base 2>/dev/null || true

echo "[splat-worker] Starting — order $ORDER_ID"
echo "[splat-worker] Downloading video from $VIDEO_URL"

curl -fsSL -o /workspace/video.mp4 "$VIDEO_URL"
echo "[splat-worker] Video downloaded: $(ls -lh /workspace/video.mp4 | awk '{print $5}')"

echo "[splat-worker] Processing video with nerfstudio..."
ns-process-data video \
  --data /workspace/video.mp4 \
  --output-dir /workspace/processed/ \
  --num-frames-target 150

echo "[splat-worker] Training gsplat..."
ns-train splatfacto \
  --data /workspace/processed/ \
  --output-dir /workspace/outputs/ \
  --max-num-iterations 7000 \
  --pipeline.model.cull-alpha-thresh 0.005 \
  --pipeline.model.densify-grad-thresh 0.0002

echo "[splat-worker] Exporting .ply..."
CONFIG=$(ls /workspace/outputs/*/config.yml 2>/dev/null | head -1)
if [ -z "$CONFIG" ]; then
  echo "[splat-worker] ERROR: No config.yml found"
  exit 1
fi
ns-export gaussian-splat --load-config "$CONFIG" --output-dir /workspace/exports/

PLY=$(find /workspace/exports -name "*.ply" 2>/dev/null | head -1)
if [ -z "$PLY" ]; then
  echo "[splat-worker] ERROR: No .ply produced"
  exit 1
fi
echo "[splat-worker] Splat ready: $(ls -lh "$PLY" | awk '{print $5}')"

echo "[splat-worker] Uploading splat to $CALLBACK_URL"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST \
  -F "splat=@$PLY" \
  -F "orderId=$ORDER_ID" \
  "$CALLBACK_URL")

if [ "$HTTP_CODE" != "200" ]; then
  echo "[splat-worker] ERROR: Upload failed (HTTP $HTTP_CODE)"
  exit 1
fi
echo "[splat-worker] Done — order $ORDER_ID completed"

#!/bin/bash
# RunPod GPU worker — video → 3D Gaussian Splat (.ply)
set -euo pipefail

echo "[splat-worker] Starting — order $ORDER_ID"

# Download with retries (RunPod may not reach some URLs first try)
echo "[splat-worker] Downloading video (retries enabled)..."
for i in $(seq 1 5); do
  if curl -fsSL -o /workspace/video.mp4 "$VIDEO_URL" --connect-timeout 30 --max-time 120; then
    echo "[splat-worker] Downloaded: $(ls -lh /workspace/video.mp4 | awk '{print $5}')"
    break
  fi
  echo "[splat-worker] Download attempt $i failed, retrying in 10s..."
  sleep 10
done

if [ ! -f /workspace/video.mp4 ] || [ ! -s /workspace/video.mp4 ]; then
  echo "[splat-worker] FATAL: Could not download video after 5 attempts"
  exit 1
fi

# Step 1: COLMAP
echo "[splat-worker] Running COLMAP via nerfstudio..."
ns-process-data video \
  --data /workspace/video.mp4 \
  --output-dir /workspace/processed/ \
  --num-frames-target 150

# Step 2: Train
echo "[splat-worker] Training gsplat (7000 iterations)..."
ns-train splatfacto \
  --data /workspace/processed/ \
  --output-dir /workspace/outputs/ \
  --max-num-iterations 7000 \
  --pipeline.model.cull-alpha-thresh 0.005 \
  --pipeline.model.densify-grad-thresh 0.0002

# Step 3: Export
echo "[splat-worker] Exporting .ply..."
CONFIG=$(ls /workspace/outputs/*/config.yml 2>/dev/null | head -1)
[ -z "$CONFIG" ] && { echo "FATAL: no config.yml"; exit 1; }
ns-export gaussian-splat --load-config "$CONFIG" --output-dir /workspace/exports/

# Step 4: Find .ply
PLY=$(find /workspace/exports -name "*.ply" 2>/dev/null | head -1)
[ -z "$PLY" ] && { echo "FATAL: no .ply produced"; exit 1; }
echo "[splat-worker] Splat: $(ls -lh "$PLY" | awk '{print $5}')"

# Step 5: Upload back (with retries)
echo "[splat-worker] Uploading to $CALLBACK_URL"
for i in $(seq 1 5); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 30 --max-time 120 \
    -X POST -F "splat=@$PLY" -F "orderId=$ORDER_ID" "$CALLBACK_URL")
  if [ "$CODE" = "200" ]; then
    echo "[splat-worker] Upload OK"
    exit 0
  fi
  echo "[splat-worker] Upload attempt $i failed (HTTP $CODE), retrying..."
  sleep 10
done

echo "[splat-worker] FATAL: upload failed after 5 attempts"
exit 1

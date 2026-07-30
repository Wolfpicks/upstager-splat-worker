#!/bin/bash
set -euo pipefail

# COLMAP needs a virtual display — use offscreen Qt rendering
export QT_QPA_PLATFORM=offscreen

# Source conda environment (runpod/pytorch uses conda)
source /opt/conda/bin/activate 2>/dev/null || true
export PATH="/opt/conda/bin:/usr/local/bin:$PATH"

echo "[splat] Starting order=$ORDER_ID"
echo "[splat] ns-process-data: $(which ns-process-data 2>&1)"
echo "[splat] ns-train: $(which ns-train 2>&1)"

echo "[splat] Downloading video..."
curl -fsSL --connect-timeout 60 --max-time 300 --retry 5 --retry-delay 10 -o /workspace/video.mp4 "$VIDEO_URL" || {
    echo "[splat] FATAL: download failed"
    exit 1
}
echo "[splat] Video: $(ls -lh /workspace/video.mp4 | awk '{print $5}')"

echo "[splat] COLMAP..."
ns-process-data video --data /workspace/video.mp4 --output-dir /workspace/processed/ --num-frames-target 150

echo "[splat] Training gsplat (7000 iters)..."
ns-train splatfacto --data /workspace/processed/ --output-dir /workspace/outputs/ --max-num-iterations 7000 --pipeline.model.cull-alpha-thresh 0.005 --pipeline.model.densify-grad-thresh 0.0002

echo "[splat] Exporting .ply..."
CONFIG=$(ls /workspace/outputs/*/config.yml 2>/dev/null | head -1)
[ -z "$CONFIG" ] && { echo "[splat] FATAL: no config.yml"; exit 1; }
ns-export gaussian-splat --load-config "$CONFIG" --output-dir /workspace/exports/

PLY=$(find /workspace/exports -name "*.ply" | head -1)
[ -z "$PLY" ] && { echo "[splat] FATAL: no .ply"; exit 1; }
echo "[splat] Splat: $(ls -lh "$PLY" | awk '{print $5}')"

echo "[splat] Uploading..."
curl -fsSL --connect-timeout 60 --max-time 300 --retry 5 --retry-delay 10 \
  -X POST -F "splat=@$PLY" -F "orderId=$ORDER_ID" "$CALLBACK_URL" || {
    echo "[splat] FATAL: upload failed"
    exit 1
}
echo "[splat] DONE"

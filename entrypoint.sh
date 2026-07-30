#!/bin/bash
export PATH="/opt/conda/bin:$PATH"
set -euo pipefail

echo "[splat] Starting order=$ORDER_ID"
echo "[splat] Downloading video..."
curl -fsSL --connect-timeout 60 --max-time 300 --retry 3 -o /workspace/video.mp4 "$VIDEO_URL"
echo "[splat] Video: $(ls -lh /workspace/video.mp4 | awk '{print $5}')"

echo "[splat] COLMAP..."
ns-process-data video --data /workspace/video.mp4 --output-dir /workspace/processed/ --num-frames-target 150

echo "[splat] Training (7000 iters)..."
ns-train splatfacto --data /workspace/processed/ --output-dir /workspace/outputs/ --max-num-iterations 7000 --pipeline.model.cull-alpha-thresh 0.005 --pipeline.model.densify-grad-thresh 0.0002

echo "[splat] Exporting..."
CONFIG=$(ls /workspace/outputs/*/config.yml 2>/dev/null | head -1)
ns-export gaussian-splat --load-config "$CONFIG" --output-dir /workspace/exports/

PLY=$(find /workspace/exports -name "*.ply" | head -1)
echo "[splat] Splat: $(ls -lh "$PLY" | awk '{print $5}')"

echo "[splat] Uploading..."
curl -fsSL --connect-timeout 60 --max-time 300 --retry 3 -X POST -F "splat=@$PLY" -F "orderId=$ORDER_ID" "$CALLBACK_URL"
echo "[splat] DONE"

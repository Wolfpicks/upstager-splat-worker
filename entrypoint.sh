#!/bin/bash
set -e

echo "=== GPU Worker (pre-built) ==="
nvidia-smi | head -12

echo "=== Step 1: Download video ==="
mkdir -p /workspace
curl -fsSL -o /workspace/video.mp4 "$VIDEO_URL"
ls -lh /workspace/video.mp4
echo "DONE"

echo "=== Step 2: COLMAP ==="
mkdir -p /workspace/processed /workspace/outputs /workspace/exports
ns-process-data video --data /workspace/video.mp4 --output-dir /workspace/processed --num-frames-target 150
echo "DONE"

echo "=== Step 3: Train gsplat ==="
ns-train splatfacto --data /workspace/processed --output-dir /workspace/outputs --max-num-iterations 7000
echo "DONE"

echo "=== Step 4: Export .ply ==="
CONFIG=$(ls /workspace/outputs/*/config.yml | head -1)
ns-export gaussian-splat --load-config "$CONFIG" --output-dir /workspace/exports/
PLY=$(find /workspace/exports -name "*.ply" | head -1)
ls -lh "$PLY"
echo "DONE"

echo "=== Step 5: Upload ==="
curl -v -X POST -F "splat=@$PLY" -F "orderId=$ORDER_ID" "$CALLBACK_URL"
echo "DONE"

sleep 10
echo "=== ALL DONE ==="
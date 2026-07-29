#!/bin/bash
set -euo pipefail

echo "=== Bootstrap GPU Worker ==="
echo "[1/5] Installing system packages..."
apt-get update -qq && apt-get install -y -qq --no-install-recommends \
    ffmpeg python3-pip python3-dev git build-essential \
    libgl1-mesa-glx libglib2.0-0 colmap \
    && rm -rf /var/lib/apt/lists/*

echo "[2/5] Installing PyTorch (CUDA 12.1)..."
pip3 install --no-cache-dir -q torch torchvision --index-url https://download.pytorch.org/whl/cu121

echo "[3/5] Installing nerfstudio + gsplat..."
pip3 install --no-cache-dir -q nerfstudio gsplat

echo "[4/5] Downloading video..."
curl -fsSL -o /workspace/video.mp4 "$VIDEO_URL"
echo "       Downloaded: $(ls -lh /workspace/video.mp4 | awk '{print $5}')"

echo "[5/5] Processing — COLMAP → gsplat → .ply"
ns-process-data video \
    --data /workspace/video.mp4 \
    --output-dir /workspace/processed \
    --num-frames-target 150

ns-train splatfacto \
    --data /workspace/processed \
    --output-dir /workspace/outputs \
    --max-num-iterations 7000 \
    --pipeline.model.cull-alpha-thresh 0.005 \
    --pipeline.model.densify-grad-thresh 0.0002

CONFIG=$(ls /workspace/outputs/*/config.yml 2>/dev/null | head -1)
ns-export gaussian-splat --load-config "$CONFIG" --output-dir /workspace/exports/

PLY=$(find /workspace/exports -name "*.ply" 2>/dev/null | head -1)
echo "Splat ready: $(ls -lh "$PLY" | awk '{print $5}')"

echo "Uploading to $CALLBACK_URL..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST -F "splat=@$PLY" -F "orderId=$ORDER_ID" "$CALLBACK_URL")

echo "=== Done (HTTP $HTTP_CODE) ==="

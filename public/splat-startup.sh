#!/bin/bash
set -euo pipefail

echo "=== Micro GPU Worker ==="
echo "[1/4] Installing CUDA + system deps (this takes ~3 min)..."
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    wget ffmpeg python3-pip python3-dev git build-essential \
    libgl1-mesa-glx libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Install CUDA toolkit
wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb
apt-get update -qq
apt-get install -y -qq --no-install-recommends cuda-toolkit-12-1

echo "[2/4] Installing PyTorch + nerfstudio..."
pip3 install --no-cache-dir -q torch torchvision --index-url https://download.pytorch.org/whl/cu121
pip3 install --no-cache-dir -q nerfstudio gsplat

echo "[3/4] Downloading video..."
curl -fsSL -o /workspace/video.mp4 "$VIDEO_URL"
echo "       Downloaded: $(ls -lh /workspace/video.mp4 | awk '{print $5}')"

echo "[4/4] Processing — COLMAP → gsplat → .ply"
mkdir -p /workspace

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
curl -s -X POST -F "splat=@$PLY" -F "orderId=$ORDER_ID" "$CALLBACK_URL"

echo "=== Done ==="

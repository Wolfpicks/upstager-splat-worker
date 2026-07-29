#!/bin/bash
# Bootstrap script for ubuntu:22.04 GPU pod — processes video into 3D splat

echo "=== STEP 1: System deps ==="
apt-get update -qq 2>&1 | tail -1
apt-get install -y -qq --no-install-recommends wget ffmpeg git build-essential libgl1-mesa-glx libglib2.0-0 2>&1 | tail -1
echo "DONE: system deps"

echo "=== STEP 2: Python ==="
apt-get install -y -qq --no-install-recommends python3-pip python3-dev 2>&1 | tail -1
echo "DONE: python"

echo "=== STEP 3: CUDA 12.1 ==="
wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb 2>&1 | tail -1
apt-get update -qq 2>&1 | tail -1
apt-get install -y -qq --no-install-recommends cuda-toolkit-12-1 2>&1 | tail -1
echo "DONE: CUDA"

echo "=== STEP 4: PyTorch + nerfstudio ==="
pip3 install --no-cache-dir -q torch torchvision --index-url https://download.pytorch.org/whl/cu121 2>&1 | tail -3
pip3 install --no-cache-dir -q nerfstudio gsplat 2>&1 | tail -3
echo "DONE: ML stack"

echo "=== STEP 5: Download video ==="
curl -fsSL -o /workspace/video.mp4 "$VIDEO_URL"
ls -lh /workspace/video.mp4
echo "DONE: video"

echo "=== STEP 6: Process splat ==="
mkdir -p /workspace/processed /workspace/outputs /workspace/exports
ns-process-data video --data /workspace/video.mp4 --output-dir /workspace/processed --num-frames-target 150 2>&1 | tail -5
echo "DONE: COLMAP"

echo "=== STEP 7: Train gsplat ==="
ns-train splatfacto --data /workspace/processed --output-dir /workspace/outputs --max-num-iterations 7000 2>&1 | tail -10
echo "DONE: training"

echo "=== STEP 8: Export .ply ==="
CONFIG=$(ls /workspace/outputs/*/config.yml 2>/dev/null | head -1)
ns-export gaussian-splat --load-config "$CONFIG" --output-dir /workspace/exports/ 2>&1 | tail -3
PLY=$(find /workspace/exports -name "*.ply" | head -1)
ls -lh "$PLY"
echo "DONE: export"

echo "=== STEP 9: Upload ==="
curl -s -X POST -F "splat=@$PLY" -F "orderId=$ORDER_ID" "$CALLBACK_URL"
echo "DONE: uploaded"

echo "=== ALL DONE ==="
sleep 30
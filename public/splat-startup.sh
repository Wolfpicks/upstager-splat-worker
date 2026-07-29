#!/bin/bash
# Minimal bootstrap — skip CUDA toolkit, PyTorch pip bundles its own

echo "=== STEP 1: apt-get ==="
apt-get update -qq 2>&1 | tail -1
apt-get install -y -qq --no-install-recommends wget ffmpeg python3-pip git build-essential libgl1-mesa-glx libglib2.0-0 2>&1 | tail -1
echo "DONE: system deps"

echo "=== STEP 2: PyTorch + nerfstudio (includes CUDA) ==="
pip3 install --no-cache-dir torch torchvision --index-url https://download.pytorch.org/whl/cu121 2>&1 | tail -3
echo "DONE: torch"

pip3 install --no-cache-dir nerfstudio gsplat 2>&1 | tail -3
echo "DONE: nerfstudio"

echo "=== STEP 3: Download video ==="
mkdir -p /workspace
curl -fsSL -o /workspace/video.mp4 "$VIDEO_URL"
ls -lh /workspace/video.mp4
echo "DONE: video"

echo "=== STEP 4: COLMAP ==="
mkdir -p /workspace/processed /workspace/outputs /workspace/exports
ns-process-data video --data /workspace/video.mp4 --output-dir /workspace/processed --num-frames-target 150 2>&1 | tail -5
echo "DONE: COLMAP"

echo "=== STEP 5: Train gsplat (GPU!) ==="
ns-train splatfacto --data /workspace/processed --output-dir /workspace/outputs --max-num-iterations 7000 2>&1 | tail -10
echo "DONE: training"

echo "=== STEP 6: Export + Upload ==="
CONFIG=$(ls /workspace/outputs/*/config.yml 2>/dev/null | head -1)
ns-export gaussian-splat --load-config "$CONFIG" --output-dir /workspace/exports/ 2>&1 | tail -3
PLY=$(find /workspace/exports -name "*.ply" | head -1)
ls -lh "$PLY"
echo "DONE: export"

echo "=== STEP 7: Upload .ply ==="
curl -v -X POST -F "splat=@$PLY" -F "orderId=$ORDER_ID" "$CALLBACK_URL" 2>&1
echo "DONE: upload"

echo "=== ALL DONE ==="
sleep 30
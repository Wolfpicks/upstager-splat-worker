#!/bin/bash
# Pipeline to run on pytorch/pytorch image (PyTorch+CUDA pre-installed)

echo "=== Installing nerfstudio ==="
pip install -q nerfstudio gsplat 2>&1 | tail -3
echo "DONE: pip install"

echo "=== Testing GPU ==="
python3 -c "import torch; print(f'CUDA: {torch.cuda.is_available()}, Devices: {torch.cuda.device_count()}')" 2>&1
echo "DONE: GPU test"

echo "=== Downloading video ==="
mkdir -p /workspace
curl -fsSL -o /workspace/video.mp4 "$VIDEO_URL"
ls -lh /workspace/video.mp4
echo "DONE: download"

echo "=== COLMAP ==="
mkdir -p /workspace/processed /workspace/outputs /workspace/exports
ns-process-data video --data /workspace/video.mp4 --output-dir /workspace/processed --num-frames-target 150 2>&1 | tail -5
echo "DONE: colmap"

echo "=== Training (GPU!) ==="
ns-train splatfacto --data /workspace/processed --output-dir /workspace/outputs --max-num-iterations 7000 2>&1 | tail -10
echo "DONE: training"

echo "=== Exporting .ply ==="
CONFIG=$(ls /workspace/outputs/*/config.yml 2>/dev/null | head -1)
ns-export gaussian-splat --load-config "$CONFIG" --output-dir /workspace/exports/ 2>&1 | tail -3
PLY=$(find /workspace/exports -name "*.ply" 2>/dev/null | head -1)
ls -lh "$PLY"
echo "DONE: export"

echo "=== Uploading ==="
curl -v -X POST -F "splat=@$PLY" -F "orderId=kitchen" "$CALLBACK_URL" 2>&1
echo "DONE: upload"

sleep 10
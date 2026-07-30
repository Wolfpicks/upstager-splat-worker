#!/bin/bash
set -euo pipefail

# ── failure reporter: POSTs status to callback so server knows why it died ──
report_failure() {
  local stage="$1"
  local msg="${2:-unknown}"
  echo "FAILED at stage: $stage"
  echo "Reason: $msg"
  curl -s -X POST \
    -F "orderId=${ORDER_ID:-unknown}" \
    -F "status=failed" \
    -F "stage=${stage}" \
    -F "error=${msg}" \
    "${CALLBACK_URL:-}" >/dev/null 2>&1 || true
  exit 1
}

echo "=== Micro GPU Worker v17 ==="

# ── [1/4] System deps ──
echo "[1/4] Installing system dependencies (this takes ~3 min)..."
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    wget ffmpeg curl \
    python3-pip python3-dev python3-venv \
    git build-essential ninja-build cmake \
    colmap xvfb \
    libgl1 libgl1-mesa-glx libglib2.0-0 \
    libsm6 libxext6 libxrender-dev \
    mesa-utils x11-utils \
    && rm -rf /var/lib/apt/lists/* \
    || report_failure "apt" "apt-get install failed"

# ── Install CUDA toolkit nvcc (gsplat JIT-compiles CUDA kernels) ──
if ! command -v nvcc &>/dev/null; then
  echo "[1/4] Installing CUDA toolkit 12.1 (nvcc missing)..."
  wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
  dpkg -i cuda-keyring_1.1-1_all.deb
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends cuda-toolkit-12-1 \
    || report_failure "cuda-toolkit" "CUDA toolkit install failed"
  rm -f cuda-keyring_1.1-1_all.deb
fi
echo "[1/4] nvcc: $(which nvcc 2>/dev/null || echo 'N/A')"

# ── [2/4] Python deps — PINNED versions ──
echo "[2/4] Installing PyTorch + nerfstudio + gsplat..."
pip3 install --no-cache-dir -q \
    torch==2.3.1 torchvision==0.18.1 \
    --index-url https://download.pytorch.org/whl/cu121 \
    || report_failure "pip-torch" "torch install failed"

pip3 install --no-cache-dir -q \
    nerfstudio==1.1.5 gsplat==1.4.0 \
    torch==2.3.1 torchvision==0.18.1 \
    || report_failure "pip-nerfstudio" "nerfstudio/gsplat install failed"

# ── Sanity check ──
echo "[check] verifying installation..."
python3 -c "
import torch, gsplat
msg = f'torch={torch.__version__} gsplat={gsplat.__version__} cuda_ok={torch.cuda.is_available()}'
assert torch.__version__.startswith('2.3.1'), f'wrong torch: {torch.__version__}'
assert torch.cuda.is_available(), 'CUDA not available'
print(msg)
" || report_failure "check" "Python sanity check failed"

# ── [3/4] Download video ──
echo "[3/4] Downloading video..."
curl -fsSL --connect-timeout 60 --max-time 300 --retry 3 --retry-delay 10 \
    -o /workspace/video.mp4 "$VIDEO_URL" \
    || report_failure "download" "video download failed"
echo "[3/4] Video: $(ls -lh /workspace/video.mp4 | awk '{print $5}')"

# ── Start Xvfb for COLMAP Qt/OpenGL ──
export DISPLAY=:99
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null || true
Xvfb :99 -screen 0 1024x768x24 -ac +extension GLX +render &>/dev/null &
sleep 2

# ── [4/4] COLMAP → gsplat train → export .ply ──
echo "[4/4] Processing — COLMAP..."
mkdir -p /workspace

ns-process-data video \
    --data /workspace/video.mp4 \
    --output-dir /workspace/processed \
    --num-frames-target 150 \
    || report_failure "colmap" "COLMAP processing failed"

echo "[4/4] Training gsplat (7000 iters)..."
ns-train splatfacto \
    --viewer.quit-on-train-completion True \
    --data /workspace/processed \
    --output-dir /workspace/outputs \
    --max-num-iterations 7000 \
    --pipeline.model.cull-alpha-thresh 0.005 \
    --pipeline.model.densify-grad-thresh 0.0002 \
    || report_failure "train" "gsplat training failed"

echo "[4/4] Exporting .ply..."
CONFIG=$(ls /workspace/outputs/*/config.yml 2>/dev/null | head -1)
[ -z "$CONFIG" ] && report_failure "export" "no config.yml found in outputs"
ns-export gaussian-splat --load-config "$CONFIG" --output-dir /workspace/exports/ \
    || report_failure "export" ".ply export failed"

PLY=$(find /workspace/exports -name "*.ply" 2>/dev/null | head -1)
[ -z "$PLY" ] && report_failure "export" "no .ply file produced"
echo "[4/4] Splat ready: $(ls -lh "$PLY" | awk '{print $5}')"

# ── Upload ──
echo "[upload] Posting to $CALLBACK_URL..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 60 --max-time 300 --retry 3 --retry-delay 10 \
    -X POST \
    -F "splat=@$PLY" \
    -F "orderId=$ORDER_ID" \
    "$CALLBACK_URL")

if [ "$HTTP_CODE" != "200" ]; then
  report_failure "upload" "callback returned HTTP $HTTP_CODE"
fi

echo "=== DONE ==="
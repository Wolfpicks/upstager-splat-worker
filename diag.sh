#!/usr/bin/env bash
# Minimal diagnostic - verifies env, download, COLMAP only
set -e
CALLBACK="${CALLBACK_URL:-http://localhost:3000/api/debug-callback}"
ORDER="${ORDER_ID:-diag}"
LOG="/workspace/diag.log"
mkdir -p /workspace
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "=== DIAGNOSTIC $(date) ==="
echo "Env: CALLBACK=$CALLBACK ORDER=$ORDER"

echo "--- CUDA ---"
python3 -c "import torch; print('torch', torch.__version__, torch.cuda.get_device_name(0))" || echo "CUDA FAIL"
python3 -c "import gsplat; print('gsplat', gsplat.__version__)" || echo "GSPLAT FAIL"

echo "--- Download video ---"
curl -f -o /workspace/v.mp4 "https://walking-flight-score-advertise.trycloudflare.com/uploads/walkthrough.mp4" || echo "DOWNLOAD FAIL"
echo "Size: $(stat -c%s /workspace/v.mp4 2>/dev/null || echo 0)"

echo "--- Xvfb ---"
Xvfb :99 -screen 0 1280x1024x24 &
sleep 1
export DISPLAY=:99
export QT_QPA_PLATFORM=offscreen

echo "--- ns-process-data (3 frames, 60s timeout) ---"
timeout 60 ns-process-data video --data /workspace/v.mp4 --output-dir /workspace/out --num-frames-target 3 --verbose 2>&1
EC=$?
echo "Exit: $EC"
ls -la /workspace/out/ 2>&1 || echo "no out dir"
[ -f /workspace/out/transforms.json ] && echo "transforms.json EXISTS" || echo "NO transforms.json"

echo "=== DIAG COMPLETE ==="
curl -s -F "orderId=$ORDER" -F status=done -F stage=diag -F "log=@$LOG;type=text/plain" "$CALLBACK" 2>&1 || echo "CALLBACK FAIL"
echo "REPORTED"
sleep 5

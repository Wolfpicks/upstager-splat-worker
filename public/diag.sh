#!/bin/bash
# Diagnostic script — tests each step and reports via callback

REPORT=""

report() { REPORT="${REPORT}$1\n"; echo "$1"; }

report "=== DIAGNOSTIC START ==="

# 1. System
report "--- apt-get update ---"
apt-get update -qq 2>&1 >> /tmp/diag.log; report "apt-update: $?"

report "--- apt-get install ---"
apt-get install -y -qq --no-install-recommends python3-pip wget 2>&1 >> /tmp/diag.log; report "apt-install: $?"

report "--- nvidia-smi ---"
nvidia-smi 2>&1 >> /tmp/diag.log; report "nvidia-smi: $?"

# 2. PyTorch
report "--- pip install torch ---"
pip3 install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cu121 2>&1 >> /tmp/diag.log; report "pip-torch: $?"

report "--- torch.cuda test ---"
python3 -c "import torch; print('CUDA:', torch.cuda.is_available(), 'Devices:', torch.cuda.device_count())" 2>&1 >> /tmp/diag.log
report "torch-ok: $?"

# 3. Nerfstudio  
report "--- pip install nerfstudio ---"
pip3 install --no-cache-dir nerfstudio gsplat 2>&1 >> /tmp/diag.log; report "pip-ns: $?"

report "--- ns-train check ---"
which ns-train 2>&1 >> /tmp/diag.log; report "ns-train-path: $?"

# Upload diagnostic report
report "=== UPLOADING ==="
echo -e "$REPORT" > /tmp/report.txt
cat /tmp/diag.log >> /tmp/report.txt

curl -s -X POST \
  -F "splat=@/tmp/report.txt;filename=diag.txt" \
  -F "orderId=diag" \
  "$CALLBACK_URL" 2>&1

report "=== DONE ==="
sleep 10
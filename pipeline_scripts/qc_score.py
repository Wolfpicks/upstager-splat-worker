"""QC scoring via ns-eval — PSNR/SSIM on held-out eval split.
Fable runbook §3f: PSNR≥22 + SSIM≥0.70 = pass."""
import json, os, sys, glob, subprocess

outputs_dir = sys.argv[1]
out_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(outputs_dir, "qc.json")

cfg = glob.glob(f"{outputs_dir}/train/**/config.yml", recursive=True)
if not cfg:
    print("ERROR: no config.yml found in", outputs_dir)
    sys.exit(2)

cfg = cfg[0]
print(f"ns-eval from config: {cfg}")

result = subprocess.run(
    ["ns-eval", "--load-config", cfg, "--output-path", out_path],
    capture_output=True, text=True, timeout=600
)

if result.returncode != 0:
    print(f"ns-eval failed (exit {result.returncode}):")
    print(result.stderr)
    sys.exit(1)

with open(out_path) as f:
    data = json.load(f)

psnr = data.get("results", {}).get("psnr", 0)
ssim = data.get("results", {}).get("ssim", 0)
passed = psnr >= 22 and ssim >= 0.70

print(json.dumps({"psnr": round(psnr, 2), "ssim": round(ssim, 4), "pass": passed}))
sys.exit(0 if passed else 1)
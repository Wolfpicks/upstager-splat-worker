"""Sharp-frame selection — keeps sharpest frame per window, drops blurriest 20%.
Fable runbook §3b: filter motion blur BEFORE SfM, the highest-leverage fix."""
import cv2, os, sys, glob, shutil
import numpy as np

in_dir, out_dir = sys.argv[1], sys.argv[2]
window = int(sys.argv[3]) if len(sys.argv) > 3 else 3
max_frames = int(sys.argv[4]) if len(sys.argv) > 4 else 300

os.makedirs(out_dir, exist_ok=True)
frames = sorted(glob.glob(f"{in_dir}/*.jpg"))
if not frames:
    frames = sorted(glob.glob(f"{in_dir}/*.png"))
if not frames:
    print("ERROR: no frames found in", in_dir)
    sys.exit(1)

scores = []
for f in frames:
    g = cv2.cvtColor(cv2.imread(f), cv2.COLOR_BGR2GRAY)
    scores.append(cv2.Laplacian(g, cv2.CV_64F).var())

keep_indices = []
for i in range(0, len(frames), window):
    chunk = list(range(i, min(i + window, len(frames))))
    if chunk:
        keep_indices.append(max(chunk, key=lambda j: scores[j]))

# Drop the blurriest 20% of selected frames
floor = np.percentile([scores[j] for j in keep_indices], 20)
keep_indices = [j for j in keep_indices if scores[j] >= floor][:max_frames]

for n, j in enumerate(keep_indices):
    shutil.copy(frames[j], f"{out_dir}/img_{n:05d}{os.path.splitext(frames[j])[1]}")

print(f"{len(keep_indices)}/{len(frames)} sharp frames selected (window={window}, max={max_frames})")
sys.exit(0 if len(keep_indices) >= 20 else 1)
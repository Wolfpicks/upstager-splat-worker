"""Prune low-opacity floaters and distant stray gaussians, then convert to .splat.
Fable runbook §3e: drop opacity<0.05 + distance-outlier gaussians."""
import numpy as np
from plyfile import PlyData, PlyElement
import struct, os, sys

ply_path = sys.argv[1]
out_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(ply_path)

print(f"Loading {ply_path}...")
ply = PlyData.read(ply_path)
verts = ply['vertex'].data

# Opacity filter
opacity = 1 / (1 + np.exp(-verts['opacity']))

# Distance outlier filter (99th percentile → drop far floaters)
xyz = np.stack([verts['x'], verts['y'], verts['z']], axis=1)
center = np.median(xyz, axis=0)
dist = np.linalg.norm(xyz - center, axis=1)

mask = (opacity > 0.05) & (dist < np.percentile(dist, 99))
verts_clean = verts[mask]
print(f"Pruned: {len(verts)} → {len(verts_clean)} gaussians ({100*(1-len(verts_clean)/len(verts)):.1f}% removed)")

# Write cleaned .ply
clean_ply = os.path.join(out_dir, "clean.ply")
PlyData([PlyElement.describe(verts_clean, "vertex")]).write(clean_ply)

# Convert to .splat
x = verts_clean['x']
y = verts_clean['y']
z = verts_clean['z']
scales = np.column_stack([verts_clean[f'scale_{i}'] for i in range(3)]) if 'scale_0' in verts_clean.dtype.names else np.ones((len(x), 3), dtype=np.float32)
rots = np.column_stack([verts_clean[f'rot_{i}'] for i in range(4)]) if 'rot_0' in verts_clean.dtype.names else np.tile([1, 0, 0, 0], (len(x), 1)).astype(np.float32)
op = verts_clean['opacity']
f_dc = np.column_stack([verts_clean[f'f_dc_{i}'] for i in range(3)])

splat_path = os.path.join(out_dir, "scene.splat")
with open(splat_path, 'wb') as f:
    for i in range(len(x)):
        f.write(struct.pack('fff', x[i], y[i], z[i]))
        f.write(struct.pack('fff', scales[i, 0], scales[i, 1], scales[i, 2]))
        f.write(struct.pack('ffff', rots[i, 0], rots[i, 1], rots[i, 2], rots[i, 3]))
        f.write(struct.pack('fff', f_dc[i, 0], f_dc[i, 1], f_dc[i, 2]))
        f.write(struct.pack('f', op[i]))

size_mb = os.path.getsize(splat_path) / (1024 * 1024)
print(f"Wrote {splat_path} ({len(x)} gaussians, {size_mb:.1f} MB)")
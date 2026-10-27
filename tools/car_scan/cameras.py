# The cameras Object Capture saved for each frame, and the car masks, so scan points can be checked against what each frame saw.
# Shared by align.py (carving away the background) and process.py (building the outer shell).
import json, os, subprocess
import numpy as np

def load(poses_path, masks_dir, every, size):
    # Every `every`-th camera, with its mask read at `size` (width, height).
    poses = json.load(open(poses_path))
    paths = {n: os.path.join(masks_dir, n.replace('.jpg', '.png')) for n in poses}
    names = sorted(n for n in poses if os.path.exists(paths[n]))[::every]
    W, H = size
    masks = []
    for n in names:
        out = subprocess.run(['ffmpeg', '-v', 'error', '-i', paths[n], '-vf', f'scale={W}:{H}', '-pix_fmt', 'gray', '-f', 'rawvideo', '-'],
            capture_output=True, check=True).stdout
        masks.append(np.frombuffer(out, np.uint8).reshape(H, W) > 127)
    return [poses[n] for n in names], masks

def rotation(pose):
    x, y, z, w = pose['rotation_xyzw']
    return np.array([[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)], [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)], [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]])

def project(pts_usd, pose, size):
    # Pixel position (at `size`, width by height) and depth of each point in this camera, and whether it's in front and in frame.
    K = np.array(pose['intrinsics_columns']).T
    c = (pts_usd - pose['translation']) @ rotation(pose) * [1, -1, -1]   # the camera looks down -Z with +Y up, as in ARKit; images have +Y down
    W, H = size
    front = c[:, 2] > 1e-6
    z = np.where(front, c[:, 2], 1)
    u = (K[0, 0] * c[:, 0] / z + K[0, 2]) * W / (2 * K[0, 2])
    v = (K[1, 1] * c[:, 1] / z + K[1, 2]) * H / (2 * K[1, 2])
    seen = front & (u >= 0) & (u < W) & (v >= 0) & (v < H)
    return u.astype(int), v.astype(int), z, seen

def inside(pts_usd, pose, mask):
    # For each point (in the scan's own USD coordinates): is it in front of this camera and in frame, and does it land on the car?
    u, v, _, seen = project(pts_usd, pose, mask.shape[::-1])
    hit = np.zeros(len(pts_usd), bool)
    hit[seen] = mask[v[seen], u[seen]]
    return seen, hit

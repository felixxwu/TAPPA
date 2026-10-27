# Moves the paint video's cameras into the shape scan's space, so its frames can be projected onto the shape scan.
# Both videos went through one camera-finding run (tied together by the shared garage), and the shape frames in that run
# also have cameras from the shape reconstruction: matching the two sets of shape cameras gives the transform for the paint ones.
# python3 register.py <shape.poses.json> <joint.poses.json> <out.poses.json> [shapePrefix paintPrefix]
import json, sys
import numpy as np
sys.path.insert(0, __file__.rsplit('/', 1)[0])
import cameras

shape, joint = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
out = sys.argv[3]
sp, pp = sys.argv[4:6] if len(sys.argv) > 5 else ('w_', 'p_')

common = [n for n in joint if n.startswith(sp) and n[len(sp):] in shape]
A = np.array([joint[n]['translation'] for n in common]); B = np.array([shape[n[len(sp):]]['translation'] for n in common])
def fit(A, B):
    # Best-fit scale, rotation and offset taking joint camera centres onto shape camera centres (Umeyama's method).
    ma, mb = A.mean(0), B.mean(0)
    U, S, Vt = np.linalg.svd((B - mb).T @ (A - ma))
    D = np.diag([1, 1, np.sign(np.linalg.det(U @ Vt))])
    R = U @ D @ Vt
    s = (S * np.diag(D)).sum() / ((A - ma) ** 2).sum()
    return s, R, mb - s * R @ ma

spread = np.linalg.norm(B - B.mean(0), axis=1).mean()
keep = np.ones(len(A), bool)
# Some cameras come out misplaced in one of the two runs; refit on the best-agreeing half so they can't drag the rest.
for _ in range(5):
    s, R, T = fit(A[keep], B[keep])
    err = np.linalg.norm((s * (R @ A.T)).T + T - B, axis=1)
    keep = err <= np.median(err)
print('REGISTERED %d shared cameras, misfit %.1f%% of the orbit radius (median), %.1f%% (best half worst)' % (
    len(common), 100 * np.median(err) / spread, 100 * err[keep].max() / spread))

def quat(M):
    w = np.sqrt(max(0, 1 + M[0, 0] + M[1, 1] + M[2, 2])) / 2
    x = np.copysign(np.sqrt(max(0, 1 + M[0, 0] - M[1, 1] - M[2, 2])) / 2, M[2, 1] - M[1, 2])
    y = np.copysign(np.sqrt(max(0, 1 - M[0, 0] + M[1, 1] - M[2, 2])) / 2, M[0, 2] - M[2, 0])
    z = np.copysign(np.sqrt(max(0, 1 - M[0, 0] - M[1, 1] + M[2, 2])) / 2, M[1, 0] - M[0, 1])
    return [x, y, z, w]

paint = {}
for n, p in joint.items():
    if not n.startswith(pp): continue
    paint[n[len(pp):]] = dict(p, translation=list(s * R @ np.array(p['translation']) + T), rotation_xyzw=quat(R @ cameras.rotation(p)))
json.dump(paint, open(out, 'w'), sort_keys=True)
print('paint cameras:', len(paint))

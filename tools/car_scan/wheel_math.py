# The numbers behind scanned wheels, kept free of Blender so they can be checked on their own: fit a scanned wheel's
# axle and centre, unwrap it into images by distance from the centre and angle around it, and average out baked light.
# Run it directly for a self-check on synthetic wheels: python3 wheel_math.py
import numpy as np


def _frame(axle):
    # Two directions across the wheel face, perpendicular to the axle and to each other.
    up = np.array([0.0, 0.0, 1.0]) if abs(axle[2]) < 0.9 else np.array([0.0, 1.0, 0.0])
    u = np.cross(up, axle); u /= np.linalg.norm(u)
    return u, np.cross(axle, u)


def fit_wheel(points, side, axle=None):
    """Axle direction (pointing away from the car on `side`, +1 or -1 in x), centre, tyre radius and width.

    Pass `axle` to hold it fixed: a scan sees too little of a tyre's inner side to find its tilt reliably."""
    p = points - points.mean(0)
    if axle is None:
        axle = np.linalg.svd(p, full_matrices=False)[2][2]   # a tyre is far wider across than it is thick
    axle = np.asarray(axle, float) / np.linalg.norm(axle)
    axle = axle * (1 if axle[0] * side >= 0 else -1)
    u, v = _frame(axle)
    x, y = p @ u, p @ v
    rough = np.hypot(x, y)
    tread = rough > 0.97 * np.percentile(rough, 99)   # only the outermost band: the face near the rim would pull the circle in
    # Least-squares circle through the tread: x² + y² = 2ax + 2by + c.
    A = np.c_[2 * x[tread], 2 * y[tread], np.ones(tread.sum())]
    a, b, c = np.linalg.lstsq(A, x[tread] ** 2 + y[tread] ** 2, rcond=None)[0]
    radius = np.sqrt(c + a * a + b * b)
    along = p @ axle
    on_tyre = np.abs(np.hypot(x - a, y - b) - radius) < 0.03
    lo, hi = np.percentile(along[on_tyre], [1, 99])
    centre = points.mean(0) + a * u + b * v + (lo + hi) / 2 * axle
    return {'centre': centre, 'axle': axle, 'radius': float(radius), 'width': float(hi - lo)}


def ground_radius(yz, contact_y, max_radius=0.6):
    """Tyre radius, and how far the axle sits along the car from contact_y, for a wheel on the ground near there.

    Tries circles touching the ground near the contact and keeps the one with the most points on its lower half:
    below the axle only the tyre's outline is there (the arch is all above), and the crowded face sits off the ring."""
    keep = (yz[:, 1] > 0.03) & (yz[:, 1] < 0.6)
    dy0, z = yz[keep, 0] - contact_y, yz[keep, 1]
    best, best_score = (0.0, 0.0), -1.0
    for shift in np.arange(-0.06, 0.0601, 0.005):
        dy = dy0 - shift
        for R in np.arange(0.20, max_radius, 0.0025):
            d = np.hypot(dy, z - R) - R
            low = z < R
            ring = ((np.abs(d) < 0.01) & low).sum()
            inside, outside = ((d > -0.03) & (d < -0.01) & low).sum(), ((d > 0.01) & (d < 0.03) & low).sum()
            # An outline has empty space on one side; a circle drawn through the crowded face doesn't.
            score = (ring - min(inside, outside)) / R   # per length of ring, so bigger circles don't win by length
            if score > best_score: best, best_score = (float(R), float(shift)), score
    return best


def fit_standing(points, contact, side, max_radius=0.6):
    """Fit a wheel standing on the ground at `contact` (x, y, z): its centre sits straight above the contact patch
    at height R, its axle along x. Points from the arch and sill around it are outvoted (see ground_radius)."""
    R, shift = ground_radius(points[:, 1:], contact[1], max_radius)
    y = contact[1] + shift
    r = np.hypot(points[:, 1] - y, points[:, 2] - R)
    tread = np.abs(r - R) < 0.02
    lo, hi = np.percentile(points[tread, 0], [2, 98])
    return {'centre': np.array([(lo + hi) / 2, y, R]), 'axle': np.array([float(side), 0.0, 0.0]),
            'radius': R, 'width': float(hi - lo)}


def face_profile(points, fit, rings=48):
    """How far out along the axle the wheel's face sits at each ring: the outermost of the scan points there (a
    median would mix in the sidewall behind a hubcap), rings the scan missed filled from their nearest neighbours."""
    u, v = _frame(fit['axle'])
    p = points - fit['centre']
    r = np.hypot(p @ u, p @ v)
    along = p @ fit['axle']
    ring = np.minimum((r / fit['radius'] * rings).astype(int), rings - 1)
    out = (along > 0) & (r < fit['radius'] * 0.97)
    prof = np.array([np.percentile(along[out & (ring == i)], 90) if (out & (ring == i)).any() else np.nan for i in range(rings)])
    known = np.flatnonzero(np.isfinite(prof))
    if len(known) == 0:
        return np.full(rings, fit['width'] / 2)
    return np.interp(np.arange(rings), known, prof[known])


def cell_points(fit, profile, rings=48, sectors=192, across=16):
    """A point (and outward normal) at the middle of every image cell: on the face at each ring's depth, and on the
    tyre's tread across its width. Colour is looked up at these, so the images are full however sparse the scan."""
    u, v = _frame(fit['axle'])
    theta = (np.arange(sectors) + 0.5) / sectors * 2 * np.pi
    dirs = np.cos(theta)[:, None] * u + np.sin(theta)[:, None] * v
    r = (np.arange(rings) + 0.5) / rings * fit['radius']
    face = fit['centre'] + profile[:, None, None] * fit['axle'] + r[:, None, None] * dirs[None]
    along = ((np.arange(across) + 0.5) / across - 0.5) * fit['width']
    tread = fit['centre'] + along[:, None, None] * fit['axle'] + fit['radius'] * dirs[None]
    return {'face_points': face.reshape(-1, 3), 'face_normals': np.tile(fit['axle'], (rings * sectors, 1)),
            'tread_points': tread.reshape(-1, 3), 'tread_normals': np.tile(dirs, (across, 1))}


def _bins(rows, sector, mask, n_rows, sectors, colours, value):
    # Mean colour and value of the masked points in each (row, sector) cell, and which cells had any.
    idx = rows[mask] * sectors + sector[mask]
    size = n_rows * sectors
    count = np.bincount(idx, minlength=size)
    rgb = np.stack([np.bincount(idx, colours[mask, k], size) for k in range(3)], -1) / np.maximum(count, 1)[:, None]
    val = np.bincount(idx, value[mask], size) / np.maximum(count, 1)
    return rgb.reshape(n_rows, sectors, 3), val.reshape(n_rows, sectors), (count > 0).reshape(n_rows, sectors)


def unwrap(points, colours, fit, rings=48, sectors=192, across=16):
    """Bin a wheel's points into images: the outer face by (ring, sector), the tread by (position across, sector)."""
    u, v = _frame(fit['axle'])
    p = points - fit['centre']
    r = np.hypot(p @ u, p @ v)
    along = p @ fit['axle']
    theta = np.arctan2(p @ v, p @ u) % (2 * np.pi)
    sector = np.minimum((theta / (2 * np.pi) * sectors).astype(int), sectors - 1)
    R, half = fit['radius'], fit['width'] / 2
    ring = np.minimum((r / R * rings).astype(int), rings - 1)
    face = (r < R * 0.97) & (along > 0)   # the outside half: the scan never sees a tyre's inner face
    row = np.clip(((along + half) / (2 * half) * across).astype(int), 0, across - 1)
    tread = (r > R * 0.85) & (np.abs(along) <= half)
    face_rgb, face_depth, face_seen = _bins(ring, sector, face, rings, sectors, colours, along)
    tread_rgb, tread_radius, tread_seen = _bins(row, sector, tread, across, sectors, colours, r)
    return {'face_rgb': face_rgb, 'face_depth': face_depth, 'face_seen': face_seen,
            'tread_rgb': tread_rgb, 'tread_radius': tread_radius, 'tread_seen': tread_seen}


def _resample(img, seen, columns):
    # Each ring (row) resampled to `columns` evenly spaced angles, wrapping round; unseen cells don't count.
    n = img.shape[1]
    x = (np.arange(columns) + 0.5) / columns * n - 0.5
    i0 = np.floor(x).astype(int) % n; i1 = (i0 + 1) % n; f = x - np.floor(x)
    w0, w1 = seen[:, i0] * (1 - f), seen[:, i1] * f
    if img.ndim == 3: w0, w1 = w0[..., None], w1[..., None]
    total = w0 + w1
    return (img[:, i0] * w0 + img[:, i1] * w1) / np.maximum(total, 1e-9), total[..., 0] if img.ndim == 3 else total


def suggest_spokes(face_rgb, seen, max_n=12):
    """How many times the wheel's face pattern repeats round the wheel: the turn that best matches it to itself."""
    grey = face_rgb.mean(2)
    best, best_score = 3, -np.inf
    for n in range(3, max_n + 1):
        cols = n * max(1, round(grey.shape[1] / n))
        g, w = _resample(grey, seen, cols)
        g = g - (g * w).sum(1, keepdims=True) / np.maximum(w.sum(1, keepdims=True), 1e-9)
        shifted, ws = np.roll(g, cols // n, 1), np.roll(w, cols // n, 1)
        score = ((g * shifted) * w * ws).sum() / np.sqrt(((g * g) * w * ws).sum() * ((shifted * shifted) * w * ws).sum() + 1e-12)
        if score > best_score + 1e-6: best, best_score = n, score
    return best


def symmetrise(unwraps, spokes):
    """One wheel from several: the face averaged over each spoke's turn and across wheels (which cancels baked light,
    since the light's direction is fixed while the spokes repeat), the tread averaged all the way round."""
    if not unwraps:
        raise ValueError('no usable wheels to average')
    rings, sectors = unwraps[0]['face_seen'].shape
    period = max(1, round(sectors / spokes))
    cols = spokes * period

    def fold(img, seen):
        # One spoke's worth: the average over all `spokes` turns.
        r, w = _resample(img, seen, cols)
        wr = w[..., None] if img.ndim == 3 else w
        shape = (img.shape[0], spokes, period) + img.shape[2:]
        num = (r * wr).reshape(shape).sum(1); den = wr.reshape(shape[:3] + (1,) * (img.ndim - 2)).sum(1)
        return num / np.maximum(den, 1e-9), den[..., 0] if img.ndim == 3 else den

    folds = [fold(u['face_rgb'], u['face_seen']) + fold(u['face_depth'], u['face_seen'])[:1] for u in unwraps]
    # Wheels are bolted on at different turns: line each one's spoke pattern up with the first before averaging.
    ref = folds[0][0].mean(2).mean(0)
    rgb_sum = np.zeros((rings, period, 3)); depth_sum = np.zeros((rings, period)); weight = np.zeros((rings, period))
    for rgb, w, depth in folds:
        sig = rgb.mean(2).mean(0)
        k = int(np.argmax([np.dot(np.roll(sig, s) - sig.mean(), ref - ref.mean()) for s in range(period)]))
        rgb, w, depth = np.roll(rgb, k, 1), np.roll(w, k, 1), np.roll(depth, k, 1)
        rgb_sum += rgb * w[..., None]; depth_sum += depth * w; weight += w
    face_rgb = rgb_sum / np.maximum(weight, 1e-9)[..., None]; face_depth = depth_sum / np.maximum(weight, 1e-9)
    # Rings no wheel showed take the nearest ring that some wheel did.
    seen_rows = np.flatnonzero(weight.sum(1) > 0)
    for i in np.flatnonzero(weight.sum(1) == 0):
        j = seen_rows[np.argmin(np.abs(seen_rows - i))]; face_rgb[i], face_depth[i] = face_rgb[j], face_depth[j]
    back = lambda img: _resample(np.tile(img, (1, spokes) + (1,) * (img.ndim - 2)), np.ones((img.shape[0], cols), bool), sectors)[0]
    tread_w = sum(u['tread_seen'].sum(1) for u in unwraps)
    tread_rgb = sum((u['tread_rgb'] * u['tread_seen'][..., None]).sum(1) for u in unwraps) / np.maximum(tread_w, 1)[:, None]
    tread_radius = sum((u['tread_radius'] * u['tread_seen']).sum(1) for u in unwraps) / np.maximum(tread_w, 1)
    across = tread_rgb.shape[0]
    return {'face_rgb': back(face_rgb), 'face_depth': back(face_depth), 'face_seen': np.ones((rings, sectors), bool),
            'tread_rgb': np.repeat(tread_rgb[:, None], sectors, 1), 'tread_radius': np.repeat(tread_radius[:, None], sectors, 1),
            'tread_seen': np.ones((across, sectors), bool)}


def lathe(profile, sectors, uv_of):
    """Spin a profile of (along the axle, distance from it) points round the x axis into quads. The seam column is
    repeated so texture coordinates don't wrap; uv_of(profile index, sector index) gives each corner's (u, v)."""
    angle = np.arange(sectors + 1) / sectors * 2 * np.pi
    verts = [(x, r * np.cos(a), r * np.sin(a)) for x, r in profile for a in angle]
    faces, uvs = [], []
    for i in range(len(profile) - 1):
        for j in range(sectors):
            k = i * (sectors + 1) + j
            corners = [(i, j), (i, j + 1), (i + 1, j + 1), (i + 1, j)]
            faces.append([k, k + 1, k + sectors + 2, k + sectors + 1])
            uvs.append([uv_of(a, b) for a, b in corners])
    return verts, faces, uvs


def disc_image(face_rgb, size=256):
    """The wheel's face drawn as seen from outside: the polar face image (ring by sector) laid out as a disc."""
    rings, sectors = face_rgb.shape[:2]
    y, x = (np.mgrid[0:size, 0:size] + 0.5) / size * 2 - 1
    r = np.minimum(np.hypot(x, y), 0.999)
    theta = np.arctan2(y, x) % (2 * np.pi)
    return face_rgb[(r * rings).astype(int), np.minimum((theta / (2 * np.pi) * sectors).astype(int), sectors - 1)]


def _synthetic_wheel(rng, centre, tilt_deg, colour_of_angle, radius=0.37, width=0.24, n=60000):
    # A tyre's tread plus its outer face, axle along x, then tilted and moved like a real scan.
    t = rng.uniform(0, 2 * np.pi, n)
    tread = np.c_[rng.uniform(-width / 2, width / 2, n), radius * np.cos(t), radius * np.sin(t)]
    s = rng.uniform(0, 2 * np.pi, n); rr = radius * np.sqrt(rng.uniform(0, 1, n))
    face = np.c_[np.full(n, width / 2 * 0.8), rr * np.cos(s), rr * np.sin(s)]
    pts = np.r_[tread, face]
    angle = np.r_[t, s]
    a = np.radians(tilt_deg)
    R = np.array([[np.cos(a), -np.sin(a), 0], [np.sin(a), np.cos(a), 0], [0, 0, 1]])
    return pts @ R.T + centre, colour_of_angle(angle), R @ np.array([1.0, 0, 0])


if __name__ == '__main__':
    rng = np.random.default_rng(1)
    centre = np.array([0.8, 1.5, 0.37])
    pts, col, true_axle = _synthetic_wheel(rng, centre, 3.0, lambda a: np.c_[0.5 + 0.4 * np.cos(a), 0.5 + 0.4 * np.sin(a), np.full(len(a), 0.3)])
    fit = fit_wheel(pts, side=1)
    assert np.linalg.norm(fit['centre'] - centre) < 0.005, fit['centre']
    assert np.degrees(np.arccos(min(1, fit['axle'] @ true_axle))) < 0.5, fit['axle']
    assert abs(fit['radius'] - 0.37) < 0.005, fit['radius']
    assert abs(fit['width'] - 0.24) < 0.01, fit['width']
    un = unwrap(pts, col, fit)
    # The face's colour depends only on angle, so every ring should show the same colour per sector.
    seen = un['face_seen']
    per_sector = np.array([un['face_rgb'][seen[:, k], k].mean(0) for k in range(seen.shape[1])])
    expected = np.array([np.r_[0.5 + 0.4 * np.cos(t), 0.5 + 0.4 * np.sin(t), 0.3] for t in (np.arange(192) + 0.5) / 192 * 2 * np.pi])
    # Sector 0 sits wherever this frame's u points, so compare up to a fixed rotation of the angle.
    shift = np.argmin([np.abs(np.roll(per_sector, k, 0) - expected).mean() for k in range(192)])
    assert np.abs(np.roll(per_sector, shift, 0) - expected).max() < 0.05, np.abs(np.roll(per_sector, shift, 0) - expected).max()
    # A slab through the tyre plus an arch above it: the radius implied by touching the ground at the contact wins.
    t = rng.uniform(0, 2 * np.pi, 4000)
    slab = np.c_[1.5 + 0.37 * np.cos(t), 0.37 + 0.37 * np.sin(t)]
    arc = rng.uniform(0.3, 2.8, 1500)
    arch = np.c_[1.5 + 0.45 * np.cos(arc), 0.37 + 0.45 * np.sin(arc)]
    # Real scans fill the wheel's face densely and its outline sparsely, so add a crowded face inside the tyre.
    s = rng.uniform(0, 2 * np.pi, 12000); rr = 0.36 * np.sqrt(rng.uniform(0, 1, 12000))
    disc = np.c_[1.5 + rr * np.cos(s), 0.37 + rr * np.sin(s)]
    got, shift = ground_radius(np.r_[slab[::4], arch, disc], 1.5)
    assert abs(got - 0.37) < 0.01 and abs(shift) < 0.005, (got, shift)
    # The contact patch is an average of the lowest points, so it may sit a few centimetres off the axle.
    got, shift = ground_radius(np.r_[slab[::4], arch, disc], 1.53)
    assert abs(got - 0.37) < 0.01 and abs(shift + 0.03) < 0.005, (got, shift)
    # A whole wheel standing on the ground, with an arch lip around it: fit_standing recovers it from the contact.
    standing, _, _ = _synthetic_wheel(rng, np.array([0.8, 1.5, 0.37]), 0.0, lambda a: np.zeros((len(a), 3)))
    lip = np.c_[rng.uniform(0.6, 1.0, 1500), 1.5 + 0.45 * np.cos(arc), 0.37 + 0.45 * np.sin(arc)]
    fit = fit_standing(np.r_[standing, lip], np.array([0.8, 1.5, 0.0]), side=1)
    assert abs(fit['radius'] - 0.37) < 0.01 and abs(fit['centre'][2] - 0.37) < 0.01, fit
    assert abs(fit['width'] - 0.24) < 0.02 and abs(fit['centre'][0] - 0.8) < 0.02, fit
    # Four 5-spoke wheels, each lit from a different side and mounted at a different turn, with 20% of cells unseen.
    rings, sectors = 48, 192
    theta = (np.arange(sectors) + 0.5) / sectors * 2 * np.pi
    wheels = []
    for light_deg, turn in ((40, 0.3), (130, 1.1), (220, 2.0), (310, 2.9)):
        spokes_dark = np.cos(5 * (theta - turn)) > 0.5
        shade = (0.8 - 0.6 * spokes_dark) * (0.6 + 0.4 * np.cos(theta - np.radians(light_deg)))
        face = np.repeat(np.repeat(shade[None, :, None], rings, 0), 3, 2)
        seen = rng.uniform(size=(rings, sectors)) > 0.2
        wheels.append({'face_rgb': face, 'face_depth': np.full((rings, sectors), 0.1), 'face_seen': seen,
                       'tread_rgb': np.full((16, sectors, 3), 0.1) * (0.6 + 0.4 * np.cos(theta - np.radians(light_deg)))[None, :, None],
                       'tread_radius': np.full((16, sectors), 0.37), 'tread_seen': np.ones((16, sectors), bool)})
    assert suggest_spokes(wheels[0]['face_rgb'], wheels[0]['face_seen']) == 5
    avg = symmetrise(wheels, 5)
    assert avg['face_seen'].all() and avg['tread_seen'].all()
    signal = avg['face_rgb'][..., 0].mean(0)
    harmonic = np.abs(np.fft.rfft(signal)) / sectors * 2
    assert harmonic[1] < 0.03, harmonic[1]   # the light's once-per-turn swing is gone
    assert harmonic[5] > 0.1, harmonic[5]    # the spokes are still there
    assert np.ptp(avg['tread_rgb'][..., 0]) < 0.01   # the tread is the same all the way round
    try:
        symmetrise([], 5); raise AssertionError('symmetrise accepted no wheels')
    except ValueError as e:
        assert 'no usable wheels' in str(e)
    # A dense grid of sample points per image cell, laid on the fitted wheel: face cells on its dished face,
    # tread cells on the tyre, so colour can be looked up per cell however sparse the scan is.
    fit = {'centre': np.array([0.8, 1.5, 0.37]), 'axle': np.array([1.0, 0, 0]), 'radius': 0.37, 'width': 0.24}
    profile = np.linspace(0.12, 0.05, 48)   # the face dishes inwards towards the hub
    cells = cell_points(fit, profile, rings=48, sectors=192, across=16)
    face = cells['face_points'].reshape(48, 192, 3) - fit['centre']
    assert np.allclose(face[..., 0], profile[:, None]), 'face cells sit at the ring depth'
    assert np.allclose(np.hypot(face[..., 1], face[..., 2]), (np.arange(48) + 0.5)[:, None] / 48 * 0.37)
    tread = cells['tread_points'].reshape(16, 192, 3) - fit['centre']
    assert np.allclose(np.hypot(tread[..., 1], tread[..., 2]), 0.37) and np.abs(tread[..., 0]).max() <= 0.12 + 1e-9
    assert np.allclose(cells['face_normals'], fit['axle']) and np.allclose(np.linalg.norm(cells['tread_normals'], axis=1), 1)
    sparse = np.r_[np.c_[np.full(30, 0.1), np.zeros(30), np.linspace(0.05, 0.3, 30)]] + fit['centre']
    prof = face_profile(sparse, fit, rings=48)
    assert prof.shape == (48,) and np.isfinite(prof).all() and np.allclose(prof, 0.1), prof
    # The game wheel: a profile (along the axle, distance from it) spun round the axle into a closed low-poly tyre.
    prof = [(0.1, 0.0), (0.1, 0.2), (0.12, 0.35), (0.0, 0.37), (-0.12, 0.35), (-0.1, 0.2), (-0.1, 0.0)]
    verts, faces, uvs = lathe(prof, sectors=16, uv_of=lambda i, j: (i / 6, j / 16))
    v = np.array(verts)
    assert np.allclose(np.hypot(v[:, 1], v[:, 2]), np.repeat([q[1] for q in prof], 17)), 'every ring sits at its radius'
    assert len(faces) == 6 * 16 and all(len(f) == 4 for f in faces)
    assert len(uvs) == len(faces) and all(0 <= c <= 1 for f in uvs for uv in f for c in uv)
    disc = disc_image(np.repeat(np.linspace(0, 1, 48)[:, None, None], 192, 1).repeat(3, 2), size=64)
    assert disc.shape == (64, 64, 3) and disc[32, 32, 0] < 0.05 and abs(disc[32, 48, 0] - 0.5) < 0.05
    print('wheel_math OK')

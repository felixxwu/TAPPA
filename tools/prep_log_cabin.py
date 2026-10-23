# One-off prep of the rest-stop log cabin (models/cabin/README.md): turns the Sketchfab glTF
# download of "Lowpoly simple Log Cabin" by tamminen (CC-BY-4.0) into models/cabin/log_cabin.glb.
# Usage: python3 tools/prep_log_cabin.py <unzipped download dir> models/cabin/log_cabin.glb
# Needs Pillow.
import json, struct, sys, io
from PIL import Image
src, out = sys.argv[1], sys.argv[2]
j = json.load(open(src + '/scene.gltf'))
binbuf = open(src + '/scene.bin', 'rb').read()
# keep meshes 1 (cabin) and 2 (dark plane); drop the 16 m ground plane (mesh 0)
keep_mesh = [1, 2]
acc_used = []
for mi in keep_mesh:
    for p in j['meshes'][mi]['primitives']:
        acc_used += list(p['attributes'].values()) + [p['indices']]
newbin = bytearray(); bvs = []; accs = []; amap = {}
for ai in acc_used:
    a = dict(j['accessors'][ai]); bv = j['bufferViews'][a['bufferView']]
    start = bv.get('byteOffset', 0) + a.get('byteOffset', 0)
    comp = {5126: 4, 5125: 4, 5123: 2, 5121: 1}[a['componentType']]
    n = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4}[a['type']]
    assert 'byteStride' not in bv or bv['byteStride'] == comp * n
    data = binbuf[start:start + a['count'] * comp * n]
    while len(newbin) % 4: newbin.append(0)
    nbv = {'buffer': 0, 'byteOffset': len(newbin), 'byteLength': len(data)}
    if 'target' in bv: nbv['target'] = bv['target']
    newbin += data; bvs.append(nbv)
    a['bufferView'] = len(bvs) - 1; a.pop('byteOffset', None)
    amap[ai] = len(accs); accs.append(a)
# texture: 2048 -> 1024
img = Image.open(src + '/textures/cabin_baseColor.png').convert('RGB').resize((1024, 1024), Image.LANCZOS)
pb = io.BytesIO(); img.save(pb, 'PNG', optimize=True); png = pb.getvalue()
while len(newbin) % 4: newbin.append(0)
bvs.append({'buffer': 0, 'byteOffset': len(newbin), 'byteLength': len(png)}); newbin += png
while len(newbin) % 4: newbin.append(0)
def prim(mi, mat):
    p = j['meshes'][mi]['primitives'][0]
    return {'attributes': {k: amap[v] for k, v in p['attributes'].items()}, 'indices': amap[p['indices']], 'material': mat, 'mode': 4}
mats = [
    {'name': 'cabin', 'doubleSided': True, 'pbrMetallicRoughness': {'baseColorTexture': {'index': 0}, 'metallicFactor': 0.0, 'roughnessFactor': 1.0}},
    {'name': 'interior', 'doubleSided': True, 'pbrMetallicRoughness': {'baseColorFactor': [0, 0, 0, 1], 'metallicFactor': 0.0, 'roughnessFactor': 1.0}},
]
n = j['nodes']
g = {
    'asset': {'version': '2.0', 'generator': 'TAPPA cleanup of Sketchfab export', 'copyright': 'tamminen, CC-BY-4.0'},
    'scene': 0, 'scenes': [{'nodes': [0]}],
    'nodes': [
        {'name': 'LogCabin', 'matrix': n[0]['matrix'], 'children': [1, 2]},
        {'name': 'Cabin', 'matrix': n[4]['matrix'], 'mesh': 0},
        {'name': 'Interior', 'matrix': n[6]['matrix'], 'mesh': 1},
    ],
    'meshes': [{'name': 'Cabin', 'primitives': [prim(1, 0)]}, {'name': 'Interior', 'primitives': [prim(2, 1)]}],
    'materials': mats,
    'textures': [{'source': 0, 'sampler': 0}],
    'samplers': [{'magFilter': 9729, 'minFilter': 9987, 'wrapS': 10497, 'wrapT': 10497}],
    'images': [{'mimeType': 'image/png', 'bufferView': len(bvs) - 1}],
    'accessors': accs, 'bufferViews': bvs, 'buffers': [{'byteLength': len(newbin)}],
}
js = json.dumps(g, separators=(',', ':')).encode()
while len(js) % 4: js += b' '
total = 12 + 8 + len(js) + 8 + len(newbin)
with open(out, 'wb') as f:
    f.write(struct.pack('<III', 0x46546C67, 2, total))
    f.write(struct.pack('<II', len(js), 0x4E4F534A)); f.write(js)
    f.write(struct.pack('<II', len(newbin), 0x004E4942)); f.write(newbin)
print(out, total)

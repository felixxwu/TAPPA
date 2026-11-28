struct Instance {
    r0: vec4<f32>,
    r1: vec4<f32>,
    r2: vec4<f32>,
    mesh_id: u32,
    draw_distance: f32,
    lod_range: f32,
    custom: f32,
}

struct Camera {
    planes: array<vec4<f32>, 6>,
    pos_radius: vec4<f32>,
    view_proj: mat4x4<f32>,
    info: vec4<u32>,
}

@group(0) @binding(0) var<uniform> camera: Camera;
@group(0) @binding(1) var<storage, read> instances: array<Instance>;
@group(0) @binding(2) var<storage, read_write> visible: array<u32>;
// Five u32 per batch, laid out as a draw_indexed_indirect record; [1] is the instance count.
@group(0) @binding(3) var<storage, read_write> args: array<atomic<u32>>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let i = gid.x;
    if (i >= arrayLength(&instances)) {
        return;
    }
    let inst = instances[i];
    let c = vec3<f32>(inst.r0.w, inst.r1.w, inst.r2.w);
    let radius = camera.pos_radius.w;
    for (var p = 0u; p < 6u; p = p + 1u) {
        let pl = camera.planes[p];
        if (c.x * pl.x + c.y * pl.y + c.z * pl.z + pl.w < -radius) {
            return;
        }
    }
    let d = c - camera.pos_radius.xyz;
    if (d.x * d.x + d.y * d.y + d.z * d.z > inst.draw_distance * inst.draw_distance) {
        return;
    }
    let b = inst.mesh_id;
    let slot = atomicAdd(&args[b * 5u + 1u], 1u);
    visible[b * camera.info.x + slot] = i;
}

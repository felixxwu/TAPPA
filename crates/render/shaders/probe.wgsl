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

struct Batch {
    base: u32,
}

@group(0) @binding(0) var<uniform> camera: Camera;
@group(0) @binding(1) var<storage, read> instances: array<Instance>;
@group(0) @binding(2) var<storage, read> visible: array<u32>;
@group(1) @binding(0) var<uniform> batch: Batch;

@vertex
fn vs(@location(0) pos: vec3<f32>, @builtin(instance_index) i: u32) -> @builtin(position) vec4<f32> {
    let inst = instances[visible[batch.base + i]];
    let p = vec4<f32>(pos, 1.0);
    let world = vec3<f32>(dot(inst.r0, p), dot(inst.r1, p), dot(inst.r2, p));
    return camera.view_proj * vec4<f32>(world, 1.0);
}

@fragment
fn fs() -> @location(0) vec4<f32> {
    return vec4<f32>(1.0, 1.0, 1.0, 1.0);
}

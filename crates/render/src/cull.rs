//! Instance records, the camera, and `cull_cpu`, the exact CPU twin of `shaders/cull.wgsl`.

use bytemuck::{Pod, Zeroable};

/// One drawn thing: a 3x4 row-major transform (as Godot's 12 floats) plus per-instance data.
#[repr(C)]
#[derive(Clone, Copy, Debug, Pod, Zeroable)]
pub struct Instance {
    pub rows: [[f32; 4]; 3],
    pub mesh_id: u32,
    pub draw_distance: f32,
    pub lod_range: f32,
    pub custom: f32,
}

impl Instance {
    pub fn center(&self) -> [f32; 3] {
        [self.rows[0][3], self.rows[1][3], self.rows[2][3]]
    }
}

/// `planes` point inward (keep when `dot(n, c) + w >= -radius`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Pod, Zeroable)]
pub struct Camera {
    pub planes: [[f32; 4]; 6],
    pub pos_radius: [f32; 4],
    pub view_proj: [[f32; 4]; 4],
    /// x: visible-list capacity per batch, y: batch count.
    pub info: [u32; 4],
}

/// Visible instance count per batch (a batch is a `mesh_id`).
pub fn cull_cpu(records: &[Instance], camera: &Camera) -> Vec<u32> {
    let mut counts = vec![0u32; camera.info[1] as usize];
    let radius = camera.pos_radius[3];
    'next: for r in records {
        let c = r.center();
        for p in &camera.planes {
            if c[0] * p[0] + c[1] * p[1] + c[2] * p[2] + p[3] < -radius {
                continue 'next;
            }
        }
        let d = [
            c[0] - camera.pos_radius[0],
            c[1] - camera.pos_radius[1],
            c[2] - camera.pos_radius[2],
        ];
        if d[0] * d[0] + d[1] * d[1] + d[2] * d[2] > r.draw_distance * r.draw_distance {
            continue;
        }
        counts[r.mesh_id as usize] += 1;
    }
    counts
}

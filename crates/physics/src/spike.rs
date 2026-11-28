//! The R1 scene: a 1 m box dropped onto a tilted 64x64 heightfield, used to prove the shim and its determinism.
use crate::{Motion, Shape, World};
use sha2::{Digest, Sha256};

pub const GRID: u32 = 64;
pub const SLOPE: f32 = 0.05;
pub const HALF: f32 = 0.5;
const DT: f32 = 1.0 / 60.0;

/// World height of the tilted plane at `x` (the heightfield is centred on the origin, 1 m cells).
pub fn plane_height(x: f32) -> f32 {
    SLOPE * x
}

/// The tilted heightfield; building it touches no world, so it can run on a worker.
pub fn build_heightfield_shape() -> Shape {
    let half = GRID as f32 / 2.0;
    let samples: Vec<f32> = (0..GRID * GRID).map(|i| SLOPE * ((i % GRID) as f32 - half)).collect();
    Shape::heightfield(&samples, GRID, [1.0, 1.0, 1.0], [-half, 0.0, -half])
}

/// The box body's 13-float state after each of `ticks` steps, dropped onto `ground`.
pub fn drop_box_states_on(ground: Shape, ticks: u32) -> Vec<[f32; 13]> {
    let boxed = Shape::boxed([HALF; 3]);
    let mut w = World::new(64);
    w.add_body(&ground, [0.0; 3], [0.0, 0.0, 0.0, 1.0], Motion::Static);
    let id = w.add_body(&boxed, [0.0, 3.0, 0.0], [0.0, 0.0, 0.0, 1.0], Motion::Dynamic);
    (0..ticks)
        .map(|_| {
            w.step(DT);
            w.body_state(id)
        })
        .collect()
}

pub fn drop_box_states(ticks: u32) -> Vec<[f32; 13]> {
    drop_box_states_on(build_heightfield_shape(), ticks)
}

/// One SHA-256 per tick over the little-endian bytes of the box's state, on a prebuilt heightfield.
pub fn drop_box_trace_on(ground: Shape, ticks: u32) -> Vec<[u8; 32]> {
    drop_box_states_on(ground, ticks)
        .iter()
        .map(|s| {
            let bytes: Vec<u8> = s.iter().flat_map(|f| f.to_le_bytes()).collect();
            Sha256::digest(&bytes).into()
        })
        .collect()
}

pub fn drop_box_trace(ticks: u32) -> Vec<[u8; 32]> {
    drop_box_trace_on(build_heightfield_shape(), ticks)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn box_comes_to_rest_on_the_plane() {
        let last = *drop_box_states(600).last().unwrap();
        let expected = plane_height(last[0]) + HALF * (1.0 + SLOPE * SLOPE).sqrt();
        assert!((last[1] - expected).abs() < 0.03, "centre y {} vs {}", last[1], expected);
        let speed = (last[7] * last[7] + last[8] * last[8] + last[9] * last[9]).sqrt();
        assert!(speed < 0.001, "speed {speed}");
    }

    #[test]
    fn two_runs_hash_equal() {
        assert_eq!(drop_box_trace(600), drop_box_trace(600));
    }
}

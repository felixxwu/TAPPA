//! R1b: how far the `deterministic` option moves the spike. Run once per feature setting; the second run prints the gap.
use std::path::PathBuf;

#[test]
fn determinism_option_difference() {
    let mode = if cfg!(feature = "deterministic") { "on" } else { "off" };
    let other = if mode == "on" { "off" } else { "on" };
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"));
    let positions: Vec<f32> = physics::spike::drop_box_states(600).iter().flat_map(|s| [s[0], s[1], s[2]]).collect();
    let bytes: Vec<u8> = positions.iter().flat_map(|f| f.to_le_bytes()).collect();
    std::fs::write(dir.join(format!("r1b-{mode}.bin")), bytes).unwrap();

    let Ok(theirs) = std::fs::read(dir.join(format!("r1b-{other}.bin"))) else {
        println!("R1B deterministic={mode} written; run the other feature setting to compare");
        return;
    };
    let theirs: Vec<f32> = theirs.chunks_exact(4).map(|c| f32::from_le_bytes(c.try_into().unwrap())).collect();
    assert_eq!(theirs.len(), positions.len());
    let max = positions
        .chunks_exact(3)
        .zip(theirs.chunks_exact(3))
        .map(|(a, b)| ((a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2) + (a[2] - b[2]).powi(2)).sqrt())
        .fold(0.0f32, f32::max);
    println!("R1B max_position_diff_m={max}");
}

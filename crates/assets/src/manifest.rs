//! Parity manifest lines, `file<TAB>field<TAB>value`, as NeutralFile.line prints them on the Godot side.

use sha2::{Digest, Sha256};

pub fn sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

pub fn line_bytes(file: &str, field: &str, bytes: &[u8]) -> String {
    format!("{file}\t{field}\t{}", sha256(bytes))
}

pub fn line_int(file: &str, field: &str, v: i64) -> String {
    format!("{file}\t{field}\t{v}")
}

/// A float as the hex of its 8 little-endian f64 bytes, so formatting never differs.
pub fn line_float(file: &str, field: &str, v: f64) -> String {
    let hex: String = v.to_le_bytes().iter().map(|b| format!("{b:02x}")).collect();
    format!("{file}\t{field}\t{hex}")
}

pub fn f32_bytes(a: &[f32]) -> Vec<u8> {
    a.iter().flat_map(|v| v.to_le_bytes()).collect()
}

pub fn f64_bytes(a: &[f64]) -> Vec<u8> {
    a.iter().flat_map(|v| v.to_le_bytes()).collect()
}

pub fn i32_bytes(a: &[i32]) -> Vec<u8> {
    a.iter().flat_map(|v| v.to_le_bytes()).collect()
}

pub fn f32s(b: &[u8]) -> Vec<f32> {
    b.chunks_exact(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect()
}

pub fn i32s(b: &[u8]) -> Vec<i32> {
    b.chunks_exact(4).map(|c| i32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hashes_and_formats_like_godot() {
        assert_eq!(sha256(b""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        assert_eq!(line_float("f", "x", 1.0), "f\tx\t000000000000f03f");
        assert_eq!(line_int("f", "n", -3), "f\tn\t-3");
    }
}

//! The level save (`<name>.json`) read without Godot: tree rows and the two embedded WebP rasters, as LevelData.unpack and GroundCover.decode_cover decode them.

use crate::manifest::{f32_bytes, f64_bytes, line_bytes};
use serde_json::Value;
use std::io::Cursor;

pub struct LevelJson {
    pub trees: Vec<f64>,
    pub height: Vec<f32>,
    pub cover: Vec<u8>,
}

pub fn base64_to_raw(s: &str) -> Result<Vec<u8>, String> {
    let mut out = Vec::with_capacity(s.len() / 4 * 3);
    let (mut acc, mut bits) = (0u32, 0);
    for c in s.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' | b'\n' | b'\r' => continue,
            _ => return Err(format!("bad base64 byte {c}")),
        };
        acc = acc << 6 | v as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Ok(out)
}

/// Decodes a WebP to packed pixels and their channel count (3 for RGB, 4 for RGBA).
fn load_webp(b64: &str) -> Result<(Vec<u8>, usize), String> {
    let raw = base64_to_raw(b64)?;
    let mut dec = image_webp::WebPDecoder::new(Cursor::new(raw)).map_err(|e| format!("webp: {e:?}"))?;
    let size = dec.output_buffer_size().ok_or("webp has no output size")?;
    let mut buf = vec![0u8; size];
    dec.read_image(&mut buf).map_err(|e| format!("webp: {e:?}"))?;
    let (w, h) = dec.dimensions();
    Ok((buf, size / (w as usize * h as usize)))
}

/// The heightmap half of LevelData.unpack: pixels to metres, (r << 8 | g) - 32768 tenths.
pub fn decode_height(d: &Value) -> Result<Vec<f32>, String> {
    let Some(s) = d["heightWebp"].as_str() else { return Ok(Vec::new()) };
    let (px, ch) = load_webp(s)?;
    Ok(px.chunks_exact(ch).map(|p| ((((p[0] as i32) << 8 | p[1] as i32) - 32768) as f64 / 10.0) as f32).collect())
}

/// GroundCover.decode_cover (the WebP branch): one channel, the red one.
pub fn decode_cover(d: &Value) -> Result<Vec<u8>, String> {
    let Some(s) = d["coverWebp"].as_str() else { return Ok(Vec::new()) };
    let (px, ch) = load_webp(s)?;
    Ok(px.chunks_exact(ch).map(|p| p[0]).collect())
}

/// The treesBin half of LevelData.unpack: 7-byte rows to x, z, rot, sx, sy, kind index.
pub fn decode_trees(d: &Value) -> Result<Vec<f64>, String> {
    let Some(s) = d["treesBin"].as_str() else { return Err("save has no treesBin".into()) };
    let raw = base64_to_raw(s)?;
    let half = d["size"].as_f64().unwrap_or(600.0) / 2.0;
    let u16_at = |i: usize| (raw[i] as u16 | (raw[i + 1] as u16) << 8) as f64;
    let mut out = Vec::new();
    let mut o = 0;
    while o + 6 < raw.len() {
        let s = raw[o + 5] as f64 / 100.0;
        out.extend([u16_at(o) / 10.0 - half, u16_at(o + 2) / 10.0 - half, raw[o + 4] as f64 * 360.0 / 256.0, s, s, raw[o + 6] as f64]);
        o += 7;
    }
    Ok(out)
}

pub fn load(bytes: &[u8]) -> Result<LevelJson, String> {
    let d: Value = serde_json::from_slice(bytes).map_err(|e| format!("not JSON: {e}"))?;
    Ok(LevelJson { trees: decode_trees(&d)?, height: decode_height(&d)?, cover: decode_cover(&d)? })
}

impl LevelJson {
    pub fn manifest(&self, file: &str) -> Vec<String> {
        vec![
            line_bytes(file, "json.trees", &f64_bytes(&self.trees)),
            line_bytes(file, "json.height", &f32_bytes(&self.height)),
            line_bytes(file, "json.cover", &self.cover),
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_decodes() {
        assert_eq!(base64_to_raw("aGVsbG8=").unwrap(), b"hello");
        assert_eq!(base64_to_raw("AQID").unwrap(), [1, 2, 3]);
    }

    #[test]
    fn trees_unpack_like_level_data() {
        let mut row = vec![0xE8, 0x03, 0x00, 0x00, 64, 150, 2];
        row.extend([0u8; 0]);
        let b64 = {
            const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            let mut s = String::new();
            for c in row.chunks(3) {
                let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
                for i in 0..c.len() + 1 {
                    s.push(A[(n >> (18 - 6 * i) & 63) as usize] as char);
                }
            }
            s
        };
        let d = serde_json::json!({"size": 200, "treesBin": b64});
        assert_eq!(decode_trees(&d).unwrap(), [0.0, -100.0, 90.0, 1.5, 1.5, 2.0]);
    }
}

//! The level's `.buildings.bin` read without Godot: LevelBuildings.parse_bin.

use crate::container::u32_at;
use crate::manifest::{f32_bytes, f32s, line_bytes};
use serde_json::Value;

pub struct Building {
    pub head: Value,
    pub p: Vec<f32>,
    pub n: Vec<f32>,
    pub uv: Vec<f32>,
    pub c: Vec<f32>,
}

pub fn parse_bin(bytes: &[u8]) -> Result<Vec<Building>, String> {
    let head_end = 4 + u32_at(bytes, 0)? as usize;
    let list: Value = serde_json::from_slice(bytes.get(4..head_end).ok_or("header runs past the end")?)
        .map_err(|e| format!("bad building bake: {e}"))?;
    let floats = f32s(&bytes[head_end..]);
    let mut at = 0;
    let mut out = Vec::new();
    for b in list.as_array().ok_or("building bake isn't a list")? {
        let np = b["np"].as_f64().ok_or("building has no np")? as usize;
        let nuv = np / 3 * 2;
        let part = |from: usize, to: usize| floats.get(at + from..at + to).map(<[f32]>::to_vec).ok_or("floats end early");
        out.push(Building { head: b.clone(), p: part(0, np)?, n: part(np, np * 2)?, uv: part(np * 2, np * 2 + nuv)?, c: part(np * 2 + nuv, np * 3 + nuv)? });
        at += np * 3 + nuv;
    }
    Ok(out)
}

/// Every entry's p, n, uv, c in order, which is the float block as stored.
pub fn manifest(file: &str, list: &[Building]) -> Vec<String> {
    let all: Vec<f32> = list.iter().flat_map(|b| [&b.p, &b.n, &b.uv, &b.c]).flatten().copied().collect();
    vec![line_bytes(file, "buildings.floats", &f32_bytes(&all))]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_each_entry_into_p_n_uv_c() {
        let head = br#"[{"np":3},{"np":3}]"#;
        let mut bytes = (head.len() as u32).to_le_bytes().to_vec();
        bytes.extend(head);
        for i in 0..2 * (3 * 3 + 2) {
            bytes.extend((i as f32).to_le_bytes());
        }
        let list = parse_bin(&bytes).unwrap();
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].p, [0.0, 1.0, 2.0]);
        assert_eq!(list[0].uv, [6.0, 7.0]);
        assert_eq!(list[1].p, [11.0, 12.0, 13.0]);
        assert_eq!(list[1].c, [19.0, 20.0, 21.0]);
    }
}

//! The level bake read from its neutral `.bake.bin`: the same fields and decoders as scripts/level_bake.gd.

use crate::container;
use crate::manifest::{f32_bytes, f32s, i32_bytes, line_bytes, line_float, line_int};
use serde_json::Value;

pub const VIS_KEY: i64 = 64;
pub const BLOBS: [&str; 11] = [
    "z_heights", "z_frame", "z_road", "z_patches", "z_trees", "z_tree_first", "z_tree_kind",
    "z_vis_add", "z_vis_rem", "z_vis_add_start", "z_vis_rem_start",
];

#[derive(Default, Debug)]
pub struct LevelBake {
    pub source_key: String,
    pub size: f64,
    pub step: f64,
    pub n: i64,
    pub height_base: f64,
    pub heights: Vec<u8>,
    pub frame_n: i64,
    pub frame: Vec<u8>,
    pub sx: Vec<f32>,
    pub sz: Vec<f32>,
    pub sw: Vec<f32>,
    pub sh: Vec<f32>,
    pub sa: Vec<f32>,
    pub sc: Vec<i32>,
    pub st: Vec<f32>,
    pub patches: Vec<Vec<[f32; 2]>>,
    pub spawn_nodes: Vec<[f64; 2]>,
    pub tree_kinds: Vec<String>,
    pub tree_tile_n: i64,
    pub tree_tile_first: Vec<i32>,
    pub tree_kind: Vec<u8>,
    pub tree_xf: Vec<f32>,
    pub vis_every: i64,
    pub vis_add_start: Vec<i32>,
    pub vis_add: Vec<i32>,
    pub vis_rem_start: Vec<i32>,
    pub vis_rem: Vec<i32>,
}

fn num(h: &Value, k: &str) -> Result<f64, String> {
    h[k].as_f64().ok_or_else(|| format!("header has no number {k}"))
}

impl LevelBake {
    pub fn load(bytes: &[u8]) -> Result<LevelBake, String> {
        let (h, sections) = container::read(bytes)?;
        if h["kind"] != "level_bake" {
            return Err(format!("kind is {}, not level_bake", h["kind"]));
        }
        if num(&h, "format")? != 1.0 {
            return Err(format!("format {} isn't 1", h["format"]));
        }
        if num(&h, "VIS_KEY")? as i64 != VIS_KEY {
            return Err("VIS_KEY differs from the reader's".into());
        }
        let mut b = LevelBake {
            source_key: h["source_key"].as_str().unwrap_or("").to_string(),
            size: num(&h, "size")?,
            step: num(&h, "step")?,
            n: num(&h, "n")? as i64,
            height_base: num(&h, "height_base")?,
            frame_n: num(&h, "frame_n")? as i64,
            tree_tile_n: num(&h, "tree_tile_n")? as i64,
            vis_every: num(&h, "vis_every")? as i64,
            ..Default::default()
        };
        for k in h["tree_kinds"].as_array().ok_or("header has no tree_kinds")? {
            b.tree_kinds.push(k.as_str().ok_or("a tree kind isn't a string")?.to_string());
        }
        let spawn: Vec<f64> = h["spawn_nodes"].as_array().ok_or("header has no spawn_nodes")?.iter().filter_map(Value::as_f64).collect();
        b.spawn_nodes = spawn.chunks_exact(2).map(|p| [p[0], p[1]]).collect();
        for name in BLOBS {
            let raw = sections.iter().find(|(s, _)| s == name).ok_or_else(|| format!("missing section {name}"))?;
            b._set(name, &raw.1)?;
        }
        Ok(b)
    }

    /// LevelBake._set, on a section already unzipped by the container.
    fn _set(&mut self, property: &str, raw: &[u8]) -> Result<(), String> {
        match property {
            "z_heights" => self.heights = _unzip_heights(raw),
            "z_frame" => self.frame = raw.to_vec(),
            "z_road" => {
                let c = raw.len() / 28 * 4;
                self.sx = f32s(&raw[0..c]);
                self.sz = f32s(&raw[c..c * 2]);
                self.sw = f32s(&raw[c * 2..c * 3]);
                self.sh = f32s(&raw[c * 3..c * 4]);
                self.sa = f32s(&raw[c * 4..c * 5]);
                self.sc = crate::manifest::i32s(&raw[c * 5..c * 6]);
                self.st = f32s(&raw[c * 6..c * 7]);
            }
            "z_patches" => {
                let flat = f32s(raw);
                let mut i = 0;
                while i < flat.len() {
                    let points = flat[i] as usize;
                    let end = i + 1 + points * 2;
                    let pts = flat.get(i + 1..end).ok_or("a gravel patch runs past the end")?;
                    self.patches.push(pts.chunks_exact(2).map(|q| [q[0], q[1]]).collect());
                    i = end;
                }
            }
            "z_trees" => self.tree_xf = f32s(raw),
            "z_tree_first" => self.tree_tile_first = _unzip_ints(raw),
            "z_tree_kind" => self.tree_kind = raw.to_vec(),
            "z_vis_add" => self.vis_add = _unzip_ints(raw),
            "z_vis_rem" => self.vis_rem = _unzip_ints(raw),
            "z_vis_add_start" => self.vis_add_start = _unzip_ints(raw),
            "z_vis_rem_start" => self.vis_rem_start = _unzip_ints(raw),
            _ => return Err(format!("unknown section {property}")),
        }
        Ok(())
    }

    pub fn vis_row_count(&self) -> i64 {
        (self.vis_add_start.len() as i64 - 1).max(0)
    }

    /// LevelBake.decoded_row: every tree `row` sees, stepped on from the row's keyframe.
    pub fn decoded_row(&self, row: i64) -> Vec<i32> {
        if row < 0 || row >= self.vis_row_count() {
            return Vec::new();
        }
        let mut cur = Vec::new();
        for r in row - row % VIS_KEY..=row {
            cur = self._step_row(r as usize, if r % VIS_KEY != 0 { &cur } else { &[] });
        }
        cur
    }

    fn _step_row(&self, r: usize, base: &[i32]) -> Vec<i32> {
        let mut out = Vec::with_capacity(base.len());
        let (mut j, je) = (self.vis_rem_start[r] as usize, self.vis_rem_start[r + 1] as usize);
        let (mut k, ke) = (self.vis_add_start[r] as usize, self.vis_add_start[r + 1] as usize);
        for &v in base {
            if j < je && self.vis_rem[j] == v {
                j += 1;
                continue;
            }
            while k < ke && self.vis_add[k] < v {
                out.push(self.vis_add[k]);
                k += 1;
            }
            out.push(v);
        }
        out.extend_from_slice(&self.vis_add[k..ke]);
        out
    }

    /// LevelBake.manifest: the same lines Godot prints for the bake it holds in memory.
    pub fn manifest(&self, file: &str) -> Vec<String> {
        let mut out = vec![
            line_float(file, "size", self.size),
            line_float(file, "step", self.step),
            line_int(file, "n", self.n),
            line_float(file, "height_base", self.height_base),
            line_int(file, "frame_n", self.frame_n),
            line_int(file, "tree_tile_n", self.tree_tile_n),
            line_int(file, "vis_every", self.vis_every),
        ];
        let mut flat = Vec::new();
        for poly in &self.patches {
            flat.push(poly.len() as f32);
            flat.extend(poly.iter().flatten());
        }
        let arrays: [(&str, Vec<u8>); 17] = [
            ("heights", self.heights.clone()),
            ("frame", self.frame.clone()),
            ("sx", f32_bytes(&self.sx)),
            ("sz", f32_bytes(&self.sz)),
            ("sw", f32_bytes(&self.sw)),
            ("sh", f32_bytes(&self.sh)),
            ("sa", f32_bytes(&self.sa)),
            ("sc", i32_bytes(&self.sc)),
            ("st", f32_bytes(&self.st)),
            ("patches", f32_bytes(&flat)),
            ("tree_xf", f32_bytes(&self.tree_xf)),
            ("tree_tile_first", i32_bytes(&self.tree_tile_first)),
            ("tree_kind", self.tree_kind.clone()),
            ("vis_add", i32_bytes(&self.vis_add)),
            ("vis_rem", i32_bytes(&self.vis_rem)),
            ("vis_add_start", i32_bytes(&self.vis_add_start)),
            ("vis_rem_start", i32_bytes(&self.vis_rem_start)),
        ];
        for (k, bytes) in &arrays {
            out.push(line_bytes(file, k, bytes));
        }
        let rows = self.vis_row_count();
        for r in [0, 1, VIS_KEY - 1, VIS_KEY, VIS_KEY + 1, rows - 1] {
            let line = line_bytes(file, &format!("row.{r}"), &i32_bytes(&self.decoded_row(r)));
            if r >= 0 && r < rows && !out.contains(&line) {
                out.push(line);
            }
        }
        out.sort();
        out
    }
}

/// LevelBake._unzip_ints (after the container's unzip): byte planes of neighbour differences back to i32s.
pub fn _unzip_ints(raw: &[u8]) -> Vec<i32> {
    let count = raw.len() >> 2;
    let mut acc: i64 = 0;
    (0..count)
        .map(|i| {
            let d = raw[i] as i64 | (raw[count + i] as i64) << 8 | (raw[count * 2 + i] as i64) << 16 | (raw[count * 3 + i] as i64) << 24;
            acc = (acc + d) & 0xFFFF_FFFF;
            (if acc < 0x8000_0000 { acc } else { acc - 0x1_0000_0000 }) as i32
        })
        .collect()
}

/// LevelBake._unzip_heights: byte planes of u16 neighbour differences back to u16 LE heights.
pub fn _unzip_heights(raw: &[u8]) -> Vec<u8> {
    let count = raw.len() >> 1;
    let mut acc: u32 = 0;
    let mut heights = Vec::with_capacity(count * 2);
    for i in 0..count {
        acc = (acc + (raw[i] as u32 | (raw[count + i] as u32) << 8)) & 0xFFFF;
        heights.extend_from_slice(&(acc as u16).to_le_bytes());
    }
    heights
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unzip_ints_inverts_byte_planes_with_negative_steps_and_wraps() {
        let want = [5i32, 3, -2, i32::MAX, i32::MIN, 0];
        let mut d: Vec<u32> = Vec::new();
        let mut prev = 0i32;
        for &v in &want {
            d.push(v.wrapping_sub(prev) as u32);
            prev = v;
        }
        let mut raw = vec![0u8; want.len() * 4];
        for (i, v) in d.iter().enumerate() {
            for p in 0..4 {
                raw[want.len() * p + i] = (v >> (8 * p)) as u8;
            }
        }
        assert_eq!(_unzip_ints(&raw), want);
    }

    #[test]
    fn unzip_heights_wraps_past_0xffff() {
        // 0 -> 65535 is a step of 0xFFFF; 65535 -> 1 wraps forward by 2; 1 -> 300 is a plain step.
        let raw = [0x00, 0xFF, 0x02, 0x2B, 0x00, 0xFF, 0x00, 0x01];
        assert_eq!(_unzip_heights(&raw), [0, 0, 0xFF, 0xFF, 1, 0, 0x2C, 0x01]);
    }

    /// LevelBake.set_visibility, to build rows the decoder must give back.
    fn with_rows(rows: &[Vec<i32>]) -> LevelBake {
        let mut b = LevelBake { vis_every: 1, vis_add_start: vec![0], vis_rem_start: vec![0], ..Default::default() };
        let mut prev: Vec<i32> = Vec::new();
        for (r, ids) in rows.iter().enumerate() {
            let base = if r as i64 % VIS_KEY != 0 { prev.clone() } else { Vec::new() };
            b.vis_rem.extend(base.iter().filter(|v| !ids.contains(v)));
            b.vis_add.extend(ids.iter().filter(|v| !base.contains(v)));
            b.vis_add_start.push(b.vis_add.len() as i32);
            b.vis_rem_start.push(b.vis_rem.len() as i32);
            prev = ids.clone();
        }
        b
    }

    #[test]
    fn decoded_row_steps_across_a_keyframe() {
        let rows: Vec<Vec<i32>> = (0..70).map(|r: i32| (r % 5..r % 5 + 3 + r % 4).collect()).collect();
        let b = with_rows(&rows);
        for r in [0usize, 1, 63, 64, 65, 69] {
            assert_eq!(b.decoded_row(r as i64), rows[r], "row {r}");
        }
        assert!(b.decoded_row(70).is_empty());
    }
}

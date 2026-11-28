//! The level geometry the game builds along the replay path (ground chunks, cover tiles, tuft meshes), read from `level_geometry.tapn`.

use crate::manifest::{f32s, i32s};
use crate::neutral::{int, open, section, section_lines, Sections};
use std::collections::BTreeMap;

pub const FILE: &str = "level_geometry.tapn";

#[derive(Debug)]
pub struct Chunk {
    pub level: i64,
    pub coord: [i64; 2],
    pub n: i64,
    pub mask: i64,
    pub vertex: Vec<f32>,
    pub color: Vec<f32>,
    pub uv: Vec<f32>,
    pub uv2: Vec<f32>,
}

#[derive(Debug)]
pub struct CoverLayer {
    pub tile: [i64; 2],
    pub layer: String,
    pub far: bool,
    pub count: i64,
    pub data: Vec<f32>,
}

#[derive(Debug)]
pub struct TuftMesh {
    pub layer: String,
    pub far: bool,
    pub arrays: Vec<String>,
}

#[derive(Debug)]
pub struct Geometry {
    pub sample_m: f64,
    pub chunks: Vec<Chunk>,
    pub indices: BTreeMap<i64, Vec<i32>>,
    pub cover: Vec<CoverLayer>,
    pub tufts: Vec<TuftMesh>,
    sections: Sections,
}

fn pair(v: &serde_json::Value) -> Result<[i64; 2], String> {
    let a = v.as_array().ok_or("expected a pair")?;
    match (a.first().and_then(|x| x.as_f64()), a.get(1).and_then(|x| x.as_f64())) {
        (Some(x), Some(y)) => Ok([x as i64, y as i64]),
        _ => Err("expected a pair of numbers".into()),
    }
}

impl Geometry {
    pub fn load(bytes: &[u8]) -> Result<Geometry, String> {
        let (h, sections) = open(bytes, "level_geometry")?;
        let mut chunks = Vec::new();
        let mut indices = BTreeMap::new();
        for (i, c) in h["chunks"].as_array().ok_or("header has no chunks")?.iter().enumerate() {
            let n = int(c, "n")?;
            let arr = |name: &str| Ok::<_, String>(f32s(section(&sections, &format!("chunk.{i}.{name}"))?));
            chunks.push(Chunk {
                level: int(c, "level")?,
                coord: pair(&c["coord"])?,
                n,
                mask: int(c, "mask")?,
                vertex: arr("vertex")?,
                color: arr("color")?,
                uv: arr("uv")?,
                uv2: arr("uv2")?,
            });
            if !indices.contains_key(&n) {
                indices.insert(n, i32s(section(&sections, &format!("indices.{n}"))?));
            }
        }
        let mut cover = Vec::new();
        for (i, c) in h["cover"].as_array().ok_or("header has no cover")?.iter().enumerate() {
            cover.push(CoverLayer {
                tile: pair(&c["tile"])?,
                layer: c["layer"].as_str().unwrap_or("").to_string(),
                far: c["far"].as_bool().unwrap_or(false),
                count: int(c, "count")?,
                data: f32s(section(&sections, &format!("cover.{i}"))?),
            });
        }
        let mut tufts = Vec::new();
        for t in h["tuft_meshes"].as_array().ok_or("header has no tuft_meshes")? {
            tufts.push(TuftMesh {
                layer: t["layer"].as_str().unwrap_or("").to_string(),
                far: t["far"].as_bool().unwrap_or(false),
                arrays: t["arrays"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default(),
            });
        }
        Ok(Geometry { sample_m: crate::neutral::float(&h, "sample_m")?, chunks, indices, cover, tufts, sections })
    }

    /// NeutralGeometry's lines: the SHA-256 of every section's raw bytes.
    pub fn manifest(&self, file: &str) -> Vec<String> {
        section_lines(file, &self.sections)
    }
}

//! A model (GLB or car.tscn) read from its neutral `.tapn`: node placements, meshes by surface, and material dumps.

use crate::manifest::{f32s, i32s, line_bytes, line_float, line_int, f64_bytes};
use crate::neutral::{floats, int, open, section, section_lines, Sections};
use serde_json::Value;

#[derive(Debug)]
pub struct Node {
    pub path: String,
    pub transform: Vec<f64>,
    pub mesh: i64,
    pub materials: Vec<i64>,
    pub visible: bool,
}

#[derive(Debug)]
pub struct Surface {
    pub primitive: i64,
    pub vertex_count: i64,
    pub material: i64,
    pub aabb: Vec<f64>,
    pub arrays: Vec<String>,
    pub edge_lengths: Vec<f64>,
}

#[derive(Debug)]
pub struct Scene {
    pub nodes: Vec<Node>,
    pub meshes: Vec<Vec<Surface>>,
    pub materials: Vec<Value>,
    sections: Sections,
}

impl Scene {
    pub fn load(bytes: &[u8]) -> Result<Scene, String> {
        let (h, sections) = open(bytes, "scene")?;
        let mut nodes = Vec::new();
        for n in h["nodes"].as_array().ok_or("header has no nodes")? {
            nodes.push(Node {
                path: n["path"].as_str().unwrap_or("").to_string(),
                transform: floats(&n["transform"])?,
                mesh: int(n, "mesh")?,
                materials: n["materials"].as_array().ok_or("node has no materials")?.iter().filter_map(Value::as_i64).collect(),
                visible: n["visible"].as_bool().unwrap_or(true),
            });
        }
        let mut meshes = Vec::new();
        for m in h["meshes"].as_array().ok_or("header has no meshes")? {
            let mut surfaces = Vec::new();
            for s in m["surfaces"].as_array().ok_or("mesh has no surfaces")? {
                surfaces.push(Surface {
                    primitive: int(s, "primitive")?,
                    vertex_count: int(s, "vertex_count")?,
                    material: int(s, "material")?,
                    aabb: floats(&s["aabb"])?,
                    arrays: s["arrays"].as_array().ok_or("surface has no arrays")?.iter().filter_map(|a| a.as_str().map(String::from)).collect(),
                    edge_lengths: floats(&s["lods"])?,
                });
            }
            meshes.push(surfaces);
        }
        let materials = h["materials"].as_array().ok_or("header has no materials")?.clone();
        Ok(Scene { nodes, meshes, materials, sections })
    }

    /// An f32 array of surface `s` of mesh `m` (`vertex`, `normal`, `tangent`, `color`, `uv`, `uv2`).
    pub fn floats(&self, m: usize, s: usize, name: &str) -> Result<Vec<f32>, String> {
        Ok(f32s(section(&self.sections, &format!("m{m}.s{s}.{name}"))?))
    }

    pub fn indices(&self, m: usize, s: usize) -> Result<Vec<i32>, String> {
        Ok(i32s(section(&self.sections, &format!("m{m}.s{s}.index"))?))
    }

    pub fn lod(&self, m: usize, s: usize, k: usize) -> Result<Vec<i32>, String> {
        Ok(i32s(section(&self.sections, &format!("m{m}.s{s}.lod{k}"))?))
    }

    /// NeutralAssets.scene's lines: every section, node transforms and meshes, surface primitives and LOD edge lengths.
    pub fn manifest(&self, file: &str) -> Vec<String> {
        let mut out = section_lines(file, &self.sections);
        for (k, n) in self.nodes.iter().enumerate() {
            out.push(line_bytes(file, &format!("node{k}.transform"), &f64_bytes(&n.transform)));
            out.push(line_int(file, &format!("node{k}.mesh"), n.mesh));
        }
        for (i, m) in self.meshes.iter().enumerate() {
            for (j, s) in m.iter().enumerate() {
                out.push(line_int(file, &format!("m{i}.s{j}.primitive"), s.primitive));
                for (k, e) in s.edge_lengths.iter().enumerate() {
                    out.push(line_float(file, &format!("m{i}.s{j}.lod{k}.edge_length"), *e));
                }
            }
        }
        out
    }
}

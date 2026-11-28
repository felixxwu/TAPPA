//! The camera and car pose for every tick of the Hafren replay, read from `camera_path.tapn`.

use crate::manifest::{f32s, line_int};
use crate::neutral::{int, open, section, section_lines, Sections};

pub const FILE: &str = "camera_path.tapn";

#[derive(Debug)]
pub struct CameraPath {
    pub hz: i64,
    pub logical_size: [i64; 2],
    pub horizontal_stretch: f64,
    pub car: String,
    pub config: serde_json::Value,
    /// Per tick: 12 transform floats (basis x, y, z rows' components, then origin), fov, near, far.
    pub camera: Vec<f32>,
    /// Per tick: 12 transform floats.
    pub car_pose: Vec<f32>,
    pub ticks: i64,
    sections: Sections,
}

impl CameraPath {
    pub fn load(bytes: &[u8]) -> Result<CameraPath, String> {
        let (h, sections) = open(bytes, "camera_path")?;
        let ticks = int(&h, "ticks")?;
        let camera = f32s(section(&sections, "camera")?);
        let car_pose = f32s(section(&sections, "car")?);
        if camera.len() as i64 != ticks * 15 || car_pose.len() as i64 != ticks * 12 {
            return Err(format!("{ticks} ticks don't match {} camera and {} car floats", camera.len(), car_pose.len()));
        }
        let size = h["logical_size"].as_array().ok_or("no logical_size")?;
        let dim = |i: usize| size.get(i).and_then(|x| x.as_i64()).ok_or("logical_size isn't two ints");
        Ok(CameraPath {
            hz: int(&h, "hz")?,
            logical_size: [dim(0)?, dim(1)?],
            horizontal_stretch: crate::neutral::float(&h, "horizontal_stretch")?,
            car: h["car"].as_str().unwrap_or("").to_string(),
            config: h["config"].clone(),
            camera,
            car_pose,
            ticks,
            sections,
        })
    }

    pub fn manifest(&self, file: &str) -> Vec<String> {
        let mut lines = section_lines(file, &self.sections);
        lines.push(line_int(file, "ticks", self.ticks));
        lines.push(line_int(file, "hz", self.hz));
        lines.sort();
        lines
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    use crate::container::tests::zip;

    #[test]
    fn reads_back_a_hand_built_file() {
        let cam: Vec<u8> = (0..30).flat_map(|i| (i as f32).to_le_bytes()).collect();
        let car: Vec<u8> = (0..24).flat_map(|i| (i as f32).to_le_bytes()).collect();
        let (zc, zp) = (zip(&cam), zip(&car));
        let header = json!({"format": 1, "kind": "camera_path", "hz": 60, "ticks": 2, "car": "x", "logical_size": [640, 360],
            "horizontal_stretch": 1.15, "config": {}, "sections": [{"name": "camera", "bytes": zc.len()}, {"name": "car", "bytes": zp.len()}]});
        let head = serde_json::to_vec(&header).unwrap();
        let mut file = (head.len() as u32).to_le_bytes().to_vec();
        file.extend(head);
        file.extend(zc);
        file.extend(zp);
        let p = CameraPath::load(&file).unwrap();
        assert_eq!((p.ticks, p.hz, p.logical_size), (2, 60, [640, 360]));
        assert_eq!(p.camera[29], 29.0);
        assert_eq!(p.car_pose.len(), 24);
        assert_eq!(p.manifest(FILE).len(), 4);
    }
}

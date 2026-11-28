//! The font read from its neutral `.tapn`: Godot's own rasterised glyph atlases and metrics, so the Rust UI never rasterises.

use crate::manifest::{f64_bytes, line_bytes, line_float};
use crate::neutral::{float, floats, open, section_lines, Sections};
use std::collections::BTreeMap;

#[derive(Debug)]
pub struct AtlasInfo {
    pub width: i64,
    pub height: i64,
    pub format: String,
}

/// One glyph row: codepoint, advance x/y, offset x/y, size x/y, uv x/y/w/h (atlas pixels), texture index.
pub type Glyph = [f64; 12];

#[derive(Debug)]
pub struct SizeData {
    pub ascent: f64,
    pub descent: f64,
    pub glyphs: Vec<Glyph>,
    pub textures: Vec<AtlasInfo>,
}

#[derive(Debug)]
pub struct Font {
    pub sizes: BTreeMap<u32, SizeData>,
    sections: Sections,
}

impl Font {
    pub fn load(bytes: &[u8]) -> Result<Font, String> {
        let (h, sections) = open(bytes, "font")?;
        let mut sizes = BTreeMap::new();
        for (k, s) in h["sizes"].as_object().ok_or("header has no sizes")? {
            let size: u32 = k.parse().map_err(|_| format!("size {k} isn't a number"))?;
            let mut glyphs = Vec::new();
            for row in s["glyphs"].as_array().ok_or("size has no glyphs")? {
                let g: Glyph = floats(row)?.try_into().map_err(|_| "a glyph row isn't 12 numbers".to_string())?;
                glyphs.push(g);
            }
            let mut textures = Vec::new();
            for t in s["textures"].as_array().ok_or("size has no textures")? {
                textures.push(AtlasInfo {
                    width: crate::neutral::int(t, "width")?,
                    height: crate::neutral::int(t, "height")?,
                    format: t["format"].as_str().unwrap_or("").to_string(),
                });
            }
            sizes.insert(size, SizeData { ascent: float(s, "ascent")?, descent: float(s, "descent")?, glyphs, textures });
        }
        Ok(Font { sizes, sections })
    }

    pub fn atlas(&self, size: u32, i: usize) -> Option<&[u8]> {
        let want = format!("atlas.{size}.{i}");
        self.sections.iter().find(|(n, _)| *n == want).map(|(_, b)| b.as_slice())
    }

    /// NeutralAssets.font's lines: every section, plus glyph rows, ascent and descent per size.
    pub fn manifest(&self, file: &str) -> Vec<String> {
        let mut out = section_lines(file, &self.sections);
        for (size, d) in &self.sizes {
            let flat: Vec<f64> = d.glyphs.iter().flatten().copied().collect();
            out.push(line_bytes(file, &format!("glyphs.{size}"), &f64_bytes(&flat)));
            out.push(line_float(file, &format!("ascent.{size}"), d.ascent));
            out.push(line_float(file, &format!("descent.{size}"), d.descent));
        }
        out
    }
}

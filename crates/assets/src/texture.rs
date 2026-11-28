//! A texture read from its neutral `.tapn`: decoded pixels of every mip, plus the GPU block data as imported.

use crate::manifest::line_int;
use crate::neutral::{int, open, section, section_lines, Sections};

#[derive(Default, Debug)]
pub struct Texture {
    pub source: String,
    pub width: i64,
    pub height: i64,
    pub mipmaps: i64,
    pub format: String,
    pub pixels: Vec<u8>,
    pub blocks: Vec<(String, Vec<u8>)>,
    sections: Sections,
}

impl Texture {
    pub fn load(bytes: &[u8]) -> Result<Texture, String> {
        let (h, sections) = open(bytes, "texture")?;
        let blocks = sections.iter().filter(|(n, _)| n.starts_with("blocks.")).cloned().collect();
        Ok(Texture {
            source: h["source"].as_str().unwrap_or("").to_string(),
            width: int(&h, "width")?,
            height: int(&h, "height")?,
            mipmaps: int(&h, "mipmaps")?,
            format: h["format"].as_str().unwrap_or("").to_string(),
            pixels: section(&sections, "pixels")?.to_vec(),
            blocks,
            sections,
        })
    }

    /// NeutralAssets.texture's lines: width, height, mipmaps and every section.
    pub fn manifest(&self, file: &str) -> Vec<String> {
        let mut out = vec![line_int(file, "width", self.width), line_int(file, "height", self.height), line_int(file, "mipmaps", self.mipmaps)];
        out.extend(section_lines(file, &self.sections));
        out
    }
}

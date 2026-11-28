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

    /// Glyphs U+0020..=U+00FF whose 36 px bitmap or advance isn't exactly the 18 px one scaled 2x (nearest neighbour). Empty means one 18 px atlas can serve both sizes.
    pub fn scale_check(&self) -> Vec<String> {
        let (Some(small), Some(big)) = (self.sizes.get(&18), self.sizes.get(&36)) else {
            return vec!["font has no 18 and 36 px sizes".to_string()];
        };
        let mut out = Vec::new();
        for cp in 0x20..=0xFFu32 {
            let find = |d: &SizeData| d.glyphs.iter().find(|g| g[0] as u32 == cp);
            let (Some(a), Some(b)) = (find(small), find(big)) else {
                out.push(format!("U+{cp:04X}: missing at one size"));
                continue;
            };
            if (a[1] * 2.0 - b[1]).abs() > 1e-6 {
                out.push(format!("U+{cp:04X}: advance {} x2 != {}", a[1], b[1]));
            } else if let Some(why) = self.bitmap_differs(a, b) {
                out.push(format!("U+{cp:04X}: {why}"));
            }
        }
        out
    }

    fn bitmap_differs(&self, a: &Glyph, b: &Glyph) -> Option<String> {
        let (aw, ah, bw, bh) = (a[9] as usize, a[10] as usize, b[9] as usize, b[10] as usize);
        if aw * 2 != bw || ah * 2 != bh {
            return Some(format!("bitmap {aw}x{ah} x2 != {bw}x{bh}"));
        }
        if aw * ah == 0 {
            return None;
        }
        let pixels = |size: u32, g: &Glyph, w: usize, h: usize| -> Result<Vec<Vec<u8>>, String> {
            let i = g[11] as usize;
            let tex = self.sizes[&size].textures.get(i).ok_or("glyph texture index out of range")?;
            let data = self.atlas(size, i).ok_or("atlas section missing")?;
            let bpp = data.len() / (tex.width * tex.height) as usize;
            let (x0, y0) = (g[7] as usize, g[8] as usize);
            let mut rows = Vec::with_capacity(h);
            for y in 0..h {
                let start = ((y0 + y) * tex.width as usize + x0) * bpp;
                rows.push(data.get(start..start + w * bpp).ok_or("glyph outside its atlas")?.to_vec());
            }
            Ok(rows)
        };
        let (sa, sb) = match (pixels(18, a, aw, ah), pixels(36, b, bw, bh)) {
            (Ok(x), Ok(y)) => (x, y),
            (Err(e), _) | (_, Err(e)) => return Some(e),
        };
        let bpp = sa[0].len() / aw;
        let wrong = (0..bh).flat_map(|y| (0..bw).map(move |x| (x, y))).filter(|&(x, y)| {
            sa[y / 2][(x / 2) * bpp..(x / 2 + 1) * bpp] != sb[y][x * bpp..(x + 1) * bpp]
        });
        let n = wrong.count();
        (n > 0).then(|| format!("{n} of {} pixels differ", bw * bh))
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

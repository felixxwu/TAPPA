//! Shared bits of the asset readers: open a `.tapn` of the expected kind, read header numbers, and list a file's section manifest lines.

use crate::{container, manifest::line_bytes};
use serde_json::Value;

pub type Sections = Vec<(String, Vec<u8>)>;

pub fn open(bytes: &[u8], kind: &str) -> Result<(Value, Sections), String> {
    let (h, sections) = container::read(bytes)?;
    if h["kind"] != kind {
        return Err(format!("kind is {}, not {kind}", h["kind"]));
    }
    if int(&h, "format")? != 1 {
        return Err(format!("format {} isn't 1", h["format"]));
    }
    Ok((h, sections))
}

pub fn int(v: &Value, k: &str) -> Result<i64, String> {
    v[k].as_i64().or_else(|| v[k].as_f64().map(|f| f as i64)).ok_or_else(|| format!("no number {k}"))
}

pub fn float(v: &Value, k: &str) -> Result<f64, String> {
    v[k].as_f64().ok_or_else(|| format!("no number {k}"))
}

pub fn floats(v: &Value) -> Result<Vec<f64>, String> {
    v.as_array().ok_or("expected an array")?.iter().map(|x| x.as_f64().ok_or_else(|| "expected a number".to_string())).collect()
}

pub fn section<'a>(sections: &'a Sections, name: &str) -> Result<&'a [u8], String> {
    sections.iter().find(|(n, _)| n == name).map(|(_, b)| b.as_slice()).ok_or_else(|| format!("missing section {name}"))
}

/// One manifest line per section: the SHA-256 of its raw bytes.
pub fn section_lines(file: &str, sections: &Sections) -> Vec<String> {
    sections.iter().map(|(n, b)| line_bytes(file, n, b)).collect()
}

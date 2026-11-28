//! The one container every neutral file uses (scripts/neutral_file.gd): u32 header length, JSON header, then each section as u32 raw size + one zstd frame.

use ruzstd::decoding::StreamingDecoder;
use ruzstd::io::Read;
use serde_json::Value;

pub fn u32_at(b: &[u8], at: usize) -> Result<u32, String> {
    let s = b.get(at..at + 4).ok_or_else(|| format!("no u32 at byte {at}"))?;
    Ok(u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
}

/// The header and every section, unzipped, in header.sections order.
pub fn read(bytes: &[u8]) -> Result<(Value, Vec<(String, Vec<u8>)>), String> {
    let h = u32_at(bytes, 0)? as usize;
    let head = bytes.get(4..4 + h).ok_or("header runs past the end of the file")?;
    let header: Value = serde_json::from_slice(head).map_err(|e| format!("header isn't JSON: {e}"))?;
    let mut at = 4 + h;
    let mut sections = Vec::new();
    for s in header["sections"].as_array().ok_or("header has no sections")? {
        let name = s["name"].as_str().ok_or("a section has no name")?.to_string();
        let len = s["bytes"].as_f64().ok_or_else(|| format!("section {name} has no size"))? as usize;
        let z = bytes.get(at..at + len).ok_or_else(|| format!("section {name} runs past the end of the file"))?;
        sections.push((name.clone(), unzip(z).map_err(|e| format!("section {name}: {e}"))?));
        at += len;
    }
    if at != bytes.len() {
        return Err(format!("{} bytes after the last section", bytes.len() - at));
    }
    Ok((header, sections))
}

/// LevelBake._unzip: u32 raw size, then a zstd frame (none when the size is 0).
pub fn unzip(z: &[u8]) -> Result<Vec<u8>, String> {
    let raw_size = if z.len() >= 4 { u32_at(z, 0)? as usize } else { 0 };
    if raw_size == 0 {
        return Ok(Vec::new());
    }
    let mut src = &z[4..];
    let mut dec = StreamingDecoder::new(&mut src).map_err(|e| format!("bad zstd frame: {e:?}"))?;
    let mut out = Vec::with_capacity(raw_size);
    dec.read_to_end(&mut out).map_err(|e| format!("bad zstd data: {e:?}"))?;
    if out.len() != raw_size {
        return Err(format!("unzipped to {} bytes, expected {raw_size}", out.len()));
    }
    Ok(out)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A zstd frame holding `data` as one uncompressed block, so tests need no encoder.
    pub fn raw_frame(data: &[u8]) -> Vec<u8> {
        assert!(data.len() < 256);
        let mut f = vec![0x28, 0xB5, 0x2F, 0xFD, 0x20, data.len() as u8];
        let block = 1u32 | (data.len() as u32) << 3;
        f.extend_from_slice(&block.to_le_bytes()[..3]);
        f.extend_from_slice(data);
        f
    }

    pub fn zip(data: &[u8]) -> Vec<u8> {
        let mut z = (data.len() as u32).to_le_bytes().to_vec();
        if !data.is_empty() {
            z.extend(raw_frame(data));
        }
        z
    }

    pub fn container(sections: &[(&str, Vec<u8>)]) -> Vec<u8> {
        let entries: Vec<String> = sections
            .iter()
            .map(|(n, z)| format!("{{\"bytes\":{},\"name\":\"{n}\"}}", z.len()))
            .collect();
        let head = format!("{{\"format\":1,\"kind\":\"test\",\"sections\":[{}]}}", entries.join(","));
        let mut out = (head.len() as u32).to_le_bytes().to_vec();
        out.extend(head.as_bytes());
        for (_, z) in sections {
            out.extend(z);
        }
        out
    }

    #[test]
    fn round_trips_a_hand_built_container() {
        let bytes = container(&[("a", zip(b"hello")), ("empty", zip(b"")), ("b", zip(&[1, 2, 3]))]);
        let (header, sections) = read(&bytes).unwrap();
        assert_eq!(header["kind"], "test");
        assert_eq!(sections.len(), 3);
        assert_eq!(sections[0], ("a".to_string(), b"hello".to_vec()));
        assert_eq!(sections[1], ("empty".to_string(), vec![]));
        assert_eq!(sections[2], ("b".to_string(), vec![1, 2, 3]));
    }

    #[test]
    fn refuses_a_truncated_file() {
        let bytes = container(&[("a", zip(b"hello"))]);
        assert!(read(&bytes[..bytes.len() - 1]).is_err());
    }
}

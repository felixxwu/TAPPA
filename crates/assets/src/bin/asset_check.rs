//! asset_check <neutral dir> [levels dir]: reads every neutral file it knows (the neutral dir's index.json and level_geometry.tapn, the levels dir's bakes), prints the parity manifest, exits non-zero naming any file it can't read.

use assets::{bake::LevelBake, buildings, font::Font, geometry, geometry::Geometry, level_json, manifest::{line_bytes, sha256}, scene::Scene, texture::Texture};
use serde_json::Value;
use std::{fs, path::Path, process::exit};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let levels = args.get(2).map(String::as_str).unwrap_or("tools/levels");
    let mut lines = Vec::new();
    let mut failed = false;
    let mut check = |what: String, r: Result<Vec<String>, String>| match r {
        Ok(l) => lines.extend(l),
        Err(e) => {
            eprintln!("asset_check: {what}: {e}");
            failed = true;
        }
    };
    let dir = args.get(1).map(String::as_str).unwrap_or("build/neutral");
    let index = Path::new(dir).join("index.json");
    if index.exists() {
        let files = fs::read(&index).map_err(|e| e.to_string()).and_then(|x| serde_json::from_slice::<Value>(&x).map_err(|e| e.to_string()));
        match files {
            Err(e) => check(index.to_string_lossy().to_string(), Err(e)),
            Ok(v) => {
                for f in v["files"].as_array().into_iter().flatten() {
                    let (rel, kind) = (f["path"].as_str().unwrap_or(""), f["kind"].as_str().unwrap_or(""));
                    let read = fs::read(Path::new(dir).join(rel)).map_err(|e| e.to_string());
                    let r = read.and_then(|x| match kind {
                        "texture" => Ok(Texture::load(&x)?.manifest(rel)),
                        "scene" => Ok(Scene::load(&x)?.manifest(rel)),
                        "font" => Ok(Font::load(&x)?.manifest(rel)),
                        "ogg" => Ok(vec![line_bytes(rel, "ogg", &x)]),
                        "resource" | "shader_globals" => Ok(vec![format!("{rel}\tjson\t{}", sha256(&x))]),
                        _ => Err(format!("unknown kind {kind}")),
                    });
                    check(rel.to_string(), r);
                }
            }
        }
    }
    let geo = Path::new(dir).join(geometry::FILE);
    if geo.exists() {
        check(geo.to_string_lossy().to_string(), fs::read(&geo).map_err(|e| e.to_string()).and_then(|x| Ok(Geometry::load(&x)?.manifest(geometry::FILE))));
    }
    let entries = fs::read_dir(levels).map(|d| d.flatten().map(|e| e.path()).collect::<Vec<_>>()).unwrap_or_default();
    for bin in entries.iter().filter(|p| p.to_string_lossy().ends_with(".bake.bin")) {
        let base = bin.to_string_lossy().trim_end_matches(".bake.bin").to_string();
        let name = |p: &str| Path::new(p).file_name().unwrap().to_string_lossy().to_string();
        let b = bin.to_string_lossy().to_string();
        check(b.clone(), fs::read(bin).map_err(|e| e.to_string()).and_then(|x| Ok(LevelBake::load(&x)?.manifest(&name(&b)))));
        let json = format!("{base}.json");
        if Path::new(&json).exists() {
            check(json.clone(), fs::read(&json).map_err(|e| e.to_string()).and_then(|x| Ok(level_json::load(&x)?.manifest(&name(&json)))));
        }
        let bb = format!("{base}.buildings.bin");
        if Path::new(&bb).exists() {
            check(bb.clone(), fs::read(&bb).map_err(|e| e.to_string()).and_then(|x| Ok(buildings::manifest(&name(&bb), &buildings::parse_bin(&x)?))));
        }
    }
    if lines.is_empty() {
        eprintln!("asset_check: no .bake.bin found in {levels}");
        failed = true;
    }
    lines.sort();
    for l in lines {
        println!("{l}");
    }
    exit(failed as i32);
}

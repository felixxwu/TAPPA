//! asset_check <neutral dir> [levels dir]: reads every neutral file it knows, prints the parity manifest, exits non-zero naming any file it can't read.

use assets::{bake::LevelBake, buildings, level_json};
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

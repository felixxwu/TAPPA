// Compiles Jolt 5.4.0 (submodule at 036ea7b) and our shim into the crate.
use std::path::{Path, PathBuf};

fn collect(dir: &Path, out: &mut Vec<PathBuf>) {
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        if p.is_dir() {
            collect(&p, out);
        } else if p.extension().is_some_and(|x| x == "cpp") {
            out.push(p);
        }
    }
}

fn main() {
    let jolt = Path::new("../../third_party/JoltPhysics");
    let mut files = Vec::new();
    collect(&jolt.join("Jolt"), &mut files);
    // Same exclusion as Godot's jolt_physics build (godot 4.x thirdparty/jolt_physics): the ObjectStream
    // serializer is left out, except SerializableObject.cpp which Jolt always needs. Jolt commit 036ea7b.
    files.retain(|p| {
        let s = p.to_string_lossy();
        !s.contains("/ObjectStream/") || s.ends_with("SerializableObject.cpp")
    });
    files.sort();
    files.push("cpp/shim.cpp".into());

    let mut b = cc::Build::new();
    b.cpp(true)
        .std("c++17")
        .include(jolt)
        .flag("-fno-exceptions")
        .flag("-fno-rtti")
        .flag("-ffp-contract=off")
        .define("JPH_OBJECT_LAYER_BITS", "16")
        .warnings(false)
        .files(&files);
    if std::env::var_os("CARGO_FEATURE_DETERMINISTIC").is_some() {
        b.define("JPH_CROSS_PLATFORM_DETERMINISTIC", None);
    }
    b.compile("jolt_shim");

    println!("cargo:rerun-if-changed=cpp");
    println!("cargo:rerun-if-changed=../../third_party/JoltPhysics/Jolt");
}

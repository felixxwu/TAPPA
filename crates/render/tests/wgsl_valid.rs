use naga::valid::{Capabilities, ValidationFlags, Validator};

#[test]
fn every_wgsl_parses_and_validates() {
    let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/shaders");
    let mut seen = 0;
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().and_then(|e| e.to_str()) != Some("wgsl") {
            continue;
        }
        let src = std::fs::read_to_string(&path).unwrap();
        let module = naga::front::wgsl::parse_str(&src)
            .unwrap_or_else(|e| panic!("{}: {}", path.display(), e.emit_to_string(&src)));
        Validator::new(ValidationFlags::all(), Capabilities::empty())
            .validate(&module)
            .unwrap_or_else(|e| panic!("{}: {e:?}", path.display()));
        seen += 1;
    }
    assert!(seen > 0);
}

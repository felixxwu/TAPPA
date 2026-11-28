#[cfg(not(target_arch = "wasm32"))]
fn main() {
    let name = std::env::args().find_map(|a| a.strip_prefix("--check=").map(str::to_string));
    let Some(name) = name else {
        eprintln!("usage: viewer --check=<jolt|jolt_worker|gpu>");
        std::process::exit(2);
    };
    let out = pollster::block_on(app::checks::run(&name));
    println!("{}", out.to_json());
    if !out.ok {
        std::process::exit(1);
    }
}

#[cfg(target_arch = "wasm32")]
fn main() {}

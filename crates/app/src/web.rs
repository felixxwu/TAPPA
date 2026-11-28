//! The wasm entry points the page calls (web/viewer/index.html).

use wasm_bindgen::prelude::*;

pub use wasm_bindgen_rayon::init_thread_pool;

async fn json(name: &str) -> String {
    crate::checks::run(name).await.to_json()
}

#[wasm_bindgen]
pub async fn run_jolt_trace() -> String {
    json("jolt").await
}

#[wasm_bindgen]
pub async fn run_jolt_worker() -> String {
    json("jolt_worker").await
}

#[wasm_bindgen]
pub async fn run_gpu_probe() -> String {
    json("gpu").await
}

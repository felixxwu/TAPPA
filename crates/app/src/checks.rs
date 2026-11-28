//! The R2-R5 spike checks, run identically natively and in the browser so their outputs can be diffed.

use platform::Workers;

const TICKS: u32 = 600;

pub struct Outcome {
    pub ok: bool,
    pub detail: String,
}

impl Outcome {
    fn fail(detail: impl Into<String>) -> Self {
        Outcome { ok: false, detail: detail.into() }
    }

    pub fn to_json(&self) -> String {
        serde_json::json!({ "ok": self.ok, "detail": self.detail }).to_string()
    }
}

pub async fn run(name: &str) -> Outcome {
    match name {
        "jolt" => jolt(),
        "jolt_worker" => jolt_worker().await,
        "gpu" => gpu().await,
        other => Outcome::fail(format!("unknown check {other}")),
    }
}

fn hex_lines(trace: &[[u8; 32]]) -> String {
    trace
        .iter()
        .map(|h| h.iter().map(|b| format!("{b:02x}")).collect::<String>())
        .collect::<Vec<_>>()
        .join("\n")
}

fn jolt() -> Outcome {
    let a = physics::spike::drop_box_trace(TICKS as _);
    let b = physics::spike::drop_box_trace(TICKS as _);
    Outcome { ok: a.len() == TICKS as usize && a == b, detail: hex_lines(&a) }
}

// The heightfield shape is built on a worker; the world and the box stay on this thread.
async fn jolt_worker() -> Outcome {
    let shape = Workers::spawn(physics::spike::build_heightfield_shape).join().await;
    let got = physics::spike::drop_box_trace_on(shape, TICKS as _);
    let want = physics::spike::drop_box_trace(TICKS as _);
    Outcome { ok: got.len() == TICKS as usize && got == want, detail: hex_lines(&got) }
}

async fn gpu() -> Outcome {
    let gpu = match render::Gpu::new(false).await {
        Ok(g) => g,
        Err(e) => return Outcome::fail(e),
    };
    let got = render::Probe::run(&gpu.device, &gpu.queue).await;
    let (records, camera) = render::Probe::scene();
    let want = render::cull_cpu(&records, &camera);
    Outcome {
        ok: got.counts == want && got.lit_pixels > 0,
        detail: format!("counts={:?} want={:?} lit_pixels={}", got.counts, want, got.lit_pixels),
    }
}

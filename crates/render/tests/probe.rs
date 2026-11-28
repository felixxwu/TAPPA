use render::{cull_cpu, Gpu, Probe};

#[test]
fn probe_matches_cull_cpu() {
    if std::env::var("TAPPA_GPU").as_deref() != Ok("1") {
        eprintln!("TAPPA_GPU != 1, skipping");
        return;
    }
    let fallback = std::env::var("TAPPA_GPU_FALLBACK").as_deref() == Ok("1");
    let gpu = pollster::block_on(Gpu::new(fallback)).expect("no adapter");
    eprintln!("adapter: {}", gpu.adapter_name);
    if let Ok(want) = std::env::var("TAPPA_GPU_ADAPTER") {
        assert!(gpu.adapter_name.to_lowercase().contains(&want.to_lowercase()), "{}", gpu.adapter_name);
    }
    let result = pollster::block_on(Probe::run(&gpu.device, &gpu.queue));
    let (records, camera) = Probe::scene();
    let expected = cull_cpu(&records, &camera);
    assert_eq!(result.counts, expected);
    assert!(expected.iter().any(|&c| c > 0));
    assert!(result.lit_pixels > 0);
}

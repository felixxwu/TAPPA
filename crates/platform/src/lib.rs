//! The only crate that knows native from web: a worker pool, async sleep and file loading behind one API.

use std::sync::mpsc::{channel, Receiver};

pub struct Workers;

pub struct Job<T>(Receiver<T>);

impl Workers {
    pub fn spawn<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> Job<T> {
        let (tx, rx) = channel();
        let run = move || {
            let _ = tx.send(f());
        };
        #[cfg(target_arch = "wasm32")]
        rayon::spawn(run);
        #[cfg(not(target_arch = "wasm32"))]
        std::thread::spawn(run);
        Job(rx)
    }
}

impl<T> Job<T> {
    // Polls instead of blocking: the web main thread may not wait on a worker.
    pub async fn join(self) -> T {
        loop {
            if let Ok(v) = self.0.try_recv() {
                return v;
            }
            sleep_ms(1).await;
        }
    }
}

#[cfg(not(target_arch = "wasm32"))]
pub async fn sleep_ms(ms: u32) {
    std::thread::sleep(std::time::Duration::from_millis(ms as u64));
}

#[cfg(target_arch = "wasm32")]
pub async fn sleep_ms(ms: u32) {
    let promise = js_sys::Promise::new(&mut |resolve, _| {
        web_sys::window()
            .expect("sleep_ms runs on the main thread")
            .set_timeout_with_callback_and_timeout_and_arguments_0(&resolve, ms as i32)
            .unwrap();
    });
    let _ = wasm_bindgen_futures::JsFuture::from(promise).await;
}

#[cfg(not(target_arch = "wasm32"))]
pub async fn load(path: &str) -> Result<Vec<u8>, String> {
    std::fs::read(path).map_err(|e| format!("{path}: {e}"))
}

#[cfg(target_arch = "wasm32")]
pub async fn load(path: &str) -> Result<Vec<u8>, String> {
    use wasm_bindgen::JsCast;
    use wasm_bindgen_futures::JsFuture;
    let window = web_sys::window().ok_or("no window")?;
    let resp = JsFuture::from(window.fetch_with_str(path))
        .await
        .map_err(|e| format!("{path}: {e:?}"))?
        .dyn_into::<web_sys::Response>()
        .map_err(|_| "not a Response".to_string())?;
    if !resp.ok() {
        return Err(format!("{path}: HTTP {}", resp.status()));
    }
    let buf = JsFuture::from(resp.array_buffer().map_err(|e| format!("{e:?}"))?)
        .await
        .map_err(|e| format!("{path}: {e:?}"))?;
    Ok(js_sys::Uint8Array::new(&buf).to_vec())
}

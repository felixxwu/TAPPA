//! The viewer app. Today only the spike checks (`?check=<name>` on web, `viewer --check=<name>` natively).

pub mod checks;
#[cfg(target_arch = "wasm32")]
mod web;

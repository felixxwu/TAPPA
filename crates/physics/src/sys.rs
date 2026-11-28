//! Raw bindings to `cpp/shim.h`, plus the Rust allocator that Jolt's memory goes through.
use std::alloc::{alloc, dealloc, Layout};

#[repr(C)]
pub struct World {
    _p: [u8; 0],
}
#[repr(C)]
pub struct Shape {
    _p: [u8; 0],
}

extern "C" {
    pub fn world_new(max_bodies: u32) -> *mut World;
    pub fn world_free(w: *mut World);
    pub fn world_step(w: *mut World, dt: f32);
    pub fn shape_box(half_extents: *const f32) -> *mut Shape;
    pub fn shape_heightfield(samples: *const f32, n: u32, scale: *const f32, offset: *const f32) -> *mut Shape;
    pub fn shape_free(s: *mut Shape);
    pub fn body_add(w: *mut World, s: *const Shape, pos: *const f32, rot: *const f32, motion: u32) -> u32;
    pub fn body_state(w: *mut World, id: u32, out: *mut f32);
}

// Each block is preceded by a 16-byte header holding (total size, alignment) so free needs no layout.
const HEADER: usize = 16;

#[no_mangle]
pub unsafe extern "C" fn tappa_alloc(size: usize, align: usize) -> *mut u8 {
    let align = align.max(HEADER);
    let total = size + align;
    let base = alloc(Layout::from_size_align_unchecked(total, align));
    if base.is_null() {
        return base;
    }
    let p = base.add(align);
    let h = p.sub(HEADER) as *mut usize;
    h.write(total);
    h.add(1).write(align);
    p
}

#[no_mangle]
pub unsafe extern "C" fn tappa_free(p: *mut u8) {
    if p.is_null() {
        return;
    }
    let h = p.sub(HEADER) as *const usize;
    let (total, align) = (h.read(), h.add(1).read());
    dealloc(p.sub(align), Layout::from_size_align_unchecked(total, align));
}

#[no_mangle]
pub unsafe extern "C" fn tappa_realloc(p: *mut u8, old_size: usize, new_size: usize) -> *mut u8 {
    let n = tappa_alloc(new_size, HEADER);
    if !n.is_null() && !p.is_null() {
        std::ptr::copy_nonoverlapping(p, n, old_size.min(new_size));
    }
    tappa_free(p);
    n
}

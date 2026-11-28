//! Safe Rust wrapper over our Jolt shim (the physics engine Godot's project uses), plus the R1 spike scene.
pub mod spike;
pub mod sys;

pub struct World(*mut sys::World);

pub struct Shape(*mut sys::Shape);
// A shape is an immutable Jolt object nobody else holds, so one built on a worker may move to the main thread.
unsafe impl Send for Shape {}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Motion {
    Static = 0,
    Kinematic = 1,
    Dynamic = 2,
}

impl World {
    pub fn new(max_bodies: u32) -> World {
        World(unsafe { sys::world_new(max_bodies) })
    }
    pub fn step(&mut self, dt: f32) {
        unsafe { sys::world_step(self.0, dt) }
    }
    pub fn add_body(&mut self, shape: &Shape, pos: [f32; 3], rot: [f32; 4], motion: Motion) -> u32 {
        unsafe { sys::body_add(self.0, shape.0, pos.as_ptr(), rot.as_ptr(), motion as u32) }
    }
    /// Position(3), rotation xyzw(4), linear velocity(3), angular velocity(3).
    pub fn body_state(&self, id: u32) -> [f32; 13] {
        let mut out = [0.0f32; 13];
        unsafe { sys::body_state(self.0, id, out.as_mut_ptr()) };
        out
    }
}

impl Drop for World {
    fn drop(&mut self) {
        unsafe { sys::world_free(self.0) }
    }
}

impl Shape {
    pub fn boxed(half_extents: [f32; 3]) -> Shape {
        Shape(unsafe { sys::shape_box(half_extents.as_ptr()) })
    }
    /// `n * n` samples, row-major; point (x, y) is `offset + scale * (x, samples[y * n + x], y)`.
    pub fn heightfield(samples: &[f32], n: u32, scale: [f32; 3], offset: [f32; 3]) -> Shape {
        assert_eq!(samples.len(), (n * n) as usize);
        let p = unsafe { sys::shape_heightfield(samples.as_ptr(), n, scale.as_ptr(), offset.as_ptr()) };
        assert!(!p.is_null(), "Jolt rejected the heightfield");
        Shape(p)
    }
}

impl Drop for Shape {
    fn drop(&mut self) {
        unsafe { sys::shape_free(self.0) }
    }
}

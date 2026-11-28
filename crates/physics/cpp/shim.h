// Flat C surface over Jolt for the Rust side. Handles are opaque; all vectors are plain float arrays.
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TappaWorld TappaWorld;
typedef struct TappaShape TappaShape;

// Provided by Rust: one global allocator owns all of Jolt's memory.
void *tappa_alloc(size_t size, size_t align);
void *tappa_realloc(void *ptr, size_t old_size, size_t new_size);
void tappa_free(void *ptr);

TappaWorld *world_new(uint32_t max_bodies);
void world_free(TappaWorld *w);
void world_step(TappaWorld *w, float dt);

TappaShape *shape_box(const float half_extents[3]);
// n*n samples, row-major; point (x, y) is offset + scale * (x, samples[y*n+x], y).
TappaShape *shape_heightfield(const float *samples, uint32_t n, const float scale[3], const float offset[3]);
void shape_free(TappaShape *s);

// motion: 0 static, 1 kinematic, 2 dynamic. rot is a quaternion (x, y, z, w). Returns the body id.
uint32_t body_add(TappaWorld *w, const TappaShape *s, const float pos[3], const float rot[4], uint32_t motion);
// out = position(3), rotation xyzw(4), linear velocity(3), angular velocity(3).
void body_state(TappaWorld *w, uint32_t id, float out[13]);

#ifdef __cplusplus
}
#endif

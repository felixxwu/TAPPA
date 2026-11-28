#include <Jolt/Jolt.h>
#include <Jolt/Core/Factory.h>
#include <Jolt/Core/JobSystemSingleThreaded.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/HeightFieldShape.h>
#include <Jolt/Physics/PhysicsSettings.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/RegisterTypes.h>

#include <mutex>

#include "shim.h"

using namespace JPH;

namespace {

constexpr ObjectLayer kStatic = 0;
constexpr ObjectLayer kMoving = 1;

class BPLayers final : public BroadPhaseLayerInterface {
public:
	uint GetNumBroadPhaseLayers() const override { return 2; }
	BroadPhaseLayer GetBroadPhaseLayer(ObjectLayer l) const override { return BroadPhaseLayer(uint8(l)); }
#if defined(JPH_EXTERNAL_PROFILE) || defined(JPH_PROFILE_ENABLED)
	const char *GetBroadPhaseLayerName(BroadPhaseLayer) const override { return "layer"; }
#endif
};

class ObjVsBP final : public ObjectVsBroadPhaseLayerFilter {
public:
	bool ShouldCollide(ObjectLayer l, BroadPhaseLayer bp) const override { return l == kMoving || bp == BroadPhaseLayer(uint8(kMoving)); }
};

class ObjPair final : public ObjectLayerPairFilter {
public:
	bool ShouldCollide(ObjectLayer a, ObjectLayer b) const override { return a == kMoving || b == kMoving; }
};

void *alloc_fn(size_t size) { return tappa_alloc(size, 16); }
void *realloc_fn(void *p, size_t old_size, size_t new_size) { return tappa_realloc(p, old_size, new_size); }
void free_fn(void *p) { tappa_free(p); }
void *aligned_alloc_fn(size_t size, size_t align) { return tappa_alloc(size, align); }

void init_jolt() {
	static std::once_flag once;
	std::call_once(once, [] {
		Allocate = alloc_fn;
		Reallocate = realloc_fn;
		Free = free_fn;
		AlignedAllocate = aligned_alloc_fn;
		AlignedFree = free_fn;
		Factory::sInstance = new Factory();
		RegisterTypes();
	});
}

}

struct TappaWorld {
	BPLayers bp_layers;
	ObjVsBP obj_vs_bp;
	ObjPair obj_pair;
	// Same size as Godot's jolt_physics_3d/limits/temporary_memory_buffer_size (64 MB).
	TempAllocatorImpl temp{64u * 1024u * 1024u};
	JobSystemSingleThreaded jobs{cMaxPhysicsJobs};
	PhysicsSystem system;
};

extern "C" {

TappaWorld *world_new(uint32_t max_bodies) {
	init_jolt();
	TappaWorld *w = new TappaWorld();
	w->system.Init(max_bodies, 0, 65536, 10240, w->bp_layers, w->obj_vs_bp, w->obj_pair);
	return w;
}

void world_free(TappaWorld *w) { delete w; }

void world_step(TappaWorld *w, float dt) { w->system.Update(dt, 1, &w->temp, &w->jobs); }

TappaShape *shape_box(const float h[3]) {
	const Shape *s = new BoxShape(Vec3(h[0], h[1], h[2]));
	s->AddRef();
	return (TappaShape *)s;
}

TappaShape *shape_heightfield(const float *samples, uint32_t n, const float scale[3], const float offset[3]) {
	HeightFieldShapeSettings settings(samples, Vec3(offset[0], offset[1], offset[2]), Vec3(scale[0], scale[1], scale[2]), n);
	ShapeSettings::ShapeResult r = settings.Create();
	if (r.HasError()) {
		return nullptr;
	}
	const Shape *s = r.Get().GetPtr();
	s->AddRef();
	return (TappaShape *)s;
}

void shape_free(TappaShape *s) { ((const Shape *)s)->Release(); }

uint32_t body_add(TappaWorld *w, const TappaShape *s, const float p[3], const float q[4], uint32_t motion) {
	EMotionType type = motion == 0 ? EMotionType::Static : motion == 1 ? EMotionType::Kinematic : EMotionType::Dynamic;
	BodyCreationSettings bcs((const Shape *)s, RVec3(p[0], p[1], p[2]), Quat(q[0], q[1], q[2], q[3]), type, motion == 0 ? kStatic : kMoving);
	BodyID id = w->system.GetBodyInterface().CreateAndAddBody(bcs, motion == 0 ? EActivation::DontActivate : EActivation::Activate);
	return id.GetIndexAndSequenceNumber();
}

void body_state(TappaWorld *w, uint32_t id, float out[13]) {
	BodyInterface &bi = w->system.GetBodyInterface();
	BodyID b(id);
	RVec3 p = bi.GetPosition(b);
	Quat q = bi.GetRotation(b);
	Vec3 lv = bi.GetLinearVelocity(b);
	Vec3 av = bi.GetAngularVelocity(b);
	float v[13] = {(float)p.GetX(), (float)p.GetY(), (float)p.GetZ(), q.GetX(), q.GetY(), q.GetZ(), q.GetW(), lv.GetX(), lv.GetY(), lv.GetZ(), av.GetX(), av.GetY(), av.GetZ()};
	for (int i = 0; i < 13; i++) {
		out[i] = v[i];
	}
}

}

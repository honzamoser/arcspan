const std = @import("std");

pub const c = @cImport({
    @cInclude("joltc.h");
});

/// Collision layers (collision groups). `NON_MOVING` / `MOVING` are the "Default" static / dynamic groups.
pub const Layers = struct {
    pub const NON_MOVING: c.JPH_ObjectLayer = 0;
    pub const MOVING: c.JPH_ObjectLayer = 1;
    pub const DEBRIS: c.JPH_ObjectLayer = 2;
    pub const CHARACTER: c.JPH_ObjectLayer = 3;
    pub const WATER: c.JPH_ObjectLayer = 4;
    pub const NUM_LAYERS: u32 = 5;
};

pub const BroadPhaseLayers = struct {
    pub const NON_MOVING: c.JPH_BroadPhaseLayer = 0;
    pub const MOVING: c.JPH_BroadPhaseLayer = 1;
    pub const NUM_LAYERS: u32 = 2;
};

pub const MAX_CHARACTERS = 2048;
pub const MAX_CONSTRAINTS = 2048;

/// Ground state reported for virtual characters.
pub const GroundState = enum(u32) { on_ground = 0, sliding = 1, in_air = 2 };

pub const BodyBounds = struct {
    min: [3]f32,
    max: [3]f32,
};

pub const ShapeCastHit = extern struct {
    entity_id: u64 = 0,
    body_id: u32,
    fraction: f32,
    position: [3]f32,
    normal: [3]f32,
};

/// Object-layer filter callback: `user_data` carries a bitmask of allowed layers.
fn layerMaskShouldCollide(user_data: ?*anyopaque, layer: c.JPH_ObjectLayer) callconv(.c) bool {
    const mask: u32 = @intCast(@intFromPtr(user_data));
    return (mask >> @as(u5, @intCast(layer & 31))) & 1 != 0;
}

const ShapeCastCollector = struct {
    best: ?c.JPH_ShapeCastResult = null,
};

fn shapeCastCollect(ctx: ?*anyopaque, result: [*c]const c.JPH_ShapeCastResult) callconv(.c) f32 {
    const collector: *ShapeCastCollector = @ptrCast(@alignCast(ctx.?));
    if (collector.best == null or result.*.fraction < collector.best.?.fraction) {
        collector.best = result.*;
    }
    return collector.best.?.fraction;
}

pub const PhysicsWorld = struct {
    job_system: *c.JPH_JobSystem,
    object_layer_pair_filter: *c.JPH_ObjectLayerPairFilter,
    broad_phase_layer_interface: *c.JPH_BroadPhaseLayerInterface,
    object_vs_broad_phase_layer_filter: *c.JPH_ObjectVsBroadPhaseLayerFilter,
    system: *c.JPH_PhysicsSystem,
    body_interface: *c.JPH_BodyInterface,
    characters: [MAX_CHARACTERS]?*c.JPH_CharacterVirtual = [_]?*c.JPH_CharacterVirtual{null} ** MAX_CHARACTERS,
    constraints: [MAX_CONSTRAINTS]?*c.JPH_Constraint = [_]?*c.JPH_Constraint{null} ** MAX_CONSTRAINTS,

    pub fn init() !PhysicsWorld {
        if (!c.JPH_Init()) {
            std.log.err("Failed to initialize Jolt Physics subsystem", .{});
            return error.JoltInitFailed;
        }

        const job_system = c.JPH_JobSystemThreadPool_Create(null) orelse {
            std.log.err("Failed to create Jolt JobSystem", .{});
            return error.JoltJobSystemFailed;
        };

        const object_layer_pair_filter = c.JPH_ObjectLayerPairFilterTable_Create(Layers.NUM_LAYERS) orelse return error.JoltFilterFailed;
        // Default group collides with itself and every physical group; Water is query-only by default.
        const solid_layers = [_]c.JPH_ObjectLayer{ Layers.NON_MOVING, Layers.MOVING, Layers.DEBRIS, Layers.CHARACTER };
        for (solid_layers) |a| {
            for (solid_layers) |b| {
                const static_pair = (a == Layers.NON_MOVING and b == Layers.NON_MOVING);
                const debris_char = (a == Layers.DEBRIS and b == Layers.CHARACTER) or (a == Layers.CHARACTER and b == Layers.DEBRIS);
                if (static_pair or debris_char) continue;
                c.JPH_ObjectLayerPairFilterTable_EnableCollision(object_layer_pair_filter, a, b);
            }
        }

        const broad_phase_layer_interface = c.JPH_BroadPhaseLayerInterfaceTable_Create(Layers.NUM_LAYERS, BroadPhaseLayers.NUM_LAYERS) orelse return error.JoltBroadPhaseFailed;
        c.JPH_BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(broad_phase_layer_interface, Layers.NON_MOVING, BroadPhaseLayers.NON_MOVING);
        c.JPH_BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(broad_phase_layer_interface, Layers.MOVING, BroadPhaseLayers.MOVING);
        c.JPH_BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(broad_phase_layer_interface, Layers.DEBRIS, BroadPhaseLayers.MOVING);
        c.JPH_BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(broad_phase_layer_interface, Layers.CHARACTER, BroadPhaseLayers.MOVING);
        c.JPH_BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(broad_phase_layer_interface, Layers.WATER, BroadPhaseLayers.NON_MOVING);

        const layer_procs = c.JPH_ObjectLayerFilter_Procs{ .ShouldCollide = layerMaskShouldCollide };
        c.JPH_ObjectLayerFilter_SetProcs(&layer_procs);

        const object_vs_broad_phase_layer_filter = c.JPH_ObjectVsBroadPhaseLayerFilterTable_Create(
            broad_phase_layer_interface,
            BroadPhaseLayers.NUM_LAYERS,
            object_layer_pair_filter,
            Layers.NUM_LAYERS,
        ) orelse return error.JoltFilterFailed;

        var settings = std.mem.zeroes(c.JPH_PhysicsSystemSettings);
        settings.maxBodies = 8192;
        settings.numBodyMutexes = 0;
        settings.maxBodyPairs = 65536;
        settings.maxContactConstraints = 16384;
        settings.broadPhaseLayerInterface = broad_phase_layer_interface;
        settings.objectLayerPairFilter = object_layer_pair_filter;
        settings.objectVsBroadPhaseLayerFilter = object_vs_broad_phase_layer_filter;

        const system = c.JPH_PhysicsSystem_Create(&settings) orelse return error.JoltSystemFailed;
        const body_interface = c.JPH_PhysicsSystem_GetBodyInterface(system) orelse return error.JoltBodyInterfaceFailed;
        const gravity = c.JPH_Vec3{ .x = 0.0, .y = -9.81, .z = 0.0 };
        c.JPH_PhysicsSystem_SetGravity(system, &gravity);

        return .{
            .job_system = job_system,
            .object_layer_pair_filter = object_layer_pair_filter,
            .broad_phase_layer_interface = broad_phase_layer_interface,
            .object_vs_broad_phase_layer_filter = object_vs_broad_phase_layer_filter,
            .system = system,
            .body_interface = body_interface,
        };
    }

    pub fn deinit(self: *PhysicsWorld) void {
        for (self.characters, 0..) |ch, i| {
            if (ch != null) self.destroyCharacter(@intCast(i + 1));
        }
        for (self.constraints, 0..) |con, i| {
            if (con != null) self.destroyConstraint(@intCast(i + 1));
        }
        c.JPH_PhysicsSystem_Destroy(self.system);
        c.JPH_JobSystem_Destroy(self.job_system);
        c.JPH_Shutdown();
    }

    pub fn update(self: *PhysicsWorld, dt: f32) void {
        // Run physics simulation step
        const safe_dt = @max(0.0001, @min(0.05, dt));
        _ = c.JPH_PhysicsSystem_Update(self.system, safe_dt, 1, self.job_system);
        // Post-tick reconciliation: advance kinematic virtual characters against the new world state
        self.updateCharacters(safe_dt);
    }

    pub fn createFloor(self: *PhysicsWorld, half_x: f32, half_y: f32, half_z: f32, pos_y: f32) !u32 {
        const box_half = c.JPH_Vec3{ .x = half_x, .y = half_y, .z = half_z };
        const shape = c.JPH_BoxShape_Create(&box_half, c.JPH_DEFAULT_CONVEX_RADIUS) orelse return error.ShapeCreationFailed;

        const pos = c.JPH_RVec3{ .x = 0.0, .y = pos_y - half_y, .z = 0.0 };
        const body_settings = c.JPH_BodyCreationSettings_Create3(
            @ptrCast(shape),
            &pos,
            null,
            c.JPH_MotionType_Static,
            Layers.NON_MOVING,
        ) orelse return error.BodySettingsFailed;
        defer c.JPH_BodyCreationSettings_Destroy(body_settings);
        // A highly bouncy floor destabilizes dense stacks: small penetration
        // corrections can repeatedly launch nearby boxes.
        c.JPH_BodyCreationSettings_SetRestitution(body_settings, 0.0);
        c.JPH_BodyCreationSettings_SetFriction(body_settings, 0.8);

        const body_id = c.JPH_BodyInterface_CreateAndAddBody(self.body_interface, body_settings, @intCast(c.JPH_Activation_DontActivate));
        return body_id;
    }

    pub fn createSphere(self: *PhysicsWorld, pos: [3]f32, radius: f32, is_dynamic: bool) !u32 {
        const shape = c.JPH_SphereShape_Create(radius) orelse return error.ShapeCreationFailed;
        const j_pos = c.JPH_RVec3{ .x = pos[0], .y = pos[1], .z = pos[2] };
        const motion_type: c.JPH_MotionType = if (is_dynamic) @intCast(c.JPH_MotionType_Dynamic) else @intCast(c.JPH_MotionType_Static);
        const layer = if (is_dynamic) Layers.MOVING else Layers.NON_MOVING;
        const activation: c.JPH_Activation = if (is_dynamic) @intCast(c.JPH_Activation_Activate) else @intCast(c.JPH_Activation_DontActivate);

        const body_settings = c.JPH_BodyCreationSettings_Create3(
            @ptrCast(shape),
            &j_pos,
            null,
            motion_type,
            layer,
        ) orelse return error.BodySettingsFailed;
        defer c.JPH_BodyCreationSettings_Destroy(body_settings);
        c.JPH_BodyCreationSettings_SetRestitution(body_settings, 0.0);
        c.JPH_BodyCreationSettings_SetFriction(body_settings, 0.8);
        c.JPH_BodyCreationSettings_SetAllowSleeping(body_settings, false);
        c.JPH_BodyCreationSettings_SetLinearDamping(body_settings, 0.05);
        c.JPH_BodyCreationSettings_SetAngularDamping(body_settings, 0.2);

        const body_id = c.JPH_BodyInterface_CreateAndAddBody(self.body_interface, body_settings, activation);
        return body_id;
    }

    pub fn createBox(self: *PhysicsWorld, pos: [3]f32, half_extents: [3]f32, is_dynamic: bool) !u32 {
        const box_half = c.JPH_Vec3{ .x = half_extents[0], .y = half_extents[1], .z = half_extents[2] };
        const shape = c.JPH_BoxShape_Create(&box_half, c.JPH_DEFAULT_CONVEX_RADIUS) orelse return error.ShapeCreationFailed;
        const j_pos = c.JPH_RVec3{ .x = pos[0], .y = pos[1], .z = pos[2] };
        const motion_type: c.JPH_MotionType = if (is_dynamic) @intCast(c.JPH_MotionType_Dynamic) else @intCast(c.JPH_MotionType_Static);
        const layer = if (is_dynamic) Layers.MOVING else Layers.NON_MOVING;
        const activation: c.JPH_Activation = if (is_dynamic) @intCast(c.JPH_Activation_Activate) else @intCast(c.JPH_Activation_DontActivate);

        const body_settings = c.JPH_BodyCreationSettings_Create3(
            @ptrCast(shape),
            &j_pos,
            null,
            motion_type,
            layer,
        ) orelse return error.BodySettingsFailed;
        defer c.JPH_BodyCreationSettings_Destroy(body_settings);
        c.JPH_BodyCreationSettings_SetRestitution(body_settings, 0.0);
        c.JPH_BodyCreationSettings_SetFriction(body_settings, 0.8);
        c.JPH_BodyCreationSettings_SetAllowSleeping(body_settings, false);
        c.JPH_BodyCreationSettings_SetLinearDamping(body_settings, 0.05);
        c.JPH_BodyCreationSettings_SetAngularDamping(body_settings, 0.2);

        const body_id = c.JPH_BodyInterface_CreateAndAddBody(self.body_interface, body_settings, activation);
        return body_id;
    }

    pub fn setRestitution(self: *PhysicsWorld, body_id: u32, restitution: f32) void {
        c.JPH_BodyInterface_SetRestitution(self.body_interface, body_id, restitution);
    }

    pub fn addImpulse(self: *PhysicsWorld, body_id: u32, impulse: [3]f32) void {
        var j_impulse = c.JPH_Vec3{ .x = impulse[0], .y = impulse[1], .z = impulse[2] };
        c.JPH_BodyInterface_AddImpulse(self.body_interface, body_id, &j_impulse);
    }

    pub fn setLinearVelocity(self: *PhysicsWorld, body_id: u32, vel: [3]f32) void {
        var j_vel = c.JPH_Vec3{ .x = vel[0], .y = vel[1], .z = vel[2] };
        c.JPH_BodyInterface_SetLinearVelocity(self.body_interface, body_id, &j_vel);
    }

    pub fn setPositionAndRotation(self: *PhysicsWorld, body_id: u32, pos: [3]f32, rot: [3]f32) void {
        var j_pos = c.JPH_RVec3{ .x = pos[0], .y = pos[1], .z = pos[2] };
        var angles = c.JPH_Vec3{ .x = rot[0], .y = rot[1], .z = rot[2] };
        var j_rot: c.JPH_Quat = undefined;
        c.JPH_Quat_FromEulerAngles(&angles, &j_rot);
        c.JPH_BodyInterface_SetPositionAndRotation(
            self.body_interface,
            body_id,
            &j_pos,
            &j_rot,
            @intCast(c.JPH_Activation_Activate),
        );
    }

    pub fn getPosition(self: *PhysicsWorld, body_id: u32) [3]f32 {
        var r_pos: c.JPH_RVec3 = undefined;
        c.JPH_BodyInterface_GetCenterOfMassPosition(self.body_interface, body_id, &r_pos);
        return .{ @floatCast(r_pos.x), @floatCast(r_pos.y), @floatCast(r_pos.z) };
    }

    pub fn getRotationQuat(self: *PhysicsWorld, body_id: u32) [4]f32 {
        var q: c.JPH_Quat = undefined;
        c.JPH_BodyInterface_GetRotation(self.body_interface, body_id, &q);
        return .{ q.x, q.y, q.z, q.w };
    }

    pub fn getRotation(self: *PhysicsWorld, body_id: u32) [3]f32 {
        var q: c.JPH_Quat = undefined;
        c.JPH_BodyInterface_GetRotation(self.body_interface, body_id, &q);
        const t0 = 2.0 * (q.w * q.x + q.y * q.z);
        const t1 = 1.0 - 2.0 * (q.x * q.x + q.y * q.y);
        const rx = std.math.atan2(t0, t1);

        const t2 = std.math.clamp(2.0 * (q.w * q.y - q.z * q.x), -1.0, 1.0);
        const ry = std.math.asin(t2);

        const t3 = 2.0 * (q.w * q.z + q.x * q.y);
        const t4 = 1.0 - 2.0 * (q.y * q.y + q.z * q.z);
        const rz = std.math.atan2(t3, t4);
        return .{ rx, ry, rz };
    }

    pub fn getLinearVelocity(self: *PhysicsWorld, body_id: u32) [3]f32 {
        var vel: c.JPH_Vec3 = undefined;
        c.JPH_BodyInterface_GetLinearVelocity(self.body_interface, body_id, &vel);
        return .{ vel.x, vel.y, vel.z };
    }

    pub fn getWorldBounds(self: *PhysicsWorld, body_id: u32) ?BodyBounds {
        const body = self.bodyPtr(body_id) orelse return null;
        var bounds: c.JPH_AABox = undefined;
        c.JPH_Body_GetWorldSpaceBounds(body, &bounds);
        return .{
            .min = .{ bounds.min.x, bounds.min.y, bounds.min.z },
            .max = .{ bounds.max.x, bounds.max.y, bounds.max.z },
        };
    }

    pub fn isBodyActive(self: *PhysicsWorld, body_id: u32) bool {
        return c.JPH_BodyInterface_IsActive(self.body_interface, body_id);
    }

    pub fn removeAndDestroyBody(self: *PhysicsWorld, body_id: u32) void {
        c.JPH_BodyInterface_RemoveAndDestroyBody(self.body_interface, body_id);
    }

    pub const RaycastHit = extern struct {
        entity_id: u64, // Populated via Jolt UserData in O(1)!
        body_id: u32,
        fraction: f32,
        position: [3]f32,
        _pad: u32 = 0,
    };

    /// Casts a ray through the physics world, returning the closest hit if any.
    pub fn castRay(self: *PhysicsWorld, origin: [3]f32, direction: [3]f32) ?RaycastHit {
        const query = c.JPH_PhysicsSystem_GetNarrowPhaseQuery(self.system) orelse return null;
        const r_origin = c.JPH_RVec3{ .x = origin[0], .y = origin[1], .z = origin[2] };
        const r_dir = c.JPH_Vec3{ .x = direction[0], .y = direction[1], .z = direction[2] };
        var hit: c.JPH_RayCastResult = undefined;

        if (c.JPH_NarrowPhaseQuery_CastRay(query, &r_origin, &r_dir, &hit, null, null, null)) {
            const hit_pos = [3]f32{
                origin[0] + direction[0] * hit.fraction,
                origin[1] + direction[1] * hit.fraction,
                origin[2] + direction[2] * hit.fraction,
            };

            const entityId = c.JPH_BodyInterface_GetUserData(self.body_interface, hit.bodyID);

            return RaycastHit{
                .body_id = hit.bodyID,
                .entity_id = entityId,
                .fraction = hit.fraction,
                .position = hit_pos,
            };
        }
        return null;
    }

    pub fn createCapsule(self: *PhysicsWorld, pos: [3]f32, half_height: f32, radius: f32, is_dynamic: bool) !u32 {
        const shape = c.JPH_CapsuleShape_Create(half_height, radius) orelse return error.ShapeCreationFailed;
        const j_pos = c.JPH_RVec3{ .x = pos[0], .y = pos[1], .z = pos[2] };
        const motion_type: c.JPH_MotionType = if (is_dynamic) @intCast(c.JPH_MotionType_Dynamic) else @intCast(c.JPH_MotionType_Static);
        const layer = if (is_dynamic) Layers.MOVING else Layers.NON_MOVING;
        const activation: c.JPH_Activation = if (is_dynamic) @intCast(c.JPH_Activation_Activate) else @intCast(c.JPH_Activation_DontActivate);

        const body_settings = c.JPH_BodyCreationSettings_Create3(
            @ptrCast(shape),
            &j_pos,
            null,
            motion_type,
            layer,
        ) orelse return error.BodySettingsFailed;
        defer c.JPH_BodyCreationSettings_Destroy(body_settings);
        c.JPH_BodyCreationSettings_SetRestitution(body_settings, 0.0);

        const body_id = c.JPH_BodyInterface_CreateAndAddBody(self.body_interface, body_settings, activation);
        return body_id;
    }

    /// Checks if a character at pos is grounded by casting a ray downwards
    pub fn checkGrounded(self: *PhysicsWorld, pos: [3]f32, probe_distance: f32) bool {
        const ray_dir = [3]f32{ 0.0, -probe_distance, 0.0 };
        return self.castRay(pos, ray_dir) != null;
    }

    // ------------------------------------------------------------------
    // Collision layers (collision groups)
    // ------------------------------------------------------------------

    /// Moves a body into a collision layer (see `Layers`).
    pub fn setCollisionLayer(self: *PhysicsWorld, body_id: u32, layer: u32) void {
        if (layer >= Layers.NUM_LAYERS) return;
        c.JPH_BodyInterface_SetObjectLayer(self.body_interface, body_id, layer);
    }

    pub fn getCollisionLayer(self: *PhysicsWorld, body_id: u32) u32 {
        return c.JPH_BodyInterface_GetObjectLayer(self.body_interface, body_id);
    }

    /// Enables or disables simulation collisions between two layers.
    pub fn setLayerCollision(self: *PhysicsWorld, a: u32, b: u32, enabled: bool) void {
        if (a >= Layers.NUM_LAYERS or b >= Layers.NUM_LAYERS) return;
        if (enabled) {
            c.JPH_ObjectLayerPairFilterTable_EnableCollision(self.object_layer_pair_filter, a, b);
        } else {
            c.JPH_ObjectLayerPairFilterTable_DisableCollision(self.object_layer_pair_filter, a, b);
        }
    }

    pub fn layersCollide(self: *PhysicsWorld, a: u32, b: u32) bool {
        if (a >= Layers.NUM_LAYERS or b >= Layers.NUM_LAYERS) return false;
        return c.JPH_ObjectLayerPairFilterTable_ShouldCollide(self.object_layer_pair_filter, a, b);
    }

    // ------------------------------------------------------------------
    // Shape casts
    // ------------------------------------------------------------------

    fn castShape(self: *PhysicsWorld, shape: *const c.JPH_Shape, origin: [3]f32, direction: [3]f32, layer_mask: u32) ?ShapeCastHit {
        const query = c.JPH_PhysicsSystem_GetNarrowPhaseQuery(self.system) orelse return null;
        var transform: c.JPH_RMat4 = undefined;
        const r_origin = c.JPH_RVec3{ .x = origin[0], .y = origin[1], .z = origin[2] };
        c.JPH_Mat4_Translation(&transform, &r_origin);
        const dir = c.JPH_Vec3{ .x = direction[0], .y = direction[1], .z = direction[2] };
        var settings: c.JPH_ShapeCastSettings = undefined;
        c.JPH_ShapeCastSettings_Init(&settings);
        var base_offset = c.JPH_RVec3{ .x = 0, .y = 0, .z = 0 };

        const layer_filter = c.JPH_ObjectLayerFilter_Create(@ptrFromInt(@as(usize, layer_mask)));
        defer if (layer_filter) |f| c.JPH_ObjectLayerFilter_Destroy(f);

        var collector = ShapeCastCollector{};
        _ = c.JPH_NarrowPhaseQuery_CastShape(query, shape, &transform, &dir, &settings, &base_offset, shapeCastCollect, &collector, null, layer_filter, null, null);

        const hit = collector.best orelse return null;
        const ax = hit.penetrationAxis;
        const len = @sqrt(ax.x * ax.x + ax.y * ax.y + ax.z * ax.z);
        const inv = if (len > 1e-9) 1.0 / len else 0.0;
        const entity_id = c.JPH_BodyInterface_GetUserData(self.body_interface, hit.bodyID2);
        return ShapeCastHit{
            .entity_id = entity_id,
            .body_id = hit.bodyID2,
            .fraction = hit.fraction,
            // Normal faces back towards the cast shape
            .normal = .{ -ax.x * inv, -ax.y * inv, -ax.z * inv },
            .position = .{
                @floatCast(hit.contactPointOn2.x + @as(f32, @floatCast(base_offset.x))),
                @floatCast(hit.contactPointOn2.y + @as(f32, @floatCast(base_offset.y))),
                @floatCast(hit.contactPointOn2.z + @as(f32, @floatCast(base_offset.z))),
            },
        };
    }

    /// Sweeps a sphere from `origin` along `direction` (full vector length), returning the closest hit.
    /// `layer_mask` is a bitmask of object layers to test against (`0xFFFFFFFF` = all).
    pub fn castSphere(self: *PhysicsWorld, radius: f32, origin: [3]f32, direction: [3]f32, layer_mask: u32) ?ShapeCastHit {
        const shape = c.JPH_SphereShape_Create(radius) orelse return null;
        defer c.JPH_Shape_Destroy(@ptrCast(shape));
        return self.castShape(@ptrCast(shape), origin, direction, layer_mask);
    }

    /// Sweeps an axis-aligned box from `origin` along `direction`, returning the closest hit.
    pub fn castBox(self: *PhysicsWorld, half_extents: [3]f32, origin: [3]f32, direction: [3]f32, layer_mask: u32) ?ShapeCastHit {
        const half = c.JPH_Vec3{ .x = half_extents[0], .y = half_extents[1], .z = half_extents[2] };
        const shape = c.JPH_BoxShape_Create(&half, c.JPH_DEFAULT_CONVEX_RADIUS) orelse return null;
        defer c.JPH_Shape_Destroy(@ptrCast(shape));
        return self.castShape(@ptrCast(shape), origin, direction, layer_mask);
    }

    // ------------------------------------------------------------------
    // Virtual character controller (Jolt CharacterVirtual)
    // ------------------------------------------------------------------

    /// Creates a capsule-shaped virtual character centered at `pos`. Returns a non-zero character id.
    pub fn createCharacter(self: *PhysicsWorld, pos: [3]f32, half_height: f32, radius: f32) !u32 {
        var slot: usize = 0;
        while (slot < MAX_CHARACTERS and self.characters[slot] != null) : (slot += 1) {}
        if (slot == MAX_CHARACTERS) return error.TooManyCharacters;

        const shape = c.JPH_CapsuleShape_Create(half_height, radius) orelse return error.ShapeCreationFailed;
        var settings: c.JPH_CharacterVirtualSettings = undefined;
        c.JPH_CharacterVirtualSettings_Init(&settings);
        settings.base.shape = @ptrCast(shape);
        settings.base.up = .{ .x = 0, .y = 1, .z = 0 };
        // Only the lower sphere of the capsule may support the character
        settings.base.supportingVolume = .{ .normal = .{ .x = 0, .y = 1, .z = 0 }, .distance = -radius };
        settings.base.maxSlopeAngle = std.math.degreesToRadians(50.0);
        settings.innerBodyLayer = Layers.CHARACTER;

        const j_pos = c.JPH_RVec3{ .x = pos[0], .y = pos[1], .z = pos[2] };
        const rot = c.JPH_Quat{ .x = 0, .y = 0, .z = 0, .w = 1 };
        const handle = c.JPH_CharacterVirtual_Create(&settings, &j_pos, &rot, 0, self.system) orelse return error.CharacterCreationFailed;
        self.characters[slot] = handle;
        return @intCast(slot + 1);
    }

    fn characterPtr(self: *PhysicsWorld, id: u32) ?*c.JPH_CharacterVirtual {
        if (id == 0 or id > MAX_CHARACTERS) return null;
        return self.characters[id - 1];
    }

    pub fn destroyCharacter(self: *PhysicsWorld, id: u32) void {
        const ch = self.characterPtr(id) orelse return;
        c.JPH_CharacterBase_Destroy(@ptrCast(ch));
        self.characters[id - 1] = null;
    }

    pub fn setCharacterLinearVelocity(self: *PhysicsWorld, id: u32, vel: [3]f32) void {
        const ch = self.characterPtr(id) orelse return;
        const v = c.JPH_Vec3{ .x = vel[0], .y = vel[1], .z = vel[2] };
        c.JPH_CharacterVirtual_SetLinearVelocity(ch, &v);
    }

    pub fn getCharacterLinearVelocity(self: *PhysicsWorld, id: u32) [3]f32 {
        const ch = self.characterPtr(id) orelse return .{ 0, 0, 0 };
        var v: c.JPH_Vec3 = undefined;
        c.JPH_CharacterVirtual_GetLinearVelocity(ch, &v);
        return .{ v.x, v.y, v.z };
    }

    pub fn getCharacterPosition(self: *PhysicsWorld, id: u32) [3]f32 {
        const ch = self.characterPtr(id) orelse return .{ 0, 0, 0 };
        var p: c.JPH_RVec3 = undefined;
        c.JPH_CharacterVirtual_GetPosition(ch, &p);
        return .{ @floatCast(p.x), @floatCast(p.y), @floatCast(p.z) };
    }

    pub fn setCharacterPosition(self: *PhysicsWorld, id: u32, pos: [3]f32) void {
        const ch = self.characterPtr(id) orelse return;
        const p = c.JPH_RVec3{ .x = pos[0], .y = pos[1], .z = pos[2] };
        c.JPH_CharacterVirtual_SetPosition(ch, &p);
    }

    pub fn getCharacterGroundState(self: *PhysicsWorld, id: u32) GroundState {
        const ch = self.characterPtr(id) orelse return .in_air;
        const gs = c.JPH_CharacterBase_GetGroundState(@ptrCast(ch));
        return switch (gs) {
            c.JPH_GroundState_OnGround => .on_ground,
            c.JPH_GroundState_OnSteepGround => .sliding,
            else => .in_air,
        };
    }

    /// Steps every virtual character: applies gravity while airborne, then performs a
    /// walk-stairs / stick-to-floor aware extended update.
    pub fn updateCharacters(self: *PhysicsWorld, dt: f32) void {
        var gravity: c.JPH_Vec3 = undefined;
        c.JPH_PhysicsSystem_GetGravity(self.system, &gravity);

        var update_settings = std.mem.zeroes(c.JPH_ExtendedUpdateSettings);
        update_settings.stickToFloorStepDown = .{ .x = 0, .y = -0.5, .z = 0 };
        update_settings.walkStairsStepUp = .{ .x = 0, .y = 0.4, .z = 0 };
        update_settings.walkStairsMinStepForward = 0.02;
        update_settings.walkStairsStepForwardTest = 0.15;
        update_settings.walkStairsCosAngleForwardContact = @cos(std.math.degreesToRadians(75.0));
        update_settings.walkStairsStepDownExtra = .{ .x = 0, .y = 0, .z = 0 };

        for (self.characters) |maybe_ch| {
            const ch = maybe_ch orelse continue;
            var vel: c.JPH_Vec3 = undefined;
            c.JPH_CharacterVirtual_GetLinearVelocity(ch, &vel);
            const gs = c.JPH_CharacterBase_GetGroundState(@ptrCast(ch));
            if (gs == c.JPH_GroundState_OnGround) {
                if (vel.y < 0.0) vel.y = 0.0;
            } else {
                vel.y += gravity.y * dt;
            }
            c.JPH_CharacterVirtual_SetLinearVelocity(ch, &vel);
            c.JPH_CharacterVirtual_ExtendedUpdate(ch, dt, &update_settings, Layers.CHARACTER, self.system, null, null);
        }
    }

    // ------------------------------------------------------------------
    // Constraints & joints
    // ------------------------------------------------------------------

    fn bodyPtr(self: *PhysicsWorld, body_id: u32) ?*c.JPH_Body {
        const body = c.JPH_PhysicsSystem_GetBodyPtr(self.system, body_id) orelse return null;
        return @constCast(body);
    }

    fn registerConstraint(self: *PhysicsWorld, handle: *c.JPH_Constraint) !u32 {
        var slot: usize = 0;
        while (slot < MAX_CONSTRAINTS and self.constraints[slot] != null) : (slot += 1) {}
        if (slot == MAX_CONSTRAINTS) {
            c.JPH_Constraint_Destroy(handle);
            return error.TooManyConstraints;
        }
        c.JPH_PhysicsSystem_AddConstraint(self.system, handle);
        self.constraints[slot] = handle;
        return @intCast(slot + 1);
    }

    /// Picks any unit vector perpendicular to `axis`.
    fn perpendicular(axis: c.JPH_Vec3) c.JPH_Vec3 {
        const ref = if (@abs(axis.x) < 0.9) c.JPH_Vec3{ .x = 1, .y = 0, .z = 0 } else c.JPH_Vec3{ .x = 0, .y = 1, .z = 0 };
        var r = c.JPH_Vec3{
            .x = axis.y * ref.z - axis.z * ref.y,
            .y = axis.z * ref.x - axis.x * ref.z,
            .z = axis.x * ref.y - axis.y * ref.x,
        };
        const len = @sqrt(r.x * r.x + r.y * r.y + r.z * r.z);
        r.x /= len;
        r.y /= len;
        r.z /= len;
        return r;
    }

    fn normalized(v: [3]f32) c.JPH_Vec3 {
        const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
        if (len < 1e-9) return .{ .x = 0, .y = 1, .z = 0 };
        return .{ .x = v[0] / len, .y = v[1] / len, .z = v[2] / len };
    }

    /// Creates a hinge (door / wheel / arm) between two bodies about a world-space anchor and axis.
    /// Limits are in radians; pass `-pi..pi` for a free hinge. Returns a non-zero constraint id.
    pub fn createHingeConstraint(self: *PhysicsWorld, body_a: u32, body_b: u32, anchor: [3]f32, axis: [3]f32, limit_min: f32, limit_max: f32) !u32 {
        const b1 = self.bodyPtr(body_a) orelse return error.InvalidBody;
        const b2 = self.bodyPtr(body_b) orelse return error.InvalidBody;
        var s: c.JPH_HingeConstraintSettings = undefined;
        c.JPH_HingeConstraintSettings_Init(&s);
        const ax = normalized(axis);
        const nrm = perpendicular(ax);
        const p = c.JPH_RVec3{ .x = anchor[0], .y = anchor[1], .z = anchor[2] };
        s.space = c.JPH_ConstraintSpace_WorldSpace;
        s.point1 = p;
        s.point2 = p;
        s.hingeAxis1 = ax;
        s.hingeAxis2 = ax;
        s.normalAxis1 = nrm;
        s.normalAxis2 = nrm;
        s.limitsMin = limit_min;
        s.limitsMax = limit_max;
        const con = c.JPH_HingeConstraint_Create(&s, b1, b2) orelse return error.ConstraintCreationFailed;
        return self.registerConstraint(@ptrCast(con));
    }

    /// Creates a ball-and-socket joint (ragdoll limb / hitch) pinning both bodies at a world-space anchor.
    pub fn createBallSocketConstraint(self: *PhysicsWorld, body_a: u32, body_b: u32, anchor: [3]f32) !u32 {
        const b1 = self.bodyPtr(body_a) orelse return error.InvalidBody;
        const b2 = self.bodyPtr(body_b) orelse return error.InvalidBody;
        var s: c.JPH_PointConstraintSettings = undefined;
        c.JPH_PointConstraintSettings_Init(&s);
        const p = c.JPH_RVec3{ .x = anchor[0], .y = anchor[1], .z = anchor[2] };
        s.space = c.JPH_ConstraintSpace_WorldSpace;
        s.point1 = p;
        s.point2 = p;
        const con = c.JPH_PointConstraint_Create(&s, b1, b2) orelse return error.ConstraintCreationFailed;
        return self.registerConstraint(@ptrCast(con));
    }

    /// Creates a slider (piston / elevator) along a world-space axis, with travel limits (meters).
    pub fn createSliderConstraint(self: *PhysicsWorld, body_a: u32, body_b: u32, axis: [3]f32, limit_min: f32, limit_max: f32) !u32 {
        const b1 = self.bodyPtr(body_a) orelse return error.InvalidBody;
        const b2 = self.bodyPtr(body_b) orelse return error.InvalidBody;
        var s: c.JPH_SliderConstraintSettings = undefined;
        c.JPH_SliderConstraintSettings_Init(&s);
        s.space = c.JPH_ConstraintSpace_WorldSpace;
        s.autoDetectPoint = true;
        const ax = normalized(axis);
        c.JPH_SliderConstraintSettings_SetSliderAxis(&s, &ax);
        s.limitsMin = limit_min;
        s.limitsMax = limit_max;
        const con = c.JPH_SliderConstraint_Create(&s, b1, b2) orelse return error.ConstraintCreationFailed;
        return self.registerConstraint(@ptrCast(con));
    }

    /// Rigidly welds two bodies together at their current relative pose.
    pub fn createWeldConstraint(self: *PhysicsWorld, body_a: u32, body_b: u32) !u32 {
        const b1 = self.bodyPtr(body_a) orelse return error.InvalidBody;
        const b2 = self.bodyPtr(body_b) orelse return error.InvalidBody;
        var s: c.JPH_FixedConstraintSettings = undefined;
        c.JPH_FixedConstraintSettings_Init(&s);
        s.space = c.JPH_ConstraintSpace_WorldSpace;
        s.autoDetectPoint = true;
        const con = c.JPH_FixedConstraint_Create(&s, b1, b2) orelse return error.ConstraintCreationFailed;
        return self.registerConstraint(@ptrCast(con));
    }

    pub fn destroyConstraint(self: *PhysicsWorld, id: u32) void {
        if (id == 0 or id > MAX_CONSTRAINTS) return;
        const con = self.constraints[id - 1] orelse return;
        c.JPH_PhysicsSystem_RemoveConstraint(self.system, con);
        c.JPH_Constraint_Destroy(con);
        self.constraints[id - 1] = null;
    }

    pub fn isConstraintValid(self: *PhysicsWorld, id: u32) bool {
        if (id == 0 or id > MAX_CONSTRAINTS) return false;
        return self.constraints[id - 1] != null;
    }
};

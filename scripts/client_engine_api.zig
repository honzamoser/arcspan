//! WebAssembly Guest SDK for the Game Engine
//! Provides typed views over imported shared memory for zero-overhead direct reads,
//! semantic action mapping, scene graph transforms, Jolt-compatible physics descriptors,
//! and an outbox queue for state mutation intents.

const std = @import("std");

// -------------------------------------------------------------------------------------------------
// 1. Authoritative State Layout (C ABI Compatible)
// -------------------------------------------------------------------------------------------------

pub const Vec3 = extern struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    z: f32 = 0.0,

    pub inline fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub inline fn add(self: Vec3, other: Vec3) Vec3 {
        return .{ .x = self.x + other.x, .y = self.y + other.y, .z = self.z + other.z };
    }

    pub inline fn sub(self: Vec3, other: Vec3) Vec3 {
        return .{ .x = self.x - other.x, .y = self.y - other.y, .z = self.z - other.z };
    }

    pub inline fn scale(self: Vec3, s: f32) Vec3 {
        return .{ .x = self.x * s, .y = self.y * s, .z = self.z * s };
    }

    pub inline fn mul(self: Vec3, other: Vec3) Vec3 {
        return .{ .x = self.x * other.x, .y = self.y * other.y, .z = self.z * other.z };
    }

    pub inline fn lengthSq(self: Vec3) f32 {
        return self.x * self.x + self.y * self.y + self.z * self.z;
    }

    pub inline fn length(self: Vec3) f32 {
        return @sqrt(self.lengthSq());
    }

    pub inline fn distance(self: Vec3, other: Vec3) f32 {
        return self.sub(other).length();
    }
};

pub const Vec4 = extern struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    z: f32 = 0.0,
    w: f32 = 1.0,

    pub inline fn init(x: f32, y: f32, z: f32, w: f32) Vec4 {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }
};

pub const NO_PARENT: u64 = 0xFFFF_FFFF_FFFF_FFFF;

pub const ComponentMask = struct {
    pub const ACTIVE: u32 = 1 << 0;
    pub const TRANSFORM: u32 = 1 << 1;
    pub const RIGID_BODY: u32 = 1 << 2;
    pub const COLLIDER: u32 = 1 << 3;
    pub const RENDERABLE: u32 = 1 << 4;
    pub const SCRIPTED: u32 = 1 << 5;
};

pub const ColliderType = enum(u32) {
    none = 0,
    box = 1,
    sphere = 2,
    capsule = 3,
};

pub const MotionType = enum(u32) {
    dynamic = 0,
    kinematic = 1,
    static = 2,
};

pub const PrimitiveType = enum(u32) {
    cube = 0,
    sphere = 1,
    pyramid = 2,
    cylinder = 3,
    plane = 4,
};

pub const ShadingModel = enum(u32) {
    pbr = 0,
    unlit = 1,
    blinn_phong = 2,
};

pub const ActionId = enum(u5) {
    move_forward = 0,
    move_backward = 1,
    move_left = 2,
    move_right = 3,
    jump = 4,
    sprint = 5,
    crouch = 6,
    interact = 7,
    primary_fire = 8,
    secondary_fire = 9,
    pause = 10,
    reload = 11,
    custom0 = 12,
    custom1 = 13,
    custom2 = 14,
    custom3 = 15,
};

pub const AxisId = enum(u3) {
    move_x = 0,
    move_y = 1,
    look_x = 2,
    look_y = 3,
    trigger_left = 4,
    trigger_right = 5,
    wheel = 6,
    custom0 = 7,
};

pub const MAX_AXES: u32 = 8;

pub const InputStateShared = extern struct {
    actions_down: u32 = 0,
    actions_pressed: u32 = 0,
    actions_released: u32 = 0,
    _pad0: u32 = 0,
    axes: [MAX_AXES]f32 = [_]f32{0.0} ** MAX_AXES,
    mouse_x: f32 = 0.0,
    mouse_y: f32 = 0.0,
    mouse_dx: f32 = 0.0,
    mouse_dy: f32 = 0.0,
    mouse_wheel: f32 = 0.0,
    _pad1: f32 = 0.0,

    pub inline fn isActionDown(self: *const InputStateShared, action: ActionId) bool {
        const mask = @as(u32, 1) << @intFromEnum(action);
        return (self.actions_down & mask) != 0;
    }

    pub inline fn isActionPressed(self: *const InputStateShared, action: ActionId) bool {
        const mask = @as(u32, 1) << @intFromEnum(action);
        return (self.actions_pressed & mask) != 0;
    }

    pub inline fn getAxis(self: *const InputStateShared, axis: AxisId) f32 {
        const idx = @intFromEnum(axis);
        if (idx < MAX_AXES) return self.axes[idx];
        return 0.0;
    }
};

pub const MAX_SHARED_EVENTS: u32 = 16;

pub const GameEvent = extern struct {
    event_type: u32 = 0,
    _pad0: u32 = 0,
    source_id: u64 = 0,
    target_id: u64 = 0,
    data: [4]f32 = [_]f32{ 0.0, 0.0, 0.0, 0.0 },
    tag: [16]u8 = [_]u8{0} ** 16,

    pub inline fn getTag(self: *const GameEvent) []const u8 {
        var len: usize = 0;
        while (len < 16 and self.tag[len] != 0) : (len += 1) {}
        return self.tag[0..len];
    }
};

pub const EventQueueShared = extern struct {
    events: [MAX_SHARED_EVENTS]GameEvent = [_]GameEvent{.{}} ** MAX_SHARED_EVENTS,
    count: u32 = 0,
    _pad: [3]u32 = [_]u32{0} ** 3,
};

pub const PlayerData = extern struct {
    id: u32 = 0,
    active: u32 = 0,
    position: Vec3 = .{},
    velocity: Vec3 = .{},
    rotation: Vec3 = .{},
    health: f32 = 100.0,
    max_health: f32 = 100.0,
    flags: u32 = 0,
};

pub const EntityData = extern struct {
    id: u64 = 0,
    active: u32 = 0,
    _pad0: u32 = 0,
    parent_id: u64 = NO_PARENT,
    component_mask: u32 = ComponentMask.ACTIVE | ComponentMask.TRANSFORM,
    entity_type: u32 = 0,
    shading_model: u32 = 0, // 0 = PBR, 1 = Unlit, 2 = Blinn-Phong
    _pad1: f32 = 0,

    // World Transforms (authoritative)
    position: Vec3 = .{},
    _pad2: f32 = 0,
    rotation: Vec3 = .{},
    _pad3: f32 = 0,
    scale: Vec3 = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
    _pad4: f32 = 0,

    // Local Hierarchy Transforms (relative to parent_id)
    local_position: Vec3 = .{},
    _pad5: f32 = 0,
    local_rotation: Vec3 = .{},
    _pad6: f32 = 0,
    local_scale: Vec3 = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
    _pad7: f32 = 0,

    // Dynamics (compatible with Jolt Physics)
    velocity: Vec3 = .{},
    mass: f32 = 1.0,
    angular_velocity: Vec3 = .{},
    motion_type: MotionType = .dynamic,

    // Colliders (compatible with Jolt ShapeSettings)
    collider_type: ColliderType = .none,
    collider_extents: Vec3 = .{ .x = 0.5, .y = 0.5, .z = 0.5 },

    // Visuals & Tagging
    color: [4]f32 = [_]f32{ 1.0, 1.0, 1.0, 1.0 },
    tag: [16]u8 = [_]u8{0} ** 16,
    layer: u32 = 0,
    metallic: f32 = 0.0,
    roughness: f32 = 0.5,
    emissive: f32 = 0.0,
    _pad8: [2]u32 = [_]u32{0} ** 2,
};

pub const SceneState = extern struct {
    rotation_x: f32 = 0.0,
    rotation_y: f32 = 0.0,
    camera_distance: f32 = 3.5,
    cube_face_colors: [6][4]f32 = [6][4]f32{
        [_]f32{ 0.95, 0.26, 0.21, 1.0 },
        [_]f32{ 0.13, 0.59, 0.95, 1.0 },
        [_]f32{ 0.30, 0.69, 0.31, 1.0 },
        [_]f32{ 1.00, 0.76, 0.03, 1.0 },
        [_]f32{ 0.61, 0.15, 0.69, 1.0 },
        [_]f32{ 1.00, 0.60, 0.00, 1.0 },
    },
};

pub const WorldHeader = extern struct {
    magic: u32 = 0x574F524C,
    version: u32 = 2,
    tick: u64 = 0,
    time: f32 = 0.0,
    delta_time: f32 = 0.0,
    player_count: u32 = 0,
    max_players: u32 = MAX_PLAYERS,
    entity_count: u32 = 0,
    max_entities: u32 = MAX_ENTITIES,
};

pub const MAX_PLAYERS: u32 = 32;
pub const MAX_ENTITIES: u32 = 2048;

pub const GameState = extern struct {
    header: WorldHeader = .{},
    scene: SceneState = .{},
    input: InputStateShared = .{},
    events: EventQueueShared = .{},
    players: [MAX_PLAYERS]PlayerData = [_]PlayerData{.{}} ** MAX_PLAYERS,
    entities: [MAX_ENTITIES]EntityData = [_]EntityData{.{}} ** MAX_ENTITIES,
};

// -------------------------------------------------------------------------------------------------
// 2. Shared Memory Buffer exported to / imported from host
// -------------------------------------------------------------------------------------------------
const MEM_SIZE = 1048576 * 16;
pub export var shared_memory_buffer: [MEM_SIZE]u8 align(4096) = [_]u8{0} ** MEM_SIZE;

pub export fn get_shared_buffer_ptr() [*]const u8 {
    return &shared_memory_buffer;
}

pub export fn get_shared_buffer_len() u32 {
    return MEM_SIZE;
}

pub inline fn getSharedState() *const GameState {
    return @ptrCast(@alignCast(&shared_memory_buffer));
}

pub inline fn getSharedStateMut() *GameState {
    return @ptrCast(@alignCast(&shared_memory_buffer));
}

// -------------------------------------------------------------------------------------------------
// 3. Guest SDK Typed Views (Zero-overhead direct memory reads & in-place writes)
// -------------------------------------------------------------------------------------------------

pub const PlayerView = struct {
    data: *const PlayerData,

    pub inline fn getId(self: PlayerView) u32 {
        return self.data.id;
    }
    pub inline fn isActive(self: PlayerView) bool {
        return self.data.active != 0;
    }
    pub inline fn getPosition(self: PlayerView) Vec3 {
        return self.data.position;
    }
    pub inline fn getVelocity(self: PlayerView) Vec3 {
        return self.data.velocity;
    }
    pub inline fn getRotation(self: PlayerView) Vec3 {
        return self.data.rotation;
    }
    pub inline fn getHealth(self: PlayerView) f32 {
        return self.data.health;
    }
    pub inline fn getMaxHealth(self: PlayerView) f32 {
        return self.data.max_health;
    }
};

pub const EntityView = struct {
    data: *const EntityData,

    pub inline fn getId(self: EntityView) u64 {
        return self.data.id;
    }
    pub inline fn isActive(self: EntityView) bool {
        return self.data.active != 0;
    }
    pub inline fn getType(self: EntityView) u32 {
        return self.data.entity_type;
    }
    pub inline fn getParentId(self: EntityView) u64 {
        return self.data.parent_id;
    }
    pub inline fn hasParent(self: EntityView) bool {
        return self.data.parent_id != NO_PARENT;
    }

    // World Transforms
    pub inline fn getPosition(self: EntityView) Vec3 {
        return self.data.position;
    }
    pub inline fn getWorldPosition(self: EntityView) Vec3 {
        return self.data.position;
    }
    pub inline fn getRotation(self: EntityView) Vec3 {
        return self.data.rotation;
    }
    pub inline fn getWorldRotation(self: EntityView) Vec3 {
        return self.data.rotation;
    }
    pub inline fn getScale(self: EntityView) Vec3 {
        return self.data.scale;
    }
    pub inline fn getWorldScale(self: EntityView) Vec3 {
        return self.data.scale;
    }

    // Local Transforms
    pub inline fn getLocalPosition(self: EntityView) Vec3 {
        return self.data.local_position;
    }
    pub inline fn getLocalRotation(self: EntityView) Vec3 {
        return self.data.local_rotation;
    }
    pub inline fn getLocalScale(self: EntityView) Vec3 {
        return self.data.local_scale;
    }

    // Physics & Collisions
    pub inline fn getVelocity(self: EntityView) Vec3 {
        return self.data.velocity;
    }
    pub inline fn getAngularVelocity(self: EntityView) Vec3 {
        return self.data.angular_velocity;
    }
    pub inline fn getMass(self: EntityView) f32 {
        return self.data.mass;
    }
    pub inline fn getMotionType(self: EntityView) MotionType {
        return self.data.motion_type;
    }
    pub inline fn isDynamic(self: EntityView) bool {
        return self.data.motion_type == .dynamic;
    }
    pub inline fn isKinematic(self: EntityView) bool {
        return self.data.motion_type == .kinematic;
    }
    pub inline fn isStatic(self: EntityView) bool {
        return self.data.motion_type == .static;
    }
    pub inline fn getColliderType(self: EntityView) ColliderType {
        return self.data.collider_type;
    }
    pub inline fn getColliderExtents(self: EntityView) Vec3 {
        return self.data.collider_extents;
    }

    // Visuals & Tagging
    pub inline fn getColor(self: EntityView) [4]f32 {
        return self.data.color;
    }
    pub inline fn getMetallic(self: EntityView) f32 {
        return self.data.metallic;
    }
    pub inline fn getRoughness(self: EntityView) f32 {
        return self.data.roughness;
    }
    pub inline fn getEmissive(self: EntityView) f32 {
        return self.data.emissive;
    }
    pub inline fn getShadingModel(self: EntityView) u32 {
        return self.data.shading_model;
    }
    pub inline fn getTag(self: EntityView) []const u8 {
        var len: usize = 0;
        while (len < 16 and self.data.tag[len] != 0) : (len += 1) {}
        return self.data.tag[0..len];
    }
    pub inline fn hasTag(self: EntityView, match_tag: []const u8) bool {
        return std.mem.eql(u8, self.getTag(), match_tag);
    }

    // Convenience In-Place Mutations
    pub inline fn setLocalPosition(self: EntityView, pos: Vec3) void {
        setEntityLocalPosition(self.data.id, pos);
    }
    pub inline fn setLocalRotation(self: EntityView, rot: Vec3) void {
        setEntityLocalRotation(self.data.id, rot);
    }
    pub inline fn setLocalScale(self: EntityView, scale: Vec3) void {
        setEntityLocalScale(self.data.id, scale);
    }
    pub inline fn setParent(self: EntityView, parent_id: u64) void {
        setEntityParent(self.data.id, parent_id);
    }
    pub inline fn applyImpulse(self: EntityView, impulse: Vec3) void {
        applyEntityImpulse(self.data.id, impulse);
    }
    pub inline fn setCollider(self: EntityView, col_type: ColliderType, extents: Vec3) void {
        setEntityCollider(self.data.id, col_type, extents);
    }
    pub inline fn setMaterial(self: EntityView, metallic: f32, roughness: f32, emissive: f32, shading_model: u32) void {
        setEntityMaterial(self.data.id, metallic, roughness, emissive, shading_model);
    }
    pub inline fn setColor(self: EntityView, color: [4]f32) void {
        setEntityColor(self.data.id, color);
    }
    pub inline fn setTag(self: EntityView, tag_str: []const u8) void {
        setEntityTag(self.data.id, tag_str);
    }
    pub inline fn despawn(self: EntityView) void {
        despawnEntity(self.data.id);
    }

    // Dynamic Flecs ECS component operations
    pub inline fn setEcs(self: EntityView, comp_id: u64, val: anytype) bool {
        return ecs.set(self.data.id, comp_id, val);
    }
    pub inline fn getEcs(self: EntityView, comp_id: u64, comptime T: type) ?T {
        return ecs.get(self.data.id, comp_id, T);
    }
    pub inline fn hasEcs(self: EntityView, comp_id: u64) bool {
        return ecs.has(self.data.id, comp_id);
    }
    pub inline fn removeEcs(self: EntityView, comp_id: u64) bool {
        return ecs.remove(self.data.id, comp_id);
    }
};

pub const SceneView = struct {
    data: *const SceneState,

    pub inline fn getRotationX(self: SceneView) f32 {
        return self.data.rotation_x;
    }
    pub inline fn getRotationY(self: SceneView) f32 {
        return self.data.rotation_y;
    }
    pub inline fn getCameraDistance(self: SceneView) f32 {
        return self.data.camera_distance;
    }
    pub inline fn getFaceColor(self: SceneView, face: u32) [4]f32 {
        if (face < 6) {
            return self.data.cube_face_colors[face];
        }
        return [_]f32{ 0.0, 0.0, 0.0, 1.0 };
    }
};

pub const World = struct {
    state: *const GameState,

    pub inline fn init() World {
        return .{ .state = getSharedState() };
    }

    pub inline fn getPlayer(self: World, id: u32) ?PlayerView {
        if (id < MAX_PLAYERS and self.state.players[id].active != 0) {
            return PlayerView{ .data = &self.state.players[id] };
        }
        return null;
    }

    pub inline fn getEntity(self: World, id: u64) ?EntityView {
        if (id < MAX_ENTITIES) {
            return EntityView{ .data = &self.state.entities[@intCast(id)] };
        }
        return null;
    }

    pub inline fn findEntityByTag(self: World, match_tag: []const u8) ?EntityView {
        for (&self.state.entities) |*ent| {
            if (ent.active != 0) {
                const view = EntityView{ .data = ent };
                if (view.hasTag(match_tag)) return view;
            }
        }
        return null;
    }

    pub inline fn getScene(self: World) SceneView {
        return SceneView{ .data = &self.state.scene };
    }

    pub inline fn getInput(self: World) *const InputStateShared {
        return &self.state.input;
    }

    pub inline fn getEvents(self: World) []const GameEvent {
        return self.state.events.events[0..self.state.events.count];
    }

    pub inline fn getTick(self: World) u64 {
        return self.state.header.tick;
    }
    pub inline fn getTime(self: World) f32 {
        return self.state.header.time;
    }
    pub inline fn getDeltaTime(self: World) f32 {
        return self.state.header.delta_time;
    }
    pub inline fn getPlayerCount(self: World) u32 {
        return self.state.header.player_count;
    }
    pub inline fn getEntityCount(self: World) u32 {
        return self.state.header.entity_count;
    }
};

pub inline fn getWorld() World {
    return World.init();
}

// -------------------------------------------------------------------------------------------------
// 4. Hybrid In-Place Shared Memory Writes & Synchronous Lifecycle Host Calls
// -------------------------------------------------------------------------------------------------

extern "engine" fn engine_apply_impulse(id: u64, x: f32, y: f32, z: f32) void;
extern "engine" fn engine_set_player_velocity(id: u32, x: f32, y: f32, z: f32) void;
extern "engine" fn engine_teleport_player(id: u32, x: f32, y: f32, z: f32) void;
extern "engine" fn engine_spawn_entity(entity_type: u32, x: f32, y: f32, z: f32, r: f32, g: f32, b: f32, a: f32) u64;
extern "engine" fn engine_despawn_entity(id: u64) void;
extern "engine" fn engine_rotate(dx: f32, dy: f32) void;
extern "engine" fn engine_set_scene_rotation(rx: f32, ry: f32) void;
extern "engine" fn engine_set_camera_distance(val: f32) void;
extern "engine" fn engine_set_cube_color(face_index: u32, r: f32, g: f32, b: f32) void;
extern "engine" fn engine_log(ptr: [*]const u8, len: u32) void;

// Scene Graph & ECS Host Imports
extern "engine" fn engine_set_entity_local_pos(id: u64, x: f32, y: f32, z: f32) void;
extern "engine" fn engine_set_entity_local_rot(id: u64, rx: f32, ry: f32, rz: f32) void;
extern "engine" fn engine_set_entity_local_scale(id: u64, sx: f32, sy: f32, sz: f32) void;
extern "engine" fn engine_set_entity_parent(child_id: u64, parent_id: u64) void;
extern "engine" fn engine_set_entity_collider(id: u64, col_type: u32, ex: f32, ey: f32, ez: f32) void;
extern "engine" fn engine_set_entity_tag(id: u64, tag_ptr: [*]const u8, tag_len: u32) void;
extern "engine" fn engine_set_entity_motion_type(id: u64, motion_type: u32) void;
extern "engine" fn engine_set_entity_material(id: u64, metallic: f32, roughness: f32, emissive: f32, shading_model: u32) void;
extern "engine" fn engine_set_entity_color(id: u64, r: f32, g: f32, b: f32, a: f32) void;
extern "engine" fn engine_emit_event(ev_type: u32, src_id: u64, tgt_id: u64, d0: f32, d1: f32, d2: f32, d3: f32, tag_ptr: [*]const u8, tag_len: u32) void;

// Semantic Action Queries (Host fallback)
extern "engine" fn engine_is_action_down(action_id: u32) u32;
extern "engine" fn engine_is_action_pressed(action_id: u32) u32;
extern "engine" fn engine_get_axis(axis_id: u32) f32;

// Legacy fallback host function imports
extern "engine" fn engine_get_time() f32;
extern "engine" fn engine_get_delta_time() f32;
extern "engine" fn engine_get_rotation_x() f32;
extern "engine" fn engine_set_rotation_x(val: f32) void;
extern "engine" fn engine_get_rotation_y() f32;
extern "engine" fn engine_set_rotation_y(val: f32) void;
extern "engine" fn engine_get_camera_distance() f32;
extern "engine" fn engine_is_key_down(scancode: u32) u32;
extern "engine" fn engine_is_mouse_button_down(button: u32) u32;
extern "engine" fn engine_sin(val: f32) f32;
extern "engine" fn engine_cos(val: f32) f32;

// Jolt Physics Subsystem Host Imports
extern "engine" fn engine_physics_create_body(entity_id: u64, shape_type: u32, x: f32, y: f32, z: f32, is_dynamic: u32) u32;
extern "engine" fn engine_physics_apply_impulse(body_id: u32, x: f32, y: f32, z: f32) void;
extern "engine" fn engine_physics_get_pos_x(body_id: u32) f32;
extern "engine" fn engine_physics_get_pos_y(body_id: u32) f32;
extern "engine" fn engine_physics_get_pos_z(body_id: u32) f32;
extern "engine" fn engine_physics_get_vel_y(body_id: u32) f32;
extern "engine" fn engine_physics_is_active(body_id: u32) u32;

// Camera Subsystem Host Imports
extern "engine" fn engine_camera_set_pos(x: f32, y: f32, z: f32) void;
extern "engine" fn engine_camera_set_rot(yaw: f32, pitch: f32) void;
extern "engine" fn engine_camera_set_fov(fov_deg: f32) void;
extern "engine" fn engine_camera_get_pos_x() f32;
extern "engine" fn engine_camera_get_pos_y() f32;
extern "engine" fn engine_camera_get_pos_z() f32;
extern "engine" fn engine_camera_get_yaw() f32;
extern "engine" fn engine_camera_get_pitch() f32;
extern "engine" fn engine_camera_screen_to_ray(sx: f32, sy: f32, sw: f32, sh: f32) u32;
extern "engine" fn engine_camera_get_ray_origin_x() f32;
extern "engine" fn engine_camera_get_ray_origin_y() f32;
extern "engine" fn engine_camera_get_ray_origin_z() f32;
extern "engine" fn engine_camera_get_ray_dir_x() f32;
extern "engine" fn engine_camera_get_ray_dir_y() f32;
extern "engine" fn engine_camera_get_ray_dir_z() f32;

// Physics Raycasting & Shapecast Host Imports
extern "engine" fn engine_physics_cast_ray(ox: f32, oy: f32, oz: f32, dx: f32, dy: f32, dz: f32, out_pointer: *physics.RaycastHit_Host) u32;
extern "engine" fn engine_physics_cast_sphere(radius: f32, ox: f32, oy: f32, oz: f32, dx: f32, dy: f32, dz: f32, layer_mask: u32, out_pointer: *physics.ShapeCastHit_Host) u32;
extern "engine" fn engine_physics_cast_box(hx: f32, hy: f32, hz: f32, ox: f32, oy: f32, oz: f32, dx: f32, dy: f32, dz: f32, layer_mask: u32, out_pointer: *physics.ShapeCastHit_Host) u32;
extern "engine" fn engine_physics_set_collision_layer(body_id: u32, layer: u32) void;
extern "engine" fn engine_physics_set_layer_collision(a: u32, b: u32, enabled: u32) void;

// Character Controller Host Imports
extern "engine" fn engine_character_create(x: f32, y: f32, z: f32, half_height: f32, radius: f32) u32;
extern "engine" fn engine_character_destroy(id: u32) void;
extern "engine" fn engine_character_set_linear_velocity(id: u32, vx: f32, vy: f32, vz: f32) void;
extern "engine" fn engine_character_set_position(id: u32, x: f32, y: f32, z: f32) void;
extern "engine" fn engine_character_get_ground_state(id: u32) u32;
extern "engine" fn engine_character_get_pos_x(id: u32) f32;
extern "engine" fn engine_character_get_pos_y(id: u32) f32;
extern "engine" fn engine_character_get_pos_z(id: u32) f32;
extern "engine" fn engine_character_get_vel_y(id: u32) f32;

// Physics Constraint Host Imports
extern "engine" fn engine_constraint_create_hinge(body_a: u32, body_b: u32, px: f32, py: f32, pz: f32, ax: f32, ay: f32, az: f32, limit_min: f32, limit_max: f32) u32;
extern "engine" fn engine_constraint_create_ball_socket(body_a: u32, body_b: u32, px: f32, py: f32, pz: f32) u32;
extern "engine" fn engine_constraint_create_slider(body_a: u32, body_b: u32, ax: f32, ay: f32, az: f32, limit_min: f32, limit_max: f32) u32;
extern "engine" fn engine_constraint_create_weld(body_a: u32, body_b: u32) u32;
extern "engine" fn engine_constraint_destroy(id: u32) void;

// 2D UI Overlay Host Imports
extern "engine" fn engine_ui_draw_rect(x: f32, y: f32, w: f32, h: f32, r: f32, g: f32, b: f32, a: f32) void;
extern "engine" fn engine_ui_draw_rect_border(x: f32, y: f32, w: f32, h: f32, thickness: f32, r: f32, g: f32, b: f32, a: f32) void;
extern "engine" fn engine_ui_draw_crosshair(cx: f32, cy: f32, size: f32, thickness: f32, r: f32, g: f32, b: f32, a: f32) void;
extern "engine" fn engine_ui_draw_progress_bar(x: f32, y: f32, w: f32, h: f32, frac: f32, fr: f32, fg: f32, fb: f32, fa: f32, br: f32, bg: f32, bb: f32, ba: f32) void;
extern "engine" fn engine_ui_draw_selection_box(x1: f32, y1: f32, x2: f32, y2: f32, fr: f32, fg: f32, fb: f32, fa: f32, br: f32, bg: f32, bb: f32, ba: f32) void;
extern "engine" fn engine_ui_draw_text(text_ptr: [*]const u8, text_len: usize, x: f32, y: f32, font_size: f32, r: f32, g: f32, b: f32, a: f32) void;

// Audio Subsystem Host Imports
extern "engine" fn engine_audio_play_tone(freq: f32, duration: f32, vol: f32) void;
extern "engine" fn engine_audio_play_impact(vol: f32) void;
extern "engine" fn engine_audio_play_chime(vol: f32) void;

// Window / Platform Host Imports
extern "engine" fn engine_window_set_relative_mouse(enabled: u32) u32;
extern "engine" fn engine_window_get_screen_w() f32;
extern "engine" fn engine_window_get_screen_h() f32;

// Particle Host Import
extern "engine" fn engine_particle_spawn_burst(x: f32, y: f32, z: f32, count: u32, speed: f32, r: f32, g: f32, b: f32, a: f32, size: f32, lifetime: f32) void;

// Networking Host Imports
extern "engine" fn engine_net_fire_server(name_ptr: [*]const u8, name_len: usize, data_ptr: [*]const u8, data_len: usize) void;
extern "engine" fn engine_net_fire_client(client_id: u32, name_ptr: [*]const u8, name_len: usize, data_ptr: [*]const u8, data_len: usize) void;
extern "engine" fn engine_net_fire_all_clients(name_ptr: [*]const u8, name_len: usize, data_ptr: [*]const u8, data_len: usize) void;
extern "engine" fn engine_net_poll_event(name_buf: [*]u8, max_name_len: usize, data_buf: [*]u8, max_data_len: usize, out_sender_id: *u32) u32;
extern "engine" fn engine_net_get_rtt() f32;
extern "engine" fn engine_net_is_connected() u32;
extern "engine" fn engine_net_get_client_id() u32;

// Task Scheduler Host Imports
const is_wasm = @import("builtin").cpu.arch == .wasm32;
const task_imports = if (is_wasm) struct {
    extern "engine" fn engine_task_wait(slot_id: u32, seconds: f32) f32;
    extern "engine" fn engine_task_cancel(task_id: u32) i32;
} else struct {
    fn engine_task_wait(slot_id: u32, seconds: f32) f32 {
        _ = slot_id;
        _ = seconds;
        return 0.0;
    }
    fn engine_task_cancel(task_id: u32) i32 {
        _ = task_id;
        return 1;
    }
};

// Custom Zig ECS Host Imports (1:1 Unified Entity IDs)
const ecs_imports = if (is_wasm) struct {
    extern "engine" fn engine_ecs_register_component(name_ptr: [*]const u8, name_len: u32, size: u32, align_val: u32) u64;
    extern "engine" fn engine_ecs_get_component_id(name_ptr: [*]const u8, name_len: u32) u64;
    extern "engine" fn engine_ecs_get_builtin_component(builtin_type: u32) u64;
    extern "engine" fn engine_ecs_new_entity(name_ptr: ?[*]const u8, name_len: u32) u64;
    extern "engine" fn engine_ecs_delete_entity(entity_id: u64) i32;
    extern "engine" fn engine_ecs_is_alive(entity_id: u64) i32;
    extern "engine" fn engine_ecs_set_component(entity_id: u64, comp_id: u64, data_ptr: [*]const u8, data_len: u32) i32;
    extern "engine" fn engine_ecs_get_component(entity_id: u64, comp_id: u64, out_ptr: [*]u8, max_len: u32) i32;
    extern "engine" fn engine_ecs_has_component(entity_id: u64, comp_id: u64) i32;
    extern "engine" fn engine_ecs_remove_component(entity_id: u64, comp_id: u64) i32;
    extern "engine" fn engine_ecs_query_entities(comp_ids_ptr: [*]const u64, comp_count: u32, out_entities_ptr: [*]u64, max_entities: u32) u32;
    extern "engine" fn engine_ecs_query_count(comp_ids_ptr: [*]const u64, comp_count: u32) u32;
    extern "engine" fn engine_ecs_register_system(name_ptr: [*]const u8, name_len: u32, comp_ids_ptr: [*]const u64, comp_count: u32) u32;
    extern "engine" fn engine_ecs_set_system_enabled(sys_id: u32, enabled: u32) i32;
} else struct {
    fn engine_ecs_register_component(name_ptr: [*]const u8, name_len: u32, size: u32, align_val: u32) u64 {
        _ = name_ptr;
        _ = name_len;
        _ = size;
        _ = align_val;
        return 1;
    }
    fn engine_ecs_get_component_id(name_ptr: [*]const u8, name_len: u32) u64 {
        _ = name_ptr;
        _ = name_len;
        return 0;
    }
    fn engine_ecs_get_builtin_component(builtin_type: u32) u64 {
        _ = builtin_type;
        return 1;
    }
    fn engine_ecs_new_entity(name_ptr: ?[*]const u8, name_len: u32) u64 {
        _ = name_ptr;
        _ = name_len;
        return 1;
    }
    fn engine_ecs_delete_entity(entity_id: u64) i32 {
        _ = entity_id;
        return 1;
    }
    fn engine_ecs_is_alive(entity_id: u64) i32 {
        _ = entity_id;
        return 1;
    }
    fn engine_ecs_set_component(entity_id: u64, comp_id: u64, data_ptr: [*]const u8, data_len: u32) i32 {
        _ = entity_id;
        _ = comp_id;
        _ = data_ptr;
        _ = data_len;
        return 1;
    }
    fn engine_ecs_get_component(entity_id: u64, comp_id: u64, out_ptr: [*]u8, max_len: u32) i32 {
        _ = entity_id;
        _ = comp_id;
        _ = out_ptr;
        _ = max_len;
        return 0;
    }
    fn engine_ecs_has_component(entity_id: u64, comp_id: u64) i32 {
        _ = entity_id;
        _ = comp_id;
        return 1;
    }
    fn engine_ecs_remove_component(entity_id: u64, comp_id: u64) i32 {
        _ = entity_id;
        _ = comp_id;
        return 1;
    }
    fn engine_ecs_query_entities(comp_ids_ptr: [*]const u64, comp_count: u32, out_entities_ptr: [*]u64, max_entities: u32) u32 {
        _ = comp_ids_ptr;
        _ = comp_count;
        _ = out_entities_ptr;
        _ = max_entities;
        return 0;
    }
    fn engine_ecs_query_count(comp_ids_ptr: [*]const u64, comp_count: u32) u32 {
        _ = comp_ids_ptr;
        _ = comp_count;
        return 0;
    }
    fn engine_ecs_register_system(name_ptr: [*]const u8, name_len: u32, comp_ids_ptr: [*]const u64, comp_count: u32) u32 {
        _ = name_ptr;
        _ = name_len;
        _ = comp_ids_ptr;
        _ = comp_count;
        return 1;
    }
    fn engine_ecs_set_system_enabled(sys_id: u32, enabled: u32) i32 {
        _ = sys_id;
        _ = enabled;
        return 1;
    }
};

const MAX_IMPULSE_MAGNITUDE_SQ: f32 = 10000.0;
const MAX_VELOCITY_MAGNITUDE_SQ: f32 = 2500.0;
const BOUND_LIMIT: f32 = 1000.0;

inline fn isFiniteVec3(v: Vec3) bool {
    return std.math.isFinite(v.x) and std.math.isFinite(v.y) and std.math.isFinite(v.z);
}

inline fn resolveEntityTransformInPlace(state: *GameState, id: u64) void {
    if (id >= MAX_ENTITIES) return;
    const ent = &state.entities[@intCast(id)];
    if (ent.active == 0) return;

    const pid = ent.parent_id;
    if (pid == NO_PARENT or pid >= MAX_ENTITIES or state.entities[@intCast(pid)].active == 0) {
        ent.position = ent.local_position;
        ent.rotation = ent.local_rotation;
        ent.scale = ent.local_scale;
    } else {
        const parent = &state.entities[@intCast(pid)];
        ent.scale = parent.scale.mul(ent.local_scale);
        ent.rotation = parent.rotation.add(ent.local_rotation);
        ent.position = parent.position.add(ent.local_position.mul(parent.scale));
    }
}

pub fn applyImpulse(player_id: u32, impulse: Vec3) void {
    if (!isFiniteVec3(impulse) or impulse.lengthSq() > MAX_IMPULSE_MAGNITUDE_SQ) return;
    const state = getSharedStateMut();
    if (player_id < MAX_PLAYERS and state.players[player_id].active != 0) {
        state.players[player_id].velocity = state.players[player_id].velocity.add(impulse);
    } else if (player_id < MAX_ENTITIES and state.entities[player_id].active != 0) {
        state.entities[player_id].velocity = state.entities[player_id].velocity.add(impulse);
    }
}

pub fn applyEntityImpulse(entity_id: u64, impulse: Vec3) void {
    if (!isFiniteVec3(impulse) or impulse.lengthSq() > MAX_IMPULSE_MAGNITUDE_SQ) return;
    const state = getSharedStateMut();
    if (entity_id < MAX_ENTITIES and state.entities[@intCast(entity_id)].active != 0) {
        state.entities[@intCast(entity_id)].velocity = state.entities[@intCast(entity_id)].velocity.add(impulse);
    }
}

pub fn setPlayerVelocity(player_id: u32, vel: Vec3) void {
    if (!isFiniteVec3(vel) or vel.lengthSq() > MAX_VELOCITY_MAGNITUDE_SQ) return;
    const state = getSharedStateMut();
    if (player_id < MAX_PLAYERS and state.players[player_id].active != 0) {
        state.players[player_id].velocity = vel;
    }
}

pub fn teleportPlayer(player_id: u32, pos: Vec3) void {
    if (!isFiniteVec3(pos) or @abs(pos.x) > BOUND_LIMIT or @abs(pos.y) > BOUND_LIMIT or @abs(pos.z) > BOUND_LIMIT) return;
    const state = getSharedStateMut();
    if (player_id < MAX_PLAYERS and state.players[player_id].active != 0) {
        state.players[player_id].position = pos;
        state.players[player_id].velocity = .{};
    }
}

/// Synchronously allocates an entity slot across both `GameState` and `EcsWorld` (1:1 unified ID)
/// and returns the allocated Entity ID (`0..MAX_ENTITIES - 1`, or `NO_PARENT` on failure).
pub fn spawnEntity(entity_type: u32, pos: Vec3, color: [4]f32) u64 {
    // if (is_wasm) {
    //     return engine_spawn_entity(entity_type, pos.x, pos.y, pos.z, color[0], color[1], color[2], color[3]);
    // } else {
    //     if (!isFiniteVec3(pos)) return NO_PARENT;
    //     const state = getSharedStateMut();
    //     for (&state.entities, 0..) |*ent, idx| {
    //         if (ent.active == 0) {
    //             ent.* = .{
    //                 .id = idx,
    //                 .active = 1,
    //                 .parent_id = NO_PARENT,
    //                 .component_mask = ComponentMask.ACTIVE | ComponentMask.TRANSFORM | ComponentMask.RENDERABLE,
    //                 .entity_type = entity_type,
    //                 .position = pos,
    //                 .local_position = pos,
    //                 .local_scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
    //                 .scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
    //                 .color = color,
    //             };
    //             state.header.entity_count += 1;
    //             return idx;
    //         }
    //     }
    //     return NO_PARENT;
    // }

    return engine_spawn_entity(entity_type, pos.x, pos.y, pos.z, color[0], color[1], color[2], color[3]);
}

/// Synchronously despawns an entity across both `GameState` and `EcsWorld`.
pub fn despawnEntity(entity_id: u64) void {
    if (is_wasm) {
        engine_despawn_entity(entity_id);
    } else {
        const state = getSharedStateMut();
        if (entity_id < MAX_ENTITIES and state.entities[@intCast(entity_id)].active != 0) {
            state.entities[@intCast(entity_id)] = .{};
            if (state.header.entity_count > 0) state.header.entity_count -= 1;
        }
    }
}

pub fn setEntityLocalPosition(entity_id: u64, pos: Vec3) void {
    if (!isFiniteVec3(pos) or @abs(pos.x) > BOUND_LIMIT or @abs(pos.y) > BOUND_LIMIT or @abs(pos.z) > BOUND_LIMIT) return;
    const state = getSharedStateMut();
    if (entity_id < MAX_ENTITIES and state.entities[@intCast(entity_id)].active != 0) {
        state.entities[@intCast(entity_id)].local_position = pos;
        resolveEntityTransformInPlace(state, entity_id);
    }
}

pub fn setEntityLocalRotation(entity_id: u64, rot: Vec3) void {
    if (!isFiniteVec3(rot)) return;
    const state = getSharedStateMut();
    if (entity_id < MAX_ENTITIES and state.entities[@intCast(entity_id)].active != 0) {
        state.entities[@intCast(entity_id)].local_rotation = rot;
        resolveEntityTransformInPlace(state, entity_id);
    }
}

pub fn setEntityLocalScale(entity_id: u64, scale: Vec3) void {
    if (!isFiniteVec3(scale) or scale.x < 0.0 or scale.y < 0.0 or scale.z < 0.0) return;
    const state = getSharedStateMut();
    if (entity_id < MAX_ENTITIES and state.entities[@intCast(entity_id)].active != 0) {
        state.entities[@intCast(entity_id)].local_scale = scale;
        resolveEntityTransformInPlace(state, entity_id);
    }
}

pub fn setEntityParent(child_id: u64, parent_id: u64) void {
    const state = getSharedStateMut();
    if (child_id < MAX_ENTITIES and state.entities[@intCast(child_id)].active != 0) {
        if (parent_id == NO_PARENT) {
            state.entities[@intCast(child_id)].parent_id = NO_PARENT;
            resolveEntityTransformInPlace(state, child_id);
        } else if (parent_id < MAX_ENTITIES and state.entities[@intCast(parent_id)].active != 0 and parent_id != child_id) {
            var has_cycle = false;
            var curr = parent_id;
            var depth: u32 = 0;
            while (curr != NO_PARENT and depth < 16) : (depth += 1) {
                if (curr == child_id) {
                    has_cycle = true;
                    break;
                }
                curr = state.entities[@intCast(curr)].parent_id;
            }
            if (!has_cycle) {
                state.entities[@intCast(child_id)].parent_id = parent_id;
                resolveEntityTransformInPlace(state, child_id);
            }
        }
    }
}

pub fn setEntityCollider(entity_id: u64, col_type: ColliderType, extents: Vec3) void {
    if (!isFiniteVec3(extents)) return;
    const state = getSharedStateMut();
    if (entity_id < MAX_ENTITIES and state.entities[@intCast(entity_id)].active != 0) {
        state.entities[@intCast(entity_id)].collider_type = col_type;
        state.entities[@intCast(entity_id)].collider_extents = extents;
        state.entities[@intCast(entity_id)].component_mask |= ComponentMask.COLLIDER;
    }
}

pub fn setEntityTag(entity_id: u64, tag_str: []const u8) void {
    const state = getSharedStateMut();
    if (entity_id < MAX_ENTITIES and state.entities[@intCast(entity_id)].active != 0) {
        const len = @min(tag_str.len, 16);
        @memset(&state.entities[@intCast(entity_id)].tag, 0);
        @memcpy(state.entities[@intCast(entity_id)].tag[0..len], tag_str[0..len]);
    }
}

pub fn setEntityMotionType(entity_id: u64, motion_type: MotionType) void {
    const state = getSharedStateMut();
    if (entity_id < MAX_ENTITIES and state.entities[@intCast(entity_id)].active != 0) {
        state.entities[@intCast(entity_id)].motion_type = motion_type;
        state.entities[@intCast(entity_id)].component_mask |= ComponentMask.RIGID_BODY;
    }
}

pub fn setEntityMaterial(entity_id: u64, metallic: f32, roughness: f32, emissive: f32, shading_model: u32) void {
    const state = getSharedStateMut();
    if (entity_id < MAX_ENTITIES and state.entities[@intCast(entity_id)].active != 0) {
        state.entities[@intCast(entity_id)].metallic = metallic;
        state.entities[@intCast(entity_id)].roughness = roughness;
        state.entities[@intCast(entity_id)].emissive = emissive;
        state.entities[@intCast(entity_id)].shading_model = shading_model;
    }
}

pub fn setEntityColor(entity_id: u64, color: [4]f32) void {
    const state = getSharedStateMut();
    if (entity_id < MAX_ENTITIES and state.entities[@intCast(entity_id)].active != 0) {
        state.entities[@intCast(entity_id)].color = color;
    }
}

pub fn setEntityPbr(entity_id: u64, metallic: f32, roughness: f32) void {
    setEntityMaterial(entity_id, metallic, roughness, 0.0, 0);
}

pub fn setEntityUnlit(entity_id: u64, emissive_intensity: f32) void {
    setEntityMaterial(entity_id, 0.0, 1.0, emissive_intensity, 1);
}

pub fn emitEvent(event_type: u32, source_id: u64, target_id: u64, data: [4]f32, tag_str: []const u8) void {
    const state = getSharedStateMut();
    if (state.events.count < MAX_SHARED_EVENTS) {
        var ev = GameEvent{
            .event_type = event_type,
            .source_id = source_id,
            .target_id = target_id,
            .data = data,
        };
        const len = @min(tag_str.len, 16);
        @memcpy(ev.tag[0..len], tag_str[0..len]);
        state.events.events[state.events.count] = ev;
        state.events.count += 1;
    }
}

pub const math = struct {
    pub fn sin(val: f32) f32 {
        return @sin(val);
    }
    pub fn cos(val: f32) f32 {
        return @cos(val);
    }
    pub fn sqrt(val: f32) f32 {
        return @sqrt(val);
    }
    pub fn clamp(val: f32, min: f32, max: f32) f32 {
        if (val < min) return min;
        if (val > max) return max;
        return val;
    }
};

pub const time = struct {
    pub fn get() f32 {
        return getWorld().getTime();
    }
    pub fn getDelta() f32 {
        return getWorld().getDeltaTime();
    }
};

pub const log = struct {
    pub fn print(msg: []const u8) void {
        engine_log(msg.ptr, @intCast(msg.len));
    }

    pub fn printf(comptime fmt: []const u8, args: anytype) void {
        if (std.fmt.allocPrint(std.heap.wasm_allocator, fmt, args)) |output| {
            defer std.heap.wasm_allocator.free(output);
            print(output);
        } else |_| {
            print("[log error] cannot format print");
        }
    }
};

pub const scene = struct {
    pub fn getRotationX() f32 {
        return getWorld().getScene().getRotationX();
    }
    pub fn setRotationX(val: f32) void {
        if (std.math.isFinite(val)) {
            getSharedStateMut().scene.rotation_x = val;
        }
    }
    pub fn getRotationY() f32 {
        return getWorld().getScene().getRotationY();
    }
    pub fn setRotationY(val: f32) void {
        if (std.math.isFinite(val)) {
            getSharedStateMut().scene.rotation_y = val;
        }
    }
    pub fn rotate(dx: f32, dy: f32) void {
        if (std.math.isFinite(dx) and std.math.isFinite(dy)) {
            const state = getSharedStateMut();
            state.scene.rotation_x += dx;
            state.scene.rotation_y += dy;
        }
    }
    pub fn getCameraDistance() f32 {
        return getWorld().getScene().getCameraDistance();
    }
    pub fn setCameraDistance(val: f32) void {
        if (std.math.isFinite(val) and val >= 1.0 and val <= 50.0) {
            getSharedStateMut().scene.camera_distance = val;
        }
    }
    pub fn setFaceColor(face_index: u32, r: f32, g: f32, b: f32) void {
        if (face_index < 6) {
            const cr = std.math.clamp(r, 0.0, 1.0);
            const cg = std.math.clamp(g, 0.0, 1.0);
            const cb = std.math.clamp(b, 0.0, 1.0);
            getSharedStateMut().scene.cube_face_colors[face_index] = [_]f32{ cr, cg, cb, 1.0 };
        }
    }
};

pub const input = struct {
    pub fn isKeyDown(scancode: u32) bool {
        return engine_is_key_down(scancode) != 0;
    }
    pub fn isMouseDown(button: u32) bool {
        return engine_is_mouse_button_down(button) != 0;
    }

    /// Fast zero-copy check of action state via shared memory
    pub fn isActionDown(action: ActionId) bool {
        return getWorld().getInput().isActionDown(action);
    }

    /// Fast zero-copy check of action just pressed this frame
    pub fn isActionPressed(action: ActionId) bool {
        return getWorld().getInput().isActionPressed(action);
    }

    /// Fast zero-copy check of analog axis value [-1.0, 1.0]
    pub fn getAxis(axis: AxisId) f32 {
        return getWorld().getInput().getAxis(axis);
    }

    pub fn getMouseX() f32 {
        return getWorld().getInput().mouse_x;
    }
    pub fn getMouseY() f32 {
        return getWorld().getInput().mouse_y;
    }
    pub fn getMouseDx() f32 {
        return getWorld().getInput().mouse_dx;
    }
    pub fn getMouseDy() f32 {
        return getWorld().getInput().mouse_dy;
    }
};

pub const events = struct {
    pub fn get() []const GameEvent {
        return getWorld().getEvents();
    }
    pub fn emit(event_type: u32, target_id: u32, data: [4]f32, tag_str: []const u8) void {
        emitEvent(event_type, 0, target_id, data, tag_str);
    }
};

pub const physics = struct {
    pub const ShapeType = enum(u32) {
        box = 0,
        sphere = 1,
    };

    pub fn createBody(entity_id: u64, shape: ShapeType, pos: Vec3, is_dynamic: bool) u32 {
        return engine_physics_create_body(entity_id, @intFromEnum(shape), pos.x, pos.y, pos.z, if (is_dynamic) 1 else 0);
    }

    pub fn applyImpulse(body_id: u32, impulse: Vec3) void {
        engine_physics_apply_impulse(body_id, impulse.x, impulse.y, impulse.z);
    }

    pub fn getPosition(body_id: u32) Vec3 {
        return Vec3.init(
            engine_physics_get_pos_x(body_id),
            engine_physics_get_pos_y(body_id),
            engine_physics_get_pos_z(body_id),
        );
    }

    pub fn getVelocityY(body_id: u32) f32 {
        return engine_physics_get_vel_y(body_id);
    }

    pub fn isActive(body_id: u32) bool {
        return engine_physics_is_active(body_id) != 0;
    }

    pub const RaycastHit_Host = extern struct {
        entity_id: u64, // Populated via Jolt UserData in O(1)!
        body_id: u32,
        fraction: f32,
        position: [3]f32,
        _pad: u32 = 0,
    };

    pub const RaycastHit = extern struct {
        entity_id: u64, // Populated via Jolt UserData in O(1)!
        body_id: u32,
        fraction: f32,
        position: Vec3,
    };

    pub fn castRay(origin: Vec3, dir: Vec3) ?RaycastHit {
        var out: RaycastHit_Host = undefined;
        if (engine_physics_cast_ray(origin.x, origin.y, origin.z, dir.x, dir.y, dir.z, &out) != 0) {
            return RaycastHit{
                .entity_id = out.entity_id,
                .body_id = out.body_id,
                .fraction = out.fraction,
                .position = Vec3.init(out.position[0], out.position[1], out.position[2]),
            };
        }
        return null;
    }

    /// Collision layers (collision groups). `default_static` / `default_dynamic` are the base groups.
    pub const Layer = enum(u32) {
        default_static = 0,
        default_dynamic = 1,
        debris = 2,
        character = 3,
        water = 4,
    };

    /// Bitmask selecting every layer in shapecast queries.
    pub const ALL_LAYERS: u32 = 0xFFFFFFFF;

    pub fn layerBit(layer: Layer) u32 {
        return @as(u32, 1) << @as(u5, @intCast(@intFromEnum(layer)));
    }

    pub fn setCollisionLayer(body_id: u32, layer: Layer) void {
        engine_physics_set_collision_layer(body_id, @intFromEnum(layer));
    }

    pub fn setLayerCollidable(a: Layer, b: Layer, enabled: bool) void {
        engine_physics_set_layer_collision(@intFromEnum(a), @intFromEnum(b), if (enabled) 1 else 0);
    }

    pub const ShapeCastHit_Host = extern struct {
        entity_id: u64,
        body_id: u32,
        fraction: f32,
        position: [3]f32,
        normal: [3]f32,
    };

    pub const ShapeCastHit = extern struct {
        entity_id: u64,
        body_id: u32,
        position: Vec3,
        normal: Vec3,
        fraction: f32,
    };

    fn convertShapeCastHit(out: ShapeCastHit_Host) ShapeCastHit {
        return ShapeCastHit{
            .entity_id = out.entity_id,
            .body_id = out.body_id,
            .position = Vec3.init(out.position[0], out.position[1], out.position[2]),
            .normal = Vec3.init(out.normal[0], out.normal[1], out.normal[2]),
            .fraction = out.fraction,
        };
    }

    /// Sweeps a sphere from `origin` along `dir` (the full vector length is the sweep distance).
    pub fn castSphere(radius: f32, origin: Vec3, dir: Vec3, layer_mask: u32) ?ShapeCastHit {
        var out: ShapeCastHit_Host = undefined;
        if (engine_physics_cast_sphere(radius, origin.x, origin.y, origin.z, dir.x, dir.y, dir.z, layer_mask, &out) != 0) {
            return convertShapeCastHit(out);
        }
        return null;
    }

    /// Sweeps an axis-aligned box from `origin` along `dir`.
    pub fn castBox(half_extents: Vec3, origin: Vec3, dir: Vec3, layer_mask: u32) ?ShapeCastHit {
        var out: ShapeCastHit_Host = undefined;
        if (engine_physics_cast_box(half_extents.x, half_extents.y, half_extents.z, origin.x, origin.y, origin.z, dir.x, dir.y, dir.z, layer_mask, &out) != 0) {
            return convertShapeCastHit(out);
        }
        return null;
    }
};

/// Jolt `CharacterVirtual` humanoid controller (slopes, stairs, ground snapping).
pub const character = struct {
    pub const GroundState = enum(u32) { on_ground = 0, sliding = 1, in_air = 2 };

    /// Creates a capsule character centered at `pos`. Returns 0 on failure.
    pub fn create(pos: Vec3, half_height: f32, radius: f32) u32 {
        return engine_character_create(pos.x, pos.y, pos.z, half_height, radius);
    }

    pub fn destroy(id: u32) void {
        engine_character_destroy(id);
    }

    /// Sets the desired velocity. The engine integrates gravity while the character is airborne,
    /// so pass `getVelocityY(id)` for `vel.y` unless jumping.
    pub fn setLinearVelocity(id: u32, vel: Vec3) void {
        engine_character_set_linear_velocity(id, vel.x, vel.y, vel.z);
    }

    pub fn setPosition(id: u32, pos: Vec3) void {
        engine_character_set_position(id, pos.x, pos.y, pos.z);
    }

    pub fn getPosition(id: u32) Vec3 {
        return Vec3.init(engine_character_get_pos_x(id), engine_character_get_pos_y(id), engine_character_get_pos_z(id));
    }

    pub fn getVelocityY(id: u32) f32 {
        return engine_character_get_vel_y(id);
    }

    pub fn getGroundState(id: u32) GroundState {
        return @enumFromInt(engine_character_get_ground_state(id));
    }
};

/// Jolt physics constraints connecting two rigid bodies. All ids returned are 0 on failure.
pub const constraint = struct {
    pub fn createHinge(body_a: u32, body_b: u32, anchor: Vec3, axis: Vec3, limit_min: f32, limit_max: f32) u32 {
        return engine_constraint_create_hinge(body_a, body_b, anchor.x, anchor.y, anchor.z, axis.x, axis.y, axis.z, limit_min, limit_max);
    }

    pub fn createBallSocket(body_a: u32, body_b: u32, anchor: Vec3) u32 {
        return engine_constraint_create_ball_socket(body_a, body_b, anchor.x, anchor.y, anchor.z);
    }

    pub fn createSlider(body_a: u32, body_b: u32, axis: Vec3, limit_min: f32, limit_max: f32) u32 {
        return engine_constraint_create_slider(body_a, body_b, axis.x, axis.y, axis.z, limit_min, limit_max);
    }

    pub fn createWeld(body_a: u32, body_b: u32) u32 {
        return engine_constraint_create_weld(body_a, body_b);
    }

    pub fn destroy(id: u32) void {
        engine_constraint_destroy(id);
    }
};

pub const Ray = struct {
    origin: Vec3,
    direction: Vec3,

    pub fn intersectPlaneY(self: Ray, plane_y: f32) ?Vec3 {
        if (@abs(self.direction.y) < 1e-6) return null;
        const t = (plane_y - self.origin.y) / self.direction.y;
        if (t < 0.0) return null;
        return self.origin.add(self.direction.scale(t));
    }
};

pub const camera = struct {
    pub fn setPosition(pos: Vec3) void {
        engine_camera_set_pos(pos.x, pos.y, pos.z);
    }

    pub fn setRotation(yaw: f32, pitch: f32) void {
        engine_camera_set_rot(yaw, pitch);
    }

    pub fn setFov(fov_deg: f32) void {
        engine_camera_set_fov(fov_deg);
    }

    pub fn getPosition() Vec3 {
        return Vec3.init(
            engine_camera_get_pos_x(),
            engine_camera_get_pos_y(),
            engine_camera_get_pos_z(),
        );
    }

    pub fn getYaw() f32 {
        return engine_camera_get_yaw();
    }

    pub fn getPitch() f32 {
        return engine_camera_get_pitch();
    }

    pub fn screenToRay(sx: f32, sy: f32, sw: f32, sh: f32) ?Ray {
        if (engine_camera_screen_to_ray(sx, sy, sw, sh) != 0) {
            return Ray{
                .origin = Vec3.init(
                    engine_camera_get_ray_origin_x(),
                    engine_camera_get_ray_origin_y(),
                    engine_camera_get_ray_origin_z(),
                ),
                .direction = Vec3.init(
                    engine_camera_get_ray_dir_x(),
                    engine_camera_get_ray_dir_y(),
                    engine_camera_get_ray_dir_z(),
                ),
            };
        }
        return null;
    }
};

pub const ui = struct {
    pub fn drawRect(x: f32, y: f32, w: f32, h: f32, color: [4]f32) void {
        engine_ui_draw_rect(x, y, w, h, color[0], color[1], color[2], color[3]);
    }

    pub fn drawRectBorder(x: f32, y: f32, w: f32, h: f32, thickness: f32, color: [4]f32) void {
        engine_ui_draw_rect_border(x, y, w, h, thickness, color[0], color[1], color[2], color[3]);
    }

    pub fn drawCrosshair(cx: f32, cy: f32, size: f32, thickness: f32, color: [4]f32) void {
        engine_ui_draw_crosshair(cx, cy, size, thickness, color[0], color[1], color[2], color[3]);
    }

    pub fn drawProgressBar(x: f32, y: f32, w: f32, h: f32, frac: f32, fg: [4]f32, bg: [4]f32) void {
        engine_ui_draw_progress_bar(x, y, w, h, frac, fg[0], fg[1], fg[2], fg[3], bg[0], bg[1], bg[2], bg[3]);
    }

    pub fn drawSelectionBox(x1: f32, y1: f32, x2: f32, y2: f32, fill: [4]f32, border: [4]f32) void {
        engine_ui_draw_selection_box(x1, y1, x2, y2, fill[0], fill[1], fill[2], fill[3], border[0], border[1], border[2], border[3]);
    }

    pub fn drawText(text: []const u8, x: f32, y: f32, font_size: f32, color: [4]f32) void {
        engine_ui_draw_text(text.ptr, text.len, x, y, font_size, color[0], color[1], color[2], color[3]);
    }
};

pub const audio = struct {
    pub fn playTone(freq: f32, duration: f32, vol: f32) void {
        engine_audio_play_tone(freq, duration, vol);
    }

    pub fn playImpact(vol: f32) void {
        engine_audio_play_impact(vol);
    }

    pub fn playChime(vol: f32) void {
        engine_audio_play_chime(vol);
    }
};

pub const window = struct {
    pub fn setRelativeMouse(enabled: bool) bool {
        return engine_window_set_relative_mouse(if (enabled) 1 else 0) != 0;
    }

    pub fn getScreenWidth() f32 {
        return engine_window_get_screen_w();
    }

    pub fn getScreenHeight() f32 {
        return engine_window_get_screen_h();
    }
};

pub const particles = struct {
    pub inline fn spawnBurst(pos: Vec3, count: u32, speed: f32, color: [4]f32, size: f32, lifetime: f32) void {
        engine_particle_spawn_burst(pos.x, pos.y, pos.z, count, speed, color[0], color[1], color[2], color[3], size, lifetime);
    }
};

pub inline fn spawnParticleBurst(pos: Vec3, count: u32, speed: f32, color: [4]f32, size: f32, lifetime: f32) void {
    particles.spawnBurst(pos, count, speed, color, size, lifetime);
}

pub const net = struct {
    pub fn fireServer(name: []const u8, payload: []const u8) void {
        engine_net_fire_server(name.ptr, name.len, payload.ptr, payload.len);
    }

    pub fn fireClient(client_id: u32, name: []const u8, payload: []const u8) void {
        engine_net_fire_client(client_id, name.ptr, name.len, payload.ptr, payload.len);
    }

    pub fn fireAllClients(name: []const u8, payload: []const u8) void {
        engine_net_fire_all_clients(name.ptr, name.len, payload.ptr, payload.len);
    }

    pub fn pollEvent(name_buf: []u8, data_buf: []u8) ?struct { name_len: usize, data_len: usize, sender_id: u32 } {
        var sender_id: u32 = 0;
        const res = engine_net_poll_event(name_buf.ptr, name_buf.len, data_buf.ptr, data_buf.len, &sender_id);
        if (res == 0) return null;
        const name_len: usize = @intCast(res >> 16);
        const data_len: usize = @intCast(res & 0xFFFF);
        return .{
            .name_len = name_len,
            .data_len = data_len,
            .sender_id = sender_id,
        };
    }

    pub fn getRtt() f32 {
        return engine_net_get_rtt();
    }

    pub fn isConnected() bool {
        return engine_net_is_connected() != 0;
    }

    pub fn getClientId() u32 {
        return engine_net_get_client_id();
    }
};

pub const task = struct {
    pub const TaskCallback = *const fn () void;

    pub const TaskSlot = struct {
        active: bool = false,
        target: f32 = 0.0,
        remaining: f32 = 0.0,
        elapsed: f32 = 0.0,
        callback: ?TaskCallback = null,
        is_deferred: bool = false,
    };

    var task_pool: [64]TaskSlot = [_]TaskSlot{.{}} ** 64;

    /// Yields/waits for `seconds` and returns the actual elapsed time on the resumption frame.
    /// Uses slot 0 by default.
    pub fn wait(seconds: f32) f32 {
        return waitSlot(0, seconds);
    }

    /// Slot-indexed wait supporting multiple concurrent wait timers
    pub fn waitSlot(slot_id: u32, seconds: f32) f32 {
        return task_imports.engine_task_wait(slot_id, seconds);
    }

    /// Spawns a callback to execute immediately in the cooperative scheduler
    pub fn spawn(callback: TaskCallback) u32 {
        callback();
        return 0;
    }

    /// Defers execution of `callback` until after the current frame/tick
    pub fn @"defer"(callback: TaskCallback) u32 {
        return deferTask(callback);
    }

    pub fn deferTask(callback: TaskCallback) u32 {
        for (&task_pool, 0..) |*slot, i| {
            if (!slot.active) {
                slot.active = true;
                slot.is_deferred = true;
                slot.callback = callback;
                slot.target = 0.0;
                slot.remaining = 0.0;
                slot.elapsed = 0.0;
                return @intCast(i + 1);
            }
        }
        return 0;
    }

    /// Schedules `callback` to run after `seconds` have elapsed
    pub fn delay(seconds: f32, callback: TaskCallback) u32 {
        for (&task_pool, 0..) |*slot, i| {
            if (!slot.active) {
                slot.active = true;
                slot.is_deferred = false;
                slot.callback = callback;
                slot.target = @max(0.0, seconds);
                slot.remaining = slot.target;
                slot.elapsed = 0.0;
                return @intCast(i + 1);
            }
        }
        return 0;
    }

    /// Cancels a scheduled task by ID
    pub fn cancel(task_id: u32) void {
        _ = task_imports.engine_task_cancel(task_id);
        if (task_id > 0 and task_id <= task_pool.len) {
            task_pool[task_id - 1].active = false;
            task_pool[task_id - 1].callback = null;
        }
    }

    /// Steps guest-scheduled tasks. Called during script update.
    pub fn step(dt: f32) void {
        for (&task_pool) |*slot| {
            if (!slot.active) continue;

            if (slot.is_deferred) {
                slot.active = false;
                if (slot.callback) |cb| {
                    cb();
                }
            } else {
                slot.remaining -= dt;
                slot.elapsed += dt;
                if (slot.remaining <= 0.0001) {
                    slot.active = false;
                    if (slot.callback) |cb| {
                        cb();
                    }
                }
            }
        }
    }
};

// -------------------------------------------------------------------------------------------------
// 6. Flecs ECS Dynamic Component & System Management Namespace
// -------------------------------------------------------------------------------------------------

pub const ecs = struct {
    pub const EntityId = u64;
    pub const ComponentId = u64;
    pub const SystemId = u32;

    pub const BuiltinComponent = enum(u32) {
        position = 0,
        rotation = 1,
        scale = 2,
        velocity = 3,
        mesh_render = 4,
        physics_body = 5,
        script = 6,
    };

    pub const Position = extern struct {
        x: f32 = 0.0,
        y: f32 = 0.0,
        z: f32 = 0.0,
    };

    pub const Rotation = extern struct {
        x: f32 = 0.0,
        y: f32 = 0.0,
        z: f32 = 0.0,
    };

    pub const Scale = extern struct {
        x: f32 = 1.0,
        y: f32 = 1.0,
        z: f32 = 1.0,
    };

    pub const Velocity = extern struct {
        x: f32 = 0.0,
        y: f32 = 0.0,
        z: f32 = 0.0,
    };

    pub const MeshRender = extern struct {
        primitive_type: u32 = 0,
        color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
        metallic: f32 = 0.0,
        roughness: f32 = 0.5,
        visible: bool = true,
    };

    pub const SystemCallback = *const fn (entity: EntityId, dt: f32) void;
    pub const SystemBatchCallback = *const fn (entities: []const EntityId, dt: f32) void;

    pub const System = struct {
        id: SystemId = 0,
        name: [64]u8 = [_]u8{0} ** 64,
        name_len: usize = 0,
        comp_ids: [8]ComponentId = [_]ComponentId{0} ** 8,
        comp_count: usize = 0,
        callback: ?SystemCallback = null,
        batch_callback: ?SystemBatchCallback = null,
        enabled: bool = true,
    };

    var systems_pool: [64]System = [_]System{.{}} ** 64;
    var registered_system_count: usize = 0;

    /// Registers a component with given name, byte size, and byte alignment in Flecs.
    pub fn registerComponent(name: []const u8, size: usize, alignment: usize) ComponentId {
        return ecs_imports.engine_ecs_register_component(name.ptr, @intCast(name.len), @intCast(size), @intCast(alignment));
    }

    /// Ergonomic type-inferred component registration helper.
    /// E.g. `const health_id = engine.ecs.register(Health, "Health");`
    pub fn register(comptime T: type, name: []const u8) ComponentId {
        return registerComponent(name, @sizeOf(T), @alignOf(T));
    }

    /// Looks up component ID by name, or returns null if not registered.
    pub fn getComponentId(name: []const u8) ?ComponentId {
        const id = ecs_imports.engine_ecs_get_component_id(name.ptr, @intCast(name.len));
        if (id == 0) return null;
        return id;
    }

    /// Retrieves component ID for engine built-in component (Position, Rotation, Scale, Velocity, MeshRender, etc.)
    pub fn getBuiltinComponent(builtin: BuiltinComponent) ComponentId {
        return ecs_imports.engine_ecs_get_builtin_component(@intFromEnum(builtin));
    }

    /// Creates a new Flecs entity with an optional name tag.
    pub fn newEntity(name: ?[]const u8) EntityId {
        if (name) |n| {
            return ecs_imports.engine_ecs_new_entity(n.ptr, @intCast(n.len));
        }
        return ecs_imports.engine_ecs_new_entity(null, 0);
    }

    /// Deletes a Flecs entity.
    pub fn deleteEntity(entity: EntityId) void {
        _ = ecs_imports.engine_ecs_delete_entity(entity);
    }

    /// Checks if a Flecs entity is currently alive.
    pub fn isAlive(entity: EntityId) bool {
        return ecs_imports.engine_ecs_is_alive(entity) != 0;
    }

    /// Attaches or updates component struct value on entity.
    pub fn set(entity: EntityId, comp_id: ComponentId, val: anytype) bool {
        const T = @TypeOf(val);
        const ptr: [*]const u8 = @ptrCast(&val);
        return ecs_imports.engine_ecs_set_component(entity, comp_id, ptr, @sizeOf(T)) != 0;
    }

    /// Attaches or updates raw component bytes on entity.
    pub fn setBytes(entity: EntityId, comp_id: ComponentId, bytes: []const u8) bool {
        return ecs_imports.engine_ecs_set_component(entity, comp_id, bytes.ptr, @intCast(bytes.len)) != 0;
    }

    /// Reads component data of type `T` from entity. Returns `null` if entity does not have component.
    pub fn get(entity: EntityId, comp_id: ComponentId, comptime T: type) ?T {
        var val: T = undefined;
        const out_ptr: [*]u8 = @ptrCast(&val);
        const read = ecs_imports.engine_ecs_get_component(entity, comp_id, out_ptr, @sizeOf(T));
        if (read <= 0) return null;
        return val;
    }

    /// Reads raw component bytes from entity into buffer. Returns bytes copied or null if not found.
    pub fn getBytes(entity: EntityId, comp_id: ComponentId, out_buf: []u8) ?usize {
        const read = ecs_imports.engine_ecs_get_component(entity, comp_id, out_buf.ptr, @intCast(out_buf.len));
        if (read <= 0) return null;
        return @intCast(read);
    }

    /// Checks if entity has the given component.
    pub fn has(entity: EntityId, comp_id: ComponentId) bool {
        return ecs_imports.engine_ecs_has_component(entity, comp_id) != 0;
    }

    /// Removes a component from an entity.
    pub fn remove(entity: EntityId, comp_id: ComponentId) bool {
        return ecs_imports.engine_ecs_remove_component(entity, comp_id) != 0;
    }

    /// Queries entities matching all specified component IDs into `out_buf`. Returns count matched.
    pub fn query(comp_ids: []const ComponentId, out_buf: []EntityId) usize {
        if (comp_ids.len == 0 or out_buf.len == 0) return 0;
        return ecs_imports.engine_ecs_query_entities(comp_ids.ptr, @intCast(comp_ids.len), out_buf.ptr, @intCast(out_buf.len));
    }

    /// Returns count of entities matching all specified component IDs.
    pub fn queryCount(comp_ids: []const ComponentId) usize {
        if (comp_ids.len == 0) return 0;
        return ecs_imports.engine_ecs_query_count(comp_ids.ptr, @intCast(comp_ids.len));
    }

    /// Defines and registers a system with a query filter and per-entity callback.
    pub fn registerSystem(name: []const u8, query_components: []const ComponentId, callback: SystemCallback) SystemId {
        if (registered_system_count >= systems_pool.len) return 0;
        const sys_id = ecs_imports.engine_ecs_register_system(name.ptr, @intCast(name.len), query_components.ptr, @intCast(query_components.len));
        const idx = registered_system_count;
        var s = &systems_pool[idx];
        s.id = if (sys_id > 0) sys_id else @intCast(idx + 1);
        s.name_len = @min(name.len, 64);
        @memcpy(s.name[0..s.name_len], name[0..s.name_len]);
        s.comp_count = @min(query_components.len, 8);
        for (query_components[0..s.comp_count], 0..) |cid, i| {
            s.comp_ids[i] = cid;
        }
        s.callback = callback;
        s.batch_callback = null;
        s.enabled = true;
        registered_system_count += 1;
        return s.id;
    }

    /// Defines and registers a system with a query filter and batch entity callback.
    pub fn registerBatchSystem(name: []const u8, query_components: []const ComponentId, batch_callback: SystemBatchCallback) SystemId {
        if (registered_system_count >= systems_pool.len) return 0;
        const sys_id = ecs_imports.engine_ecs_register_system(name.ptr, @intCast(name.len), query_components.ptr, @intCast(query_components.len));
        const idx = registered_system_count;
        var s = &systems_pool[idx];
        s.id = if (sys_id > 0) sys_id else @intCast(idx + 1);
        s.name_len = @min(name.len, 64);
        @memcpy(s.name[0..s.name_len], name[0..s.name_len]);
        s.comp_count = @min(query_components.len, 8);
        for (query_components[0..s.comp_count], 0..) |cid, i| {
            s.comp_ids[i] = cid;
        }
        s.callback = null;
        s.batch_callback = batch_callback;
        s.enabled = true;
        registered_system_count += 1;
        return s.id;
    }

    /// Enables or disables a system by SystemId.
    pub fn setSystemEnabled(sys_id: SystemId, enabled: bool) void {
        _ = ecs_imports.engine_ecs_set_system_enabled(sys_id, if (enabled) 1 else 0);
        for (systems_pool[0..registered_system_count]) |*s| {
            if (s.id == sys_id) {
                s.enabled = enabled;
                break;
            }
        }
    }

    /// Executes a single system by SystemId with the specified delta time.
    pub fn runSystem(sys_id: SystemId, dt: f32) void {
        for (systems_pool[0..registered_system_count]) |*s| {
            if (s.id == sys_id and s.enabled) {
                var entities_buf: [2048]EntityId = undefined;
                const count = query(s.comp_ids[0..s.comp_count], &entities_buf);
                if (s.batch_callback) |batch_cb| {
                    batch_cb(entities_buf[0..count], dt);
                } else if (s.callback) |cb| {
                    for (entities_buf[0..count]) |e| {
                        cb(e, dt);
                    }
                }
                break;
            }
        }
    }

    /// Advances and executes all registered UGC systems for the frame.
    pub fn step(dt: f32) void {
        var entities_buf: [2048]EntityId = undefined;
        for (systems_pool[0..registered_system_count]) |*s| {
            if (!s.enabled) continue;
            const count = query(s.comp_ids[0..s.comp_count], &entities_buf);
            if (count == 0) continue;
            if (s.batch_callback) |batch_cb| {
                batch_cb(entities_buf[0..count], dt);
            } else if (s.callback) |cb| {
                for (entities_buf[0..count]) |e| {
                    cb(e, dt);
                }
            }
        }
    }
};

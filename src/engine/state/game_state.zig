const std = @import("std");

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

/// Physics motion type (compatible with Jolt's EMotionType)
pub const MotionType = enum(u32) {
    dynamic = 0,
    kinematic = 1,
    static = 2,
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

    pub fn make(event_type: u32, source_id: u64, target_id: u64, data: [4]f32, tag_str: []const u8) GameEvent {
        var ev = GameEvent{
            .event_type = event_type,
            .source_id = source_id,
            .target_id = target_id,
            .data = data,
        };
        const len = @min(tag_str.len, 16);
        @memcpy(ev.tag[0..len], tag_str[0..len]);
        return ev;
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

    // World Transforms (authoritative, backward compatible with .position, .rotation, .scale)
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

    // Visuals & Metadata
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
        [_]f32{ 0.95, 0.26, 0.21, 1.0 }, // Front: Red
        [_]f32{ 0.13, 0.59, 0.95, 1.0 }, // Back: Blue
        [_]f32{ 0.30, 0.69, 0.31, 1.0 }, // Top: Green
        [_]f32{ 1.00, 0.76, 0.03, 1.0 }, // Bottom: Yellow
        [_]f32{ 0.61, 0.15, 0.69, 1.0 }, // Right: Purple
        [_]f32{ 1.00, 0.60, 0.00, 1.0 }, // Left: Orange
    },
};

pub const WorldHeader = extern struct {
    magic: u32 = WORLD_MAGIC,
    version: u32 = WORLD_VERSION,
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
pub const WORLD_MAGIC: u32 = 0x574F524C; // 'WORL'
pub const WORLD_VERSION: u32 = 2;

pub inline fn isFiniteVec3(v: Vec3) bool {
    return std.math.isFinite(v.x) and std.math.isFinite(v.y) and std.math.isFinite(v.z);
}

pub const GameState = extern struct {
    header: WorldHeader = .{},
    scene: SceneState = .{},
    input: InputStateShared = .{},
    events: EventQueueShared = .{},
    players: [MAX_PLAYERS]PlayerData = [_]PlayerData{.{}} ** MAX_PLAYERS,
    entities: [MAX_ENTITIES]EntityData = [_]EntityData{.{}} ** MAX_ENTITIES,

    pub fn initDefault() GameState {
        var state = GameState{};
        state.header.magic = WORLD_MAGIC;
        state.header.version = WORLD_VERSION;
        state.header.max_players = MAX_PLAYERS;
        state.header.max_entities = MAX_ENTITIES;
        return state;
    }

    /// Allocates and initializes an entity slot in-place.
    pub fn allocateEntitySlot(self: *GameState, preferred_slot: ?u32) ?u32 {
        if (preferred_slot) |slot| {
            if (slot < MAX_ENTITIES and self.entities[slot].active == 0) {
                self.initSlot(slot);
                return slot;
            }
        }
        for (&self.entities, 0..) |*ent, idx| {
            if (ent.active == 0) {
                const slot: u32 = @intCast(idx);
                self.initSlot(slot);
                return slot;
            }
        }
        return null;
    }

    pub fn initSlot(self: *GameState, slot: u32) void {
        if (slot >= MAX_ENTITIES) return;
        const ent = &self.entities[slot];
        const was_active = ent.active != 0;
        ent.* = .{
            .id = slot,
            .active = 1,
            .parent_id = NO_PARENT,
            .component_mask = ComponentMask.ACTIVE | ComponentMask.TRANSFORM,
            .local_scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
            .scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
        };
        if (!was_active) {
            self.header.entity_count += 1;
        }
    }

    /// Despawns an entity slot in-place and unparents any attached children.
    pub fn freeEntitySlot(self: *GameState, entity_id: u64) bool {
        if (entity_id >= MAX_ENTITIES) return false;
        const slot: usize = @intCast(entity_id);
        if (self.entities[slot].active == 0) return false;

        self.entities[slot].active = 0;
        for (&self.entities) |*child| {
            if (child.parent_id == entity_id) {
                child.parent_id = NO_PARENT;
            }
        }
        if (self.header.entity_count > 0) {
            self.header.entity_count -= 1;
        }
        return true;
    }

    /// Sanitizes in-place guest mutations and resolves parent-child hierarchical transforms.
    pub fn resolveHierarchy(self: *GameState) void {
        var active_count: u32 = 0;
        for (&self.entities, 0..) |*ent, idx| {
            if (ent.active == 0) continue;
            active_count += 1;
            ent.id = @intCast(idx);

            if (!isFiniteVec3(ent.local_position)) ent.local_position = .{};
            if (!isFiniteVec3(ent.local_rotation)) ent.local_rotation = .{};
            if (!isFiniteVec3(ent.local_scale) or ent.local_scale.x < 0.0 or ent.local_scale.y < 0.0 or ent.local_scale.z < 0.0) {
                ent.local_scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 };
            }
            if (!isFiniteVec3(ent.velocity)) ent.velocity = .{};
        }
        self.header.entity_count = active_count;

        for (0..8) |_| {
            for (&self.entities) |*ent| {
                if (ent.active == 0) continue;
                if (ent.parent_id == NO_PARENT or ent.parent_id >= MAX_ENTITIES or ent.parent_id == ent.id) {
                    ent.position = ent.local_position;
                    ent.rotation = ent.local_rotation;
                    ent.scale = ent.local_scale;
                } else {
                    const parent = &self.entities[@intCast(ent.parent_id)];
                    if (parent.active != 0) {
                        ent.position = parent.position.add(ent.local_position.mul(parent.scale));
                        ent.rotation = parent.rotation.add(ent.local_rotation);
                        ent.scale = parent.scale.mul(ent.local_scale);
                    } else {
                        ent.position = ent.local_position;
                        ent.rotation = ent.local_rotation;
                        ent.scale = ent.local_scale;
                    }
                }
            }
        }
    }

    /// Advances kinematic velocity integration, sanitizes state, and resolves scene hierarchy.
    pub fn stepAndResolve(self: *GameState, dt: f32) void {
        const damping: f32 = 0.98;

        for (&self.players) |*player| {
            if (player.active != 0) {
                if (!isFiniteVec3(player.position)) player.position = .{};
                if (!isFiniteVec3(player.velocity)) player.velocity = .{};
                if (dt > 0.0) {
                    player.position = player.position.add(player.velocity.scale(dt));
                    player.velocity = player.velocity.scale(damping);
                }
            }
        }

        if (dt > 0.0) {
            for (&self.entities) |*entity| {
                if (entity.active != 0 and entity.motion_type == .dynamic) {
                    if (!isFiniteVec3(entity.velocity)) entity.velocity = .{};
                    entity.local_position = entity.local_position.add(entity.velocity.scale(dt));
                    entity.velocity = entity.velocity.scale(damping);
                }
            }
        }

        self.resolveHierarchy();

        if (dt > 0.0) {
            self.header.tick += 1;
            self.header.time += dt;
            self.header.delta_time = dt;
        }
    }
};

test "GameState memory layout and C ABI alignment" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(Vec3));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Vec4));
    try std.testing.expect(@sizeOf(EntityData) % 16 == 0);
    try std.testing.expect(@sizeOf(GameState) <= 524288);
    try std.testing.expectEqual(@as(u32, WORLD_MAGIC), GameState.initDefault().header.magic);
}

//! Built-in Zig Entity Component System (ECS)
//! High-performance, pure-Zig ECS implementation supporting entities, built-in and dynamic
//! components, multi-component queries, native and guest systems, and Jolt/Scene synchronization.
//! Entity IDs are unified 1:1 with `GameState.entities` slots (`0 .. MAX_ENTITIES - 1`).

const std = @import("std");
const physics_mod = @import("../physics/jolt.zig");
const scene_mod = @import("../renderer/scene.zig");

const NativeCameraComponent = @import("./native/camera.zig").CameraComponent;
const NativeCameraSystem = @import("./native/camera.zig").CameraSystem;

/// Compatibility alias for code/tests that referenced `engine.ecs.c.ecs_entity_t`
pub const c = struct {
    pub const ecs_entity_t = u64;
};

// Component data structures
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

pub const PrimitiveMeshRender = extern struct {
    primitive_type: u32 = 0, // 0 = cube, 1 = sphere, 2 = pyramid, 3 = cylinder, 4 = plane
    color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    metallic: f32 = 0.0,
    roughness: f32 = 0.5,
    visible: bool = true,
};

pub const PhysicsBody = extern struct {
    body_id: u32 = 0,
    is_dynamic: bool = true,
};

pub const ScriptComponent = extern struct {
    instance_id: u32 = 0,
    enabled: bool = true,
};

pub const Entity = u64;
pub const INVALID_ENTITY: Entity = 0xFFFF_FFFF_FFFF_FFFF;
pub const ComponentId = u64;
pub const SystemId = u32;

pub const MAX_ENTITIES: usize = 4096;
pub const MAX_COMPONENTS: usize = 136; // 7 built-in + 128 dynamic
pub const MAX_DYNAMIC_COMPONENTS: usize = 128;
pub const MAX_DYNAMIC_SYSTEMS: usize = 64;

pub const DynamicComponent = struct {
    id: ComponentId = 0,
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    size: usize = 0,
    alignment: usize = 0,
};

pub const NativeSystemFn = *const fn (world: *EcsWorld, entity: Entity, dt: f32, context: ?*anyopaque) void;

pub const SystemInfo = struct {
    id: u32 = 0,
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    query_components: [8]ComponentId = [_]ComponentId{0} ** 8,
    query_comp_count: usize = 0,
    flecs_system_entity: Entity = INVALID_ENTITY,
    callback: ?NativeSystemFn = null,
    enabled: bool = true,
};

const EntityRecord = struct {
    alive: bool = false,
    generation: u32 = 1,
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    comp_mask: u128 = 0,
    comp_mask_ext: u16 = 0,

    inline fn hasBit(self: *const EntityRecord, comp_idx: usize) bool {
        if (comp_idx < 128) {
            return (self.comp_mask & (@as(u128, 1) << @intCast(comp_idx))) != 0;
        } else if (comp_idx < 144) {
            return (self.comp_mask_ext & (@as(u16, 1) << @intCast(comp_idx - 128))) != 0;
        }
        return false;
    }

    inline fn setBit(self: *EntityRecord, comp_idx: usize) void {
        if (comp_idx < 128) {
            self.comp_mask |= (@as(u128, 1) << @intCast(comp_idx));
        } else if (comp_idx < 144) {
            self.comp_mask_ext |= (@as(u16, 1) << @intCast(comp_idx - 128));
        }
    }

    inline fn clearBit(self: *EntityRecord, comp_idx: usize) void {
        if (comp_idx < 128) {
            self.comp_mask &= ~(@as(u128, 1) << @intCast(comp_idx));
        } else if (comp_idx < 144) {
            self.comp_mask_ext &= ~(@as(u16, 1) << @intCast(comp_idx - 128));
        }
    }
};

const ComponentColumn = struct {
    id: ComponentId = 0,
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    size: usize = 0,
    alignment: usize = 1,
    data: ?[]u8 = null,

    fn deinit(self: *ComponentColumn, allocator: std.mem.Allocator) void {
        if (self.data) |buf| {
            allocator.free(buf);
            self.data = null;
        }
    }

    fn ensureAllocated(self: *ComponentColumn, allocator: std.mem.Allocator) ?[]u8 {
        if (self.data) |buf| return buf;
        const stride = @max(self.size, 1);
        const buf = allocator.alloc(u8, stride * MAX_ENTITIES) catch return null;
        @memset(buf, 0);
        self.data = buf;
        return buf;
    }

    fn getSlotBytes(self: *ComponentColumn, allocator: std.mem.Allocator, slot: usize) ?[]u8 {
        if (slot >= MAX_ENTITIES) return null;
        const buf = self.ensureAllocated(allocator) orelse return null;
        const stride = @max(self.size, 1);
        const start = slot * stride;
        return buf[start .. start + self.size];
    }

    fn getSlotBytesConst(self: *const ComponentColumn, slot: usize) ?[]const u8 {
        if (slot >= MAX_ENTITIES) return null;
        const buf = self.data orelse return null;
        const stride = @max(self.size, 1);
        const start = slot * stride;
        return buf[start .. start + self.size];
    }
};

pub const EcsWorld = struct {
    allocator: std.mem.Allocator,
    id_pos: ComponentId,
    id_rot: ComponentId,
    id_scale: ComponentId,
    id_vel: ComponentId,
    id_mesh: ComponentId,
    id_body: ComponentId,
    id_script: ComponentId,

    entities: []EntityRecord,
    columns: [MAX_COMPONENTS]ComponentColumn = [_]ComponentColumn{.{}} ** MAX_COMPONENTS,
    column_count: usize = 0,

    dynamic_components: [MAX_DYNAMIC_COMPONENTS]DynamicComponent = [_]DynamicComponent{.{ .id = 0 }} ** MAX_DYNAMIC_COMPONENTS,
    dynamic_component_count: usize = 0,
    systems: [MAX_DYNAMIC_SYSTEMS]SystemInfo = [_]SystemInfo{.{}} ** MAX_DYNAMIC_SYSTEMS,
    system_count: usize = 0,
    system_context: ?*anyopaque = null,

    pub fn init() !EcsWorld {
        const allocator = std.heap.page_allocator;
        const entities = try allocator.alloc(EntityRecord, MAX_ENTITIES);
        for (entities) |*rec| {
            rec.* = .{};
        }

        var world = EcsWorld{
            .allocator = allocator,
            .id_pos = 1,
            .id_rot = 2,
            .id_scale = 3,
            .id_vel = 4,
            .id_mesh = 5,
            .id_body = 6,
            .id_script = 7,
            .entities = entities,
        };

        _ = world.registerBuiltinColumn("Position", @sizeOf(Position), @alignOf(Position));
        _ = world.registerBuiltinColumn("Rotation", @sizeOf(Rotation), @alignOf(Rotation));
        _ = world.registerBuiltinColumn("Scale", @sizeOf(Scale), @alignOf(Scale));
        _ = world.registerBuiltinColumn("Velocity", @sizeOf(Velocity), @alignOf(Velocity));
        _ = world.registerBuiltinColumn("MeshRender", @sizeOf(PrimitiveMeshRender), @alignOf(PrimitiveMeshRender));
        _ = world.registerBuiltinColumn("PhysicsBody", @sizeOf(PhysicsBody), @alignOf(PhysicsBody));
        _ = world.registerBuiltinColumn("ScriptComponent", @sizeOf(ScriptComponent), @alignOf(ScriptComponent));
        const camera_comp_id = world.registerDynamicComponent("CameraComponent", @sizeOf(NativeCameraComponent), @alignOf(NativeCameraComponent));

        _ = world.registerNativeSystem("CameraSystem", &[_]u64{camera_comp_id}, NativeCameraSystem);

        return world;
    }

    fn registerBuiltinColumn(self: *EcsWorld, name: []const u8, size: usize, alignment: usize) ComponentId {
        const idx = self.column_count;
        const id: ComponentId = @intCast(idx + 1);
        var col = ComponentColumn{
            .id = id,
            .name_len = @min(name.len, 64),
            .size = size,
            .alignment = @max(alignment, 1),
        };
        @memcpy(col.name[0..col.name_len], name[0..col.name_len]);
        _ = col.ensureAllocated(self.allocator);
        self.columns[idx] = col;
        self.column_count += 1;
        return id;
    }

    pub fn deinit(self: *EcsWorld) void {
        for (&self.columns) |*col| {
            col.deinit(self.allocator);
        }
        self.allocator.free(self.entities);
    }

    fn getSlotIndex(self: *const EcsWorld, entity: Entity) ?u32 {
        if (entity == INVALID_ENTITY) return null;
        const slot: u32 = @truncate(entity);
        if (slot < MAX_ENTITIES and self.entities[slot].alive) {
            return slot;
        }
        return null;
    }

    fn getOrCreateSlotIndex(self: *EcsWorld, entity: Entity) ?u32 {
        if (entity == INVALID_ENTITY) return null;
        const slot: u32 = @truncate(entity);
        if (slot >= MAX_ENTITIES) return null;
        var rec = &self.entities[slot];
        if (!rec.alive) {
            rec.alive = true;
            rec.comp_mask = 0;
            rec.comp_mask_ext = 0;
            rec.name_len = 0;
        }
        return slot;
    }

    pub fn setSystemContext(self: *EcsWorld, context: ?*anyopaque) void {
        self.system_context = context;
    }

    pub fn progress(self: *EcsWorld, dt: f32) bool {
        var matched_buf: [256]Entity = undefined;
        for (self.systems[0..self.system_count]) |*sys| {
            if (!sys.enabled) continue;
            if (sys.callback) |cb| {
                const count = self.queryEntities(sys.query_components[0..sys.query_comp_count], &matched_buf);
                for (matched_buf[0..count]) |e| {
                    cb(self, e, dt, self.system_context);
                }
            }
        }
        return true;
    }

    /// Initializes a specific unified slot index (`0 .. MAX_ENTITIES - 1`) in the ECS world.
    pub fn initSlot(self: *EcsWorld, slot: u32, name: ?[:0]const u8) Entity {
        if (slot >= MAX_ENTITIES) return INVALID_ENTITY;
        var rec = &self.entities[slot];
        rec.alive = true;
        rec.comp_mask = 0;
        rec.comp_mask_ext = 0;
        rec.name_len = 0;
        @memset(&rec.name, 0);
        if (name) |n| {
            const len = @min(n.len, 64);
            @memcpy(rec.name[0..len], n[0..len]);
            rec.name_len = len;
        }
        return @as(Entity, slot);
    }

    pub fn newEntity(self: *EcsWorld, name: ?[:0]const u8) Entity {
        for (self.entities[1..], 1..) |*rec, idx| {
            if (!rec.alive) {
                return self.initSlot(@intCast(idx), name);
            }
        }
        if (!self.entities[0].alive) {
            return self.initSlot(0, name);
        }
        return INVALID_ENTITY;
    }

    pub fn deleteEntity(self: *EcsWorld, entity: Entity) void {
        const slot = self.getSlotIndex(entity) orelse return;
        var rec = &self.entities[slot];
        rec.alive = false;
        rec.comp_mask = 0;
        rec.comp_mask_ext = 0;
        rec.name_len = 0;
        rec.generation +%= 1;
        if (rec.generation == 0) rec.generation = 1;
    }

    pub fn isAlive(self: *EcsWorld, entity: Entity) bool {
        return self.getSlotIndex(entity) != null;
    }

    pub fn setPosition(self: *EcsWorld, entity: Entity, pos: Position) void {
        _ = self.setComponentData(entity, self.id_pos, std.mem.asBytes(&pos));
    }

    pub fn getPosition(self: *EcsWorld, entity: Entity) ?*const Position {
        return self.getComponentPtrConst(entity, self.id_pos, Position);
    }

    pub fn setRotation(self: *EcsWorld, entity: Entity, rot: Rotation) void {
        _ = self.setComponentData(entity, self.id_rot, std.mem.asBytes(&rot));
    }

    pub fn getRotation(self: *EcsWorld, entity: Entity) ?*const Rotation {
        return self.getComponentPtrConst(entity, self.id_rot, Rotation);
    }

    pub fn setScale(self: *EcsWorld, entity: Entity, sc: Scale) void {
        _ = self.setComponentData(entity, self.id_scale, std.mem.asBytes(&sc));
    }

    pub fn getScale(self: *EcsWorld, entity: Entity) ?*const Scale {
        return self.getComponentPtrConst(entity, self.id_scale, Scale);
    }

    pub fn setVelocity(self: *EcsWorld, entity: Entity, vel: Velocity) void {
        _ = self.setComponentData(entity, self.id_vel, std.mem.asBytes(&vel));
    }

    pub fn getVelocity(self: *EcsWorld, entity: Entity) ?*const Velocity {
        return self.getComponentPtrConst(entity, self.id_vel, Velocity);
    }

    pub fn setMesh(self: *EcsWorld, entity: Entity, mesh: PrimitiveMeshRender) void {
        _ = self.setComponentData(entity, self.id_mesh, std.mem.asBytes(&mesh));
    }

    pub fn getMesh(self: *EcsWorld, entity: Entity) ?*const PrimitiveMeshRender {
        return self.getComponentPtrConst(entity, self.id_mesh, PrimitiveMeshRender);
    }

    pub fn setPhysicsBody(self: *EcsWorld, entity: Entity, body: PhysicsBody) void {
        _ = self.setComponentData(entity, self.id_body, std.mem.asBytes(&body));
    }

    pub fn getPhysicsBody(self: *EcsWorld, entity: Entity) ?*const PhysicsBody {
        return self.getComponentPtrConst(entity, self.id_body, PhysicsBody);
    }

    pub fn setScript(self: *EcsWorld, entity: Entity, script: ScriptComponent) void {
        _ = self.setComponentData(entity, self.id_script, std.mem.asBytes(&script));
    }

    pub fn getScript(self: *EcsWorld, entity: Entity) ?*const ScriptComponent {
        return self.getComponentPtrConst(entity, self.id_script, ScriptComponent);
    }

    pub fn hasScript(self: *EcsWorld, entity: Entity) bool {
        return self.hasComponent(entity, self.id_script);
    }

    pub fn removeScript(self: *EcsWorld, entity: Entity) void {
        self.removeComponent(entity, self.id_script);
    }

    pub fn spawnMeshEntity(self: *EcsWorld, pos: Position, sc: Scale, mesh: PrimitiveMeshRender) Entity {
        const e = self.newEntity(null);
        self.setPosition(e, pos);
        self.setScale(e, sc);
        self.setMesh(e, mesh);
        return e;
    }

    pub fn spawnPhysicsEntity(self: *EcsWorld, pos: Position, sc: Scale, mesh: PrimitiveMeshRender, body: PhysicsBody) Entity {
        const e = self.newEntity(null);
        self.setPosition(e, pos);
        self.setScale(e, sc);
        self.setMesh(e, mesh);
        self.setPhysicsBody(e, body);
        return e;
    }

    /// Queries dynamic Jolt bodies and writes updated transforms into ECS Position / Rotation components
    pub fn syncFromPhysics(self: *EcsWorld, physics: *physics_mod.PhysicsWorld) void {
        const body_col_idx: usize = @intCast(self.id_body - 1);
        for (self.entities, 0..) |*rec, slot| {
            if (!rec.alive or !rec.hasBit(body_col_idx)) continue;
            const handle: Entity = @intCast(slot);
            const body = self.getPhysicsBody(handle) orelse continue;
            if (!body.is_dynamic) continue;
            const pos = physics.getPosition(body.body_id);
            const rot = physics.getRotation(body.body_id);
            self.setPosition(handle, .{ .x = pos[0], .y = pos[1], .z = pos[2] });
            self.setRotation(handle, .{ .x = rot[0], .y = rot[1], .z = rot[2] });
        }
    }

    /// Iterates (Position, Rotation, Scale, MeshRender) entities and prepares render instances in Scene
    pub fn syncToScene(self: *EcsWorld, scene: *scene_mod.Scene) void {
        const mesh_col_idx: usize = @intCast(self.id_mesh - 1);
        for (self.entities, 0..) |*rec, slot| {
            if (!rec.alive or !rec.hasBit(mesh_col_idx)) continue;
            const handle: Entity = @intCast(slot);
            const mesh = self.getMesh(handle) orelse continue;
            if (!mesh.visible) continue;
            const pos = self.getPosition(handle) orelse continue;
            const rot = self.getRotation(handle) orelse &Rotation{};
            const sc = self.getScale(handle) orelse &Scale{};
            const p_type: scene_mod.PrimitiveType = @enumFromInt(mesh.primitive_type % 5);
            _ = scene.addObject(.{
                .primitive_type = p_type,
                .position = .{ pos.x, pos.y, pos.z },
                .rotation = .{ rot.x, rot.y, rot.z },
                .scale = .{ sc.x, sc.y, sc.z },
                .material = .{
                    .base_color = mesh.color,
                    .metallic = mesh.metallic,
                    .roughness = mesh.roughness,
                },
                .visible = true,
            });
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Dynamic UGC Component & System Operations
    // ---------------------------------------------------------------------------------------------

    pub fn registerDynamicComponent(self: *EcsWorld, name: []const u8, size: usize, alignment: usize) ComponentId {
        for (self.dynamic_components[0..self.dynamic_component_count]) |dc| {
            if (std.mem.eql(u8, dc.name[0..dc.name_len], name)) {
                return dc.id;
            }
        }

        if (std.mem.eql(u8, name, "Position")) return self.id_pos;
        if (std.mem.eql(u8, name, "Rotation")) return self.id_rot;
        if (std.mem.eql(u8, name, "Scale")) return self.id_scale;
        if (std.mem.eql(u8, name, "Velocity")) return self.id_vel;
        if (std.mem.eql(u8, name, "MeshRender")) return self.id_mesh;
        if (std.mem.eql(u8, name, "PhysicsBody")) return self.id_body;
        if (std.mem.eql(u8, name, "ScriptComponent")) return self.id_script;

        if (self.dynamic_component_count >= MAX_DYNAMIC_COMPONENTS or self.column_count >= MAX_COMPONENTS) {
            return 0;
        }

        const copy_len = @min(name.len, 64);
        const comp_align = if (alignment == 0) 1 else alignment;
        const col_idx = self.column_count;
        const id: ComponentId = @intCast(col_idx + 1);

        var col = ComponentColumn{
            .id = id,
            .name_len = copy_len,
            .size = size,
            .alignment = comp_align,
        };
        @memcpy(col.name[0..copy_len], name[0..copy_len]);
        _ = col.ensureAllocated(self.allocator);
        self.columns[col_idx] = col;
        self.column_count += 1;

        const idx = self.dynamic_component_count;
        self.dynamic_components[idx] = .{
            .id = id,
            .name = [_]u8{0} ** 64,
            .name_len = copy_len,
            .size = size,
            .alignment = comp_align,
        };
        @memcpy(self.dynamic_components[idx].name[0..copy_len], name[0..copy_len]);
        self.dynamic_component_count += 1;
        return id;
    }

    pub fn getComponentIdByName(self: *const EcsWorld, name: []const u8) ?ComponentId {
        for (self.dynamic_components[0..self.dynamic_component_count]) |dc| {
            if (std.mem.eql(u8, dc.name[0..dc.name_len], name)) {
                return dc.id;
            }
        }
        if (std.mem.eql(u8, name, "Position")) return self.id_pos;
        if (std.mem.eql(u8, name, "Rotation")) return self.id_rot;
        if (std.mem.eql(u8, name, "Scale")) return self.id_scale;
        if (std.mem.eql(u8, name, "Velocity")) return self.id_vel;
        if (std.mem.eql(u8, name, "MeshRender")) return self.id_mesh;
        if (std.mem.eql(u8, name, "PhysicsBody")) return self.id_body;
        if (std.mem.eql(u8, name, "ScriptComponent")) return self.id_script;
        return null;
    }

    pub fn getComponentSize(self: *const EcsWorld, comp_id: ComponentId) usize {
        if (comp_id == 0 or comp_id > self.column_count) return 0;
        return self.columns[@intCast(comp_id - 1)].size;
    }

    pub fn getBuiltinComponentId(self: *const EcsWorld, builtin_type: u32) ?ComponentId {
        return switch (builtin_type) {
            0 => self.id_pos,
            1 => self.id_rot,
            2 => self.id_scale,
            3 => self.id_vel,
            4 => self.id_mesh,
            5 => self.id_body,
            6 => self.id_script,
            else => null,
        };
    }

    fn getComponentPtrConst(self: *const EcsWorld, entity: Entity, comp_id: ComponentId, comptime T: type) ?*const T {
        if (comp_id == 0 or comp_id > self.column_count) return null;
        const slot = self.getSlotIndex(entity) orelse return null;
        const col_idx: usize = @intCast(comp_id - 1);
        if (!self.entities[slot].hasBit(col_idx)) return null;
        const bytes = self.columns[col_idx].getSlotBytesConst(slot) orelse return null;
        if (bytes.len < @sizeOf(T)) return null;
        return @ptrCast(@alignCast(bytes.ptr));
    }

    pub fn setComponentData(self: *EcsWorld, entity: Entity, comp_id: ComponentId, data: []const u8) bool {
        if (entity == INVALID_ENTITY or comp_id == 0 or comp_id > self.column_count) return false;
        const slot = self.getOrCreateSlotIndex(entity) orelse return false;
        const col_idx: usize = @intCast(comp_id - 1);
        var col = &self.columns[col_idx];
        const dest = col.getSlotBytes(self.allocator, slot) orelse return false;
        @memset(dest, 0);
        const copy_len = @min(data.len, dest.len);
        if (copy_len > 0) {
            @memcpy(dest[0..copy_len], data[0..copy_len]);
        }
        self.entities[slot].setBit(col_idx);
        return true;
    }

    pub fn getComponentData(self: *EcsWorld, entity: Entity, comp_id: ComponentId, out_buffer: []u8) ?usize {
        if (entity == INVALID_ENTITY or comp_id == 0 or comp_id > self.column_count) return null;
        const slot = self.getSlotIndex(entity) orelse return null;
        const col_idx: usize = @intCast(comp_id - 1);
        if (!self.entities[slot].hasBit(col_idx)) return null;
        const src = self.columns[col_idx].getSlotBytesConst(slot) orelse return null;
        const copy_len = @min(out_buffer.len, src.len);
        if (copy_len > 0) {
            @memcpy(out_buffer[0..copy_len], src[0..copy_len]);
        }
        return copy_len;
    }

    pub fn hasComponent(self: *EcsWorld, entity: Entity, comp_id: ComponentId) bool {
        if (entity == INVALID_ENTITY or comp_id == 0 or comp_id > self.column_count) return false;
        const slot = self.getSlotIndex(entity) orelse return false;
        const col_idx: usize = @intCast(comp_id - 1);
        return self.entities[slot].hasBit(col_idx);
    }

    pub fn removeComponent(self: *EcsWorld, entity: Entity, comp_id: ComponentId) void {
        if (entity == INVALID_ENTITY or comp_id == 0 or comp_id > self.column_count) return;
        const slot = self.getSlotIndex(entity) orelse return;
        const col_idx: usize = @intCast(comp_id - 1);
        self.entities[slot].clearBit(col_idx);
    }

    pub fn queryEntities(self: *EcsWorld, comp_ids: []const ComponentId, out_entities: []Entity) usize {
        if (comp_ids.len == 0 or out_entities.len == 0) return 0;

        var req_mask: u128 = 0;
        var req_mask_ext: u16 = 0;
        for (comp_ids) |cid| {
            if (cid == 0 or cid > self.column_count) return 0;
            const col_idx: usize = @intCast(cid - 1);
            if (col_idx < 128) {
                req_mask |= (@as(u128, 1) << @intCast(col_idx));
            } else if (col_idx < 144) {
                req_mask_ext |= (@as(u16, 1) << @intCast(col_idx - 128));
            }
        }

        var matched: usize = 0;
        for (self.entities, 0..) |*rec, slot| {
            if (!rec.alive) continue;
            if ((rec.comp_mask & req_mask) == req_mask and (rec.comp_mask_ext & req_mask_ext) == req_mask_ext) {
                if (matched < out_entities.len) {
                    out_entities[matched] = @intCast(slot);
                }
                matched += 1;
            }
        }
        return @min(matched, out_entities.len);
    }

    pub fn countEntities(self: *EcsWorld, comp_ids: []const ComponentId) usize {
        if (comp_ids.len == 0) return 0;

        var req_mask: u128 = 0;
        var req_mask_ext: u16 = 0;
        for (comp_ids) |cid| {
            if (cid == 0 or cid > self.column_count) return 0;
            const col_idx: usize = @intCast(cid - 1);
            if (col_idx < 128) {
                req_mask |= (@as(u128, 1) << @intCast(col_idx));
            } else if (col_idx < 144) {
                req_mask_ext |= (@as(u16, 1) << @intCast(col_idx - 128));
            }
        }

        var matched: usize = 0;
        for (self.entities) |*rec| {
            if (!rec.alive) continue;
            if ((rec.comp_mask & req_mask) == req_mask and (rec.comp_mask_ext & req_mask_ext) == req_mask_ext) {
                matched += 1;
            }
        }
        return matched;
    }

    pub fn registerSystem(self: *EcsWorld, name: []const u8, comp_ids: []const ComponentId) u32 {
        return self.registerNativeSystem(name, comp_ids, null);
    }

    pub fn registerNativeSystem(self: *EcsWorld, name: []const u8, comp_ids: []const ComponentId, callback: ?NativeSystemFn) u32 {
        for (self.systems[0..self.system_count]) |*s| {
            if (std.mem.eql(u8, s.name[0..s.name_len], name)) {
                if (callback != null) s.callback = callback;
                return s.id;
            }
        }
        if (self.system_count >= MAX_DYNAMIC_SYSTEMS) return 0;
        const sys_id: u32 = @intCast(self.system_count + 1);
        var sys = SystemInfo{
            .id = sys_id,
            .name_len = @min(name.len, 64),
            .query_comp_count = @min(comp_ids.len, 8),
            .callback = callback,
            .enabled = true,
        };
        @memcpy(sys.name[0..sys.name_len], name[0..sys.name_len]);
        for (comp_ids[0..sys.query_comp_count], 0..) |cid, i| {
            sys.query_components[i] = cid;
        }

        var name_buf = [_]u8{0} ** 65;
        @memcpy(name_buf[0..sys.name_len], name[0..sys.name_len]);
        name_buf[sys.name_len] = 0;

        sys.flecs_system_entity = self.newEntity(name_buf[0..sys.name_len :0]);

        self.systems[self.system_count] = sys;
        self.system_count += 1;
        return sys_id;
    }

    pub fn setSystemEnabled(self: *EcsWorld, sys_id: u32, enabled: bool) bool {
        if (sys_id == 0 or sys_id > self.system_count) return false;
        self.systems[sys_id - 1].enabled = enabled;
        return true;
    }

    pub fn getSystem(self: *EcsWorld, sys_id: u32) ?*SystemInfo {
        if (sys_id == 0 or sys_id > self.system_count) return null;
        return &self.systems[sys_id - 1];
    }
};

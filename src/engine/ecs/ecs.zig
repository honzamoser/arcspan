//! Built-in Zig Entity Component System (ECS)
//! High-performance, pure-Zig ECS implementation supporting entities, built-in and dynamic
//! components, multi-component queries, native and guest systems, and Jolt/Scene synchronization.
//! Entity IDs are unified 1:1 with shared ECS entity slots (`0 .. MAX_ENTITIES - 1`).

const std = @import("std");
const physics_mod = @import("../physics/jolt.zig");
const scene_mod = @import("../renderer/scene.zig");
const shared_state = @import("../state/game_state.zig");
const sh = @import("shared_math");

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

pub const Transform = extern struct { position: sh.Vec3 = .zero(), rotation: sh.Vec3 = .zero(), scale: sh.Vec3 = .init(1.0, 1.0, 1.0) };

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

pub const Hierarchy = extern struct {
    parent_id: u64 = 0xFFFF_FFFF_FFFF_FFFF,
};

pub const Collider = extern struct {
    collider_type: u32 = 0,
    _pad: u32 = 0,
    extents: sh.Vec3 = .{ .x = 0.5, .y = 0.5, .z = 0.5 },
};

pub const Material = extern struct {
    metallic: f32 = 0.0,
    roughness: f32 = 0.5,
    emissive: f32 = 0.0,
    shading_model: u32 = 0,
};

pub const Metadata = extern struct {
    entity_type: u32 = 0,
    layer: u32 = 0,
    tag: [16]u8 = [_]u8{0} ** 16,
};

pub const Entity = u64;
pub const INVALID_ENTITY: Entity = 0xFFFF_FFFF_FFFF_FFFF;
pub const ComponentId = u64;
pub const SystemId = u32;

pub const MAX_ENTITIES: usize = shared_state.ECS_MAX_ENTITIES;
pub const MAX_COMPONENTS: usize = shared_state.ECS_MAX_COMPONENTS; // 7 built-in + 128 dynamic
pub const MAX_DYNAMIC_COMPONENTS: usize = shared_state.ECS_MAX_DYNAMIC_COMPONENTS;
pub const MAX_DYNAMIC_SYSTEMS: usize = 64;

pub const DynamicComponent = shared_state.SharedEcsColumn;

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

const EntityRecord = shared_state.SharedEcsEntity;

inline fn hasBit(self: *const EntityRecord, comp_idx: usize) bool {
    if (comp_idx < 128) return (self.comp_mask & (@as(u128, 1) << @intCast(comp_idx))) != 0;
    if (comp_idx < 144) return (self.comp_mask_ext & (@as(u16, 1) << @intCast(comp_idx - 128))) != 0;
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

pub const EcsWorld = struct {
    shared: ?*shared_state.SharedEcsWorld = null,
    id_mesh: ComponentId,
    id_phys: ComponentId,
    id_transform: ComponentId,
    id_camera: ComponentId,
    id_hierarchy: ComponentId,
    id_collider: ComponentId,
    id_material: ComponentId,
    id_metadata: ComponentId,
    dirty_transforms: [MAX_ENTITIES]bool = [_]bool{false} ** MAX_ENTITIES,

    systems: [MAX_DYNAMIC_SYSTEMS]SystemInfo = [_]SystemInfo{.{}} ** MAX_DYNAMIC_SYSTEMS,
    system_count: usize = 0,
    system_context: ?*anyopaque = null,

    pub fn init() !EcsWorld {
        const result = EcsWorld{
            .id_mesh = 0,
            .id_phys = 0,
            .id_transform = 0,
            .id_camera = 0,
            .id_hierarchy = 0,
            .id_collider = 0,
            .id_material = 0,
            .id_metadata = 0,
        };
        return result;
    }

    pub fn deinit(self: *EcsWorld) void {
        self.shared = null;
    }

    fn registerColumn(self: *EcsWorld, name: []const u8, size: usize, alignment: usize) ComponentId {
        const shared = self.sharedWorld() orelse return 0;
        if (shared.column_count >= MAX_COMPONENTS) return 0;
        const col_idx: usize = @intCast(shared.column_count);
        const id: ComponentId = @intCast(col_idx + 1);
        const copy_len = @min(name.len, 64);
        const comp_align = @max(alignment, 1);
        const stride = alignUp(size, comp_align);
        const bytes = stride * MAX_ENTITIES;
        const offset = alignUp(shared.arena_used, comp_align);
        if (offset > shared.arena.len or bytes > shared.arena.len - offset) return 0;
        var col = &shared.columns[col_idx];
        col.* = .{
            .id = id,
            .name_len = @intCast(copy_len),
            .size = @intCast(size),
            .alignment = @intCast(comp_align),
            .stride = @intCast(stride),
            .data_offset = @intCast(offset),
        };
        @memcpy(col.name[0..copy_len], name[0..copy_len]);
        shared.arena_used = @intCast(offset + bytes);
        shared.column_count += 1;
        return id;
    }

    pub fn bindSharedWorld(self: *EcsWorld, shared: *shared_state.SharedEcsWorld) void {
        self.shared = shared;
        shared.* = .{};
        self.id_transform = self.registerColumn("Transform", @sizeOf(Transform), @alignOf(Transform));
        self.id_mesh = self.registerColumn("MeshRender", @sizeOf(PrimitiveMeshRender), @alignOf(PrimitiveMeshRender));
        self.id_phys = self.registerColumn("PhysicsBody", @sizeOf(PhysicsBody), @alignOf(PhysicsBody));
        self.id_hierarchy = self.registerColumn("Hierarchy", @sizeOf(Hierarchy), @alignOf(Hierarchy));
        self.id_collider = self.registerColumn("Collider", @sizeOf(Collider), @alignOf(Collider));
        self.id_material = self.registerColumn("Material", @sizeOf(Material), @alignOf(Material));
        self.id_metadata = self.registerColumn("Metadata", @sizeOf(Metadata), @alignOf(Metadata));
        self.id_camera = self.registerDynamicComponent("CameraComponent", @sizeOf(NativeCameraComponent), @alignOf(NativeCameraComponent));

        if (self.id_camera != 0) {
            _ = self.registerNativeSystem("CameraSystem", &[_]u64{self.id_camera}, NativeCameraSystem);
        }
    }

    /// Reattaches the native facade after WASM memory relocation without clearing shared data.
    pub fn attachSharedWorld(self: *EcsWorld, shared: *shared_state.SharedEcsWorld) void {
        self.shared = shared;
        if (shared.magic != 0x45435357 or shared.version != 1 or shared.column_count == 0) {
            self.bindSharedWorld(shared);
        }
    }

    fn sharedWorld(self: *const EcsWorld) ?*shared_state.SharedEcsWorld {
        return self.shared;
    }

    fn alignUp(value: usize, alignment: usize) usize {
        const a = @max(alignment, 1);
        return (value + a - 1) & ~(a - 1);
    }

    fn column(self: *const EcsWorld, index: usize) ?*const shared_state.SharedEcsColumn {
        const w = self.sharedWorld() orelse return null;
        if (index >= w.column_count or index >= MAX_COMPONENTS) return null;
        return &w.columns[index];
    }

    fn mutableColumn(self: *EcsWorld, index: usize) ?*shared_state.SharedEcsColumn {
        const w = self.sharedWorld() orelse return null;
        if (index >= w.column_count or index >= MAX_COMPONENTS) return null;
        return &w.columns[index];
    }

    fn componentBytes(self: *const EcsWorld, col: *const shared_state.SharedEcsColumn, slot: usize) ?[]u8 {
        const w = self.sharedWorld() orelse return null;
        if (slot >= MAX_ENTITIES) return null;
        const start = @as(usize, col.data_offset) + slot * @as(usize, col.stride);
        const end = start + col.size;
        if (end > w.arena.len) return null;
        return w.arena[start..end];
    }

    fn mutableComponentBytes(self: *EcsWorld, col: *const shared_state.SharedEcsColumn, slot: usize) ?[]u8 {
        const w = self.sharedWorld() orelse return null;
        if (slot >= MAX_ENTITIES) return null;
        const start = @as(usize, col.data_offset) + slot * @as(usize, col.stride);
        const end = start + col.size;
        if (end > w.arena.len) return null;
        return w.arena[start..end];
    }

    fn entities(self: *const EcsWorld) ?[]const EntityRecord {
        const w = self.sharedWorld() orelse return null;
        return w.entities[0..];
    }

    fn mutableEntities(self: *EcsWorld) ?[]EntityRecord {
        const w = self.sharedWorld() orelse return null;
        return w.entities[0..];
    }

    fn getSlotIndex(self: *const EcsWorld, entity: Entity) ?u32 {
        if (entity == INVALID_ENTITY) return null;
        const slot: u32 = @truncate(entity);
        const records = self.entities() orelse return null;
        if (slot < MAX_ENTITIES and records[slot].alive != 0) {
            return slot;
        }
        return null;
    }

    fn getOrCreateSlotIndex(self: *EcsWorld, entity: Entity) ?u32 {
        if (entity == INVALID_ENTITY) return null;
        const slot: u32 = @truncate(entity);
        if (slot >= MAX_ENTITIES) return null;
        const records = self.mutableEntities() orelse return null;
        var rec = &records[slot];
        if (rec.alive == 0) {
            rec.alive = 1;
            rec.comp_mask = 0;
            rec.comp_mask_ext = 0;
        }
        return slot;
    }

    pub fn setSystemContext(self: *EcsWorld, context: ?*anyopaque) void {
        self.system_context = context;
    }

    pub fn progress(self: *EcsWorld, dt: f32) bool {
        var matched_buf: [MAX_ENTITIES]Entity = undefined;
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
        const records = self.mutableEntities() orelse return INVALID_ENTITY;
        var rec = &records[slot];
        rec.alive = 1;
        rec.comp_mask = 0;
        rec.comp_mask_ext = 0;
        _ = name;
        return @as(Entity, slot);
    }

    pub fn newEntity(self: *EcsWorld, name: ?[:0]const u8) Entity {
        const records = self.entities() orelse return INVALID_ENTITY;
        for (records[1..], 1..) |*rec, idx| {
            if (rec.alive == 0) {
                return self.initSlot(@intCast(idx), name);
            }
        }
        if (records[0].alive == 0) {
            return self.initSlot(0, name);
        }
        return INVALID_ENTITY;
    }

    pub fn deleteEntity(self: *EcsWorld, entity: Entity) void {
        const slot = self.getSlotIndex(entity) orelse return;
        const records = self.mutableEntities() orelse return;
        var rec = &records[slot];
        rec.alive = 0;
        rec.comp_mask = 0;
        rec.comp_mask_ext = 0;
        rec.generation +%= 1;
        if (rec.generation == 0) rec.generation = 1;
    }

    pub fn isAlive(self: *EcsWorld, entity: Entity) bool {
        return self.getSlotIndex(entity) != null;
    }

    pub fn setPosition(self: *EcsWorld, entity: Entity, pos: sh.Vec3) void {
        const current = self.getComponentPtrMutable(entity, self.id_transform, Transform);
        if (current) |t| {
            t.position = pos;
        } else {
            var transform = Transform{};
            transform.position = pos;
            _ = self.setComponentData(entity, self.id_transform, std.mem.asBytes(&transform));
        }
        if (entity < MAX_ENTITIES) self.dirty_transforms[@intCast(entity)] = true;
    }

    pub fn getPosition(self: *EcsWorld, entity: Entity) ?sh.Vec3 {
        if (self.getComponentPtrConst(entity, self.id_transform, Transform)) |t| {
            return t.*.position;
        }

        return null;
    }

    pub fn setRotation(self: *EcsWorld, entity: Entity, rot: sh.Vec3) void {
        const current = self.getComponentPtrMutable(entity, self.id_transform, Transform);
        if (current) |t| {
            t.rotation = rot;
        } else {
            var transform = Transform{};
            transform.rotation = rot;
            _ = self.setComponentData(entity, self.id_transform, std.mem.asBytes(&transform));
        }
        if (entity < MAX_ENTITIES) self.dirty_transforms[@intCast(entity)] = true;
    }

    pub fn getRotation(self: *EcsWorld, entity: Entity) ?sh.Vec3 {
        if (self.getComponentPtrConst(entity, self.id_transform, Transform)) |t| {
            return t.*.rotation;
        }

        return null;
    }

    pub fn setScale(self: *EcsWorld, entity: Entity, sc: sh.Vec3) void {
        const current = self.getComponentPtrMutable(entity, self.id_transform, Transform);
        if (current) |t| {
            t.scale = sc;
        } else {
            var transform = Transform{};
            transform.scale = sc;
            _ = self.setComponentData(entity, self.id_transform, std.mem.asBytes(&transform));
        }
    }

    pub fn setHierarchy(self: *EcsWorld, entity: Entity, hierarchy: Hierarchy) void {
        _ = self.setComponentData(entity, self.id_hierarchy, std.mem.asBytes(&hierarchy));
    }

    pub fn getHierarchy(self: *EcsWorld, entity: Entity) ?*const Hierarchy {
        return self.getComponentPtrConst(entity, self.id_hierarchy, Hierarchy);
    }

    pub fn setCollider(self: *EcsWorld, entity: Entity, collider: Collider) void {
        _ = self.setComponentData(entity, self.id_collider, std.mem.asBytes(&collider));
    }

    pub fn setMaterial(self: *EcsWorld, entity: Entity, material: Material) void {
        _ = self.setComponentData(entity, self.id_material, std.mem.asBytes(&material));
    }

    pub fn setMetadata(self: *EcsWorld, entity: Entity, metadata: Metadata) void {
        _ = self.setComponentData(entity, self.id_metadata, std.mem.asBytes(&metadata));
    }

    pub fn getScale(self: *EcsWorld, entity: Entity) ?sh.Vec3 {
        if (self.getComponentPtrConst(entity, self.id_transform, Transform)) |t| {
            return t.*.scale;
        }

        return null;
    }

    pub fn setMesh(self: *EcsWorld, entity: Entity, mesh: PrimitiveMeshRender) void {
        _ = self.setComponentData(entity, self.id_mesh, std.mem.asBytes(&mesh));
    }

    pub fn getMesh(self: *EcsWorld, entity: Entity) ?*const PrimitiveMeshRender {
        return self.getComponentPtrConst(entity, self.id_mesh, PrimitiveMeshRender);
    }

    pub fn setPhysicsBody(self: *EcsWorld, entity: Entity, body: PhysicsBody) void {
        _ = self.setComponentData(entity, self.id_phys, std.mem.asBytes(&body));
    }

    pub fn getPhysicsBody(self: *EcsWorld, entity: Entity) ?*const PhysicsBody {
        return self.getComponentPtrConst(entity, self.id_phys, PhysicsBody);
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
        const body_col_idx: usize = @intCast(self.id_phys - 1);

        // std.debug.print("Active etnties in syncFromPhysics: {d}\n", .{self.entities.len});

        const records = self.entities() orelse return;
        for (records, 0..) |*rec, slot| {
            if (rec.alive == 0 or !hasBit(rec, body_col_idx)) continue;

            const handle: Entity = @intCast(slot);
            const body = self.getPhysicsBody(handle) orelse continue;
            if (!body.is_dynamic) continue;
            const pos = physics.getPosition(body.body_id);
            const rot = physics.getRotation(body.body_id);
            if (self.getComponentPtrMutable(handle, self.id_transform, Transform)) |transform| {
                transform.position = .{ .x = pos[0], .y = pos[1], .z = pos[2] };
                transform.rotation = .{ .x = rot[0], .y = rot[1], .z = rot[2] };
            }
        }
    }

    pub fn syncDirtyToPhysics(self: *EcsWorld, physics: *physics_mod.PhysicsWorld) void {
        const records = self.entities() orelse return;
        for (records, 0..) |*rec, slot| {
            if (rec.alive == 0 or !self.dirty_transforms[slot]) continue;
            self.dirty_transforms[slot] = false;
            const entity: Entity = @intCast(slot);
            const body = self.getPhysicsBody(entity) orelse continue;
            const transform = self.getComponentPtrConst(entity, self.id_transform, Transform) orelse continue;
            physics.setPositionAndRotation(body.body_id, .{
                transform.position.x,
                transform.position.y,
                transform.position.z,
            }, .{
                transform.rotation.x,
                transform.rotation.y,
                transform.rotation.z,
            });
        }
    }

    /// Iterates (Position, Rotation, Scale, MeshRender) entities and prepares render instances in Scene
    pub fn syncToScene(self: *EcsWorld, scene: *scene_mod.Scene) void {
        const mesh_col_idx: usize = @intCast(self.id_mesh - 1);
        const records = self.entities() orelse return;
        scene.beginObjectBatch();
        for (records, 0..) |*rec, slot| {
            if (rec.alive == 0 or !hasBit(rec, mesh_col_idx)) continue;
            const handle: Entity = @intCast(slot);
            const mesh = self.getMesh(handle) orelse continue;
            if (!mesh.visible) continue;
            const pos = self.getPosition(handle) orelse continue;
            const rot = self.getRotation(handle) orelse sh.Vec3{ .x = 0.0, .y = 0.0, .z = 0.0 };
            const sc = self.getScale(handle) orelse sh.Vec3{ .x = 1.0, .y = 1.0, .z = 1.0 };
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
        scene.endObjectBatch();
    }

    // ---------------------------------------------------------------------------------------------
    // Dynamic UGC Component & System Operations
    // ---------------------------------------------------------------------------------------------

    pub fn registerDynamicComponent(
        self: *EcsWorld,
        name: []const u8,
        size: usize,
        alignment: usize,
    ) ComponentId {
        const shared = self.sharedWorld() orelse return 0;
        const count: usize = @intCast(@min(shared.column_count, MAX_COMPONENTS));

        for (shared.columns[0..count]) |_column| {
            if (std.mem.eql(u8, _column.name[0.._column.name_len], name)) {
                return _column.id;
            }
        }

        if (count >= MAX_COMPONENTS) return 0;

        return self.registerColumn(
            name,
            size,
            if (alignment == 0) 1 else alignment,
        );
    }

    pub fn getComponentIdByName(self: *const EcsWorld, name: []const u8) ?ComponentId {
        const shared = self.sharedWorld() orelse return 0;
        const count: usize = @intCast(@min(shared.column_count, MAX_COMPONENTS));

        for (shared.columns[0..count]) |_column| {
            if (std.mem.eql(u8, _column.name[0.._column.name_len], name)) {
                return _column.id;
            }
        }

        return null;
    }

    pub fn getComponentSize(self: *const EcsWorld, comp_id: ComponentId) usize {
        const shared = self.sharedWorld() orelse return 0;
        if (comp_id == 0 or comp_id > shared.column_count) return 0;
        return shared.columns[@intCast(comp_id - 1)].size;
    }

    pub fn getBuiltinComponentId(self: *const EcsWorld, builtin_type: u32) ?ComponentId {
        switch (builtin_type) {
            0 => return self.id_transform,
            1 => return self.id_mesh,
            2 => return self.id_phys,
            3 => return self.id_camera,
            4 => return self.id_hierarchy,
            5 => return self.id_collider,
            6 => return self.id_material,
            7 => return self.id_metadata,
            else => return null,
        }
    }

    pub fn getComponentPtrConst(self: *const EcsWorld, entity: Entity, comp_id: ComponentId, comptime T: type) ?*const T {
        const shared = self.sharedWorld() orelse return null;
        if (comp_id == 0 or comp_id > shared.column_count) return null;
        const slot = self.getSlotIndex(entity) orelse return null;
        const col_idx: usize = @intCast(comp_id - 1);
        const records = self.entities() orelse return null;
        if (!hasBit(&records[slot], col_idx)) return null;
        const col = self.column(col_idx) orelse return null;
        const bytes = self.componentBytes(col, slot) orelse return null;
        if (bytes.len < @sizeOf(T)) return null;
        return @ptrCast(@alignCast(bytes.ptr));
    }

    fn getComponentPtrMutable(self: *EcsWorld, entity: Entity, comp_id: ComponentId, comptime T: type) ?*T {
        const shared = self.sharedWorld() orelse return null;
        if (comp_id == 0 or comp_id > shared.column_count) return null;
        const slot = self.getSlotIndex(entity) orelse return null;
        const col_idx: usize = @intCast(comp_id - 1);
        const records = self.entities() orelse return null;
        if (!hasBit(&records[slot], col_idx)) return null;
        const col = self.column(col_idx) orelse return null;
        const bytes = self.mutableComponentBytes(col, slot) orelse return null;
        if (bytes.len < @sizeOf(T)) return null;
        return @ptrCast(@alignCast(bytes.ptr));
    }

    pub fn setComponentData(self: *EcsWorld, entity: Entity, comp_id: ComponentId, data: []const u8) bool {
        const shared = self.sharedWorld() orelse return false;
        if (entity == INVALID_ENTITY or comp_id == 0 or comp_id > shared.column_count) return false;
        const slot = self.getOrCreateSlotIndex(entity) orelse return false;
        const col_idx: usize = @intCast(comp_id - 1);
        const col = self.column(col_idx) orelse return false;
        const dest = self.mutableComponentBytes(col, slot) orelse return false;
        @memset(dest, 0);
        const copy_len = @min(data.len, dest.len);
        if (copy_len > 0) {
            @memcpy(dest[0..copy_len], data[0..copy_len]);
        }
        const records = self.mutableEntities() orelse return false;
        setBit(&records[slot], col_idx);
        return true;
    }

    pub fn getComponentData(self: *EcsWorld, entity: Entity, comp_id: ComponentId, out_buffer: []u8) ?usize {
        const shared = self.sharedWorld() orelse return null;
        if (entity == INVALID_ENTITY or comp_id == 0 or comp_id > shared.column_count) return null;
        const slot = self.getSlotIndex(entity) orelse return null;
        const col_idx: usize = @intCast(comp_id - 1);
        const records = self.entities() orelse return null;
        if (!hasBit(&records[slot], col_idx)) return null;
        const col = self.column(col_idx) orelse return null;
        const src = self.componentBytes(col, slot) orelse return null;
        const copy_len = @min(out_buffer.len, src.len);
        if (copy_len > 0) {
            @memcpy(out_buffer[0..copy_len], src[0..copy_len]);
        }
        return copy_len;
    }

    pub fn hasComponent(self: *EcsWorld, entity: Entity, comp_id: ComponentId) bool {
        const shared = self.sharedWorld() orelse return false;
        if (entity == INVALID_ENTITY or comp_id == 0 or comp_id > shared.column_count) return false;
        const slot = self.getSlotIndex(entity) orelse return false;
        const col_idx: usize = @intCast(comp_id - 1);
        const records = self.entities() orelse return false;
        return hasBit(&records[slot], col_idx);
    }

    pub fn removeComponent(self: *EcsWorld, entity: Entity, comp_id: ComponentId) void {
        const shared = self.sharedWorld() orelse return;
        if (entity == INVALID_ENTITY or comp_id == 0 or comp_id > shared.column_count) return;
        const slot = self.getSlotIndex(entity) orelse return;
        const col_idx: usize = @intCast(comp_id - 1);
        const records = self.mutableEntities() orelse return;
        clearBit(&records[slot], col_idx);
    }

    pub fn queryEntities(self: *EcsWorld, comp_ids: []const ComponentId, out_entities: []Entity) usize {
        if (comp_ids.len == 0 or out_entities.len == 0) return 0;

        var req_mask: u128 = 0;
        var req_mask_ext: u16 = 0;
        for (comp_ids) |cid| {
            const shared = self.sharedWorld() orelse return 0;
            if (cid == 0 or cid > shared.column_count) return 0;
            const col_idx: usize = @intCast(cid - 1);
            if (col_idx < 128) {
                req_mask |= (@as(u128, 1) << @intCast(col_idx));
            } else if (col_idx < 144) {
                req_mask_ext |= (@as(u16, 1) << @intCast(col_idx - 128));
            }
        }

        var matched: usize = 0;
        const records = self.entities() orelse return 0;
        for (records, 0..) |*rec, slot| {
            if (rec.alive == 0) continue;
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
            const shared = self.sharedWorld() orelse return 0;
            if (cid == 0 or cid > shared.column_count) return 0;
            const col_idx: usize = @intCast(cid - 1);
            if (col_idx < 128) {
                req_mask |= (@as(u128, 1) << @intCast(col_idx));
            } else if (col_idx < 144) {
                req_mask_ext |= (@as(u16, 1) << @intCast(col_idx - 128));
            }
        }

        var matched: usize = 0;
        const records = self.entities() orelse return 0;
        for (records) |*rec| {
            if (rec.alive == 0) continue;
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

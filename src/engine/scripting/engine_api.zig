const std = @import("std");
const wamr = @import("wamr_bindings.zig");
const c = wamr.c;
const joltc = @import("../physics/jolt.zig").c;
const PhysicsWorld = @import("../physics/jolt.zig").PhysicsWorld;
const Scene = @import("../renderer/scene.zig").Scene;
const ecs_mod = @import("../ecs/ecs.zig");
const InputState = @import("../input/input.zig").InputState;
const game_state = @import("../state/game_state.zig");
const GameState = game_state.GameState;
const Vec3 = game_state.Vec3;
const ActionId = game_state.ActionId;
const AxisId = game_state.AxisId;
const ColliderType = game_state.ColliderType;
const MotionType = game_state.MotionType;
const GameEvent = game_state.GameEvent;
const isFiniteVec3 = game_state.isFiniteVec3;

const MAX_IMPULSE_MAGNITUDE: f32 = 500.0;
const MAX_SPEED: f32 = 100.0;
const BOUND_LIMIT: f32 = 1000.0;

pub const EngineContext = struct {
    scene: *Scene,
    camera: ?*@import("../camera/camera.zig").Camera = null,
    input: ?*const InputState = null,
    physics: ?*@import("../physics/jolt.zig").PhysicsWorld = null,
    audio: ?*@import("../audio/audio.zig").AudioEngine = null,
    ui: ?*@import("../renderer/ui.zig").UiRenderer = null,
    window: ?*@import("../platform/window.zig").Window = null,
    ecs: ?*@import("../ecs/ecs.zig").EcsWorld = null,
    particles: ?*@import("../renderer/particles.zig").ParticleSystem = null,
    remote_events: ?*@import("../net/replication.zig").RemoteEventManager = null,
    task_scheduler: ?*@import("task_scheduler.zig").TaskScheduler = null,
    is_server: bool = false,
    client_id: u32 = 0,
    rtt_ms: f32 = 0.0,
    is_connected: bool = false,
    time: f32 = 0.0,
    delta_time: f32 = 0.0,

    last_ray_origin: [3]f32 = .{ 0.0, 0.0, 0.0 },
    last_ray_dir: [3]f32 = .{ 0.0, 0.0, 0.0 },

    // Authoritative shared game state (points directly to WASM's shared_memory_buffer when loaded)
    host_state: ?*GameState = null,
    guest_state: ?*const GameState = null,
    shared_ecs: ?*game_state.SharedEcsWorld = null,
    guest_buffer_offset: ?u32 = null,

    // Diagnostics & testing state
    last_log: [256]u8 = [_]u8{0} ** 256,
    last_log_len: usize = 0,
    log_count: u32 = 0,

    pub fn getLastLog(self: *const EngineContext) []const u8 {
        return self.last_log[0..self.last_log_len];
    }

    /// Re-resolves the native pointer to WASM's `shared_memory_buffer` in case `memory.grow` relocated linear memory.
    pub fn refreshSharedState(self: *EngineContext, mod_inst: ?c.wasm_module_inst_t) ?*GameState {
        const inst = mod_inst orelse return self.host_state;
        const offset = self.guest_buffer_offset orelse return self.host_state;
        if (wamr.getGuestMemorySliceMut(inst, offset, @sizeOf(GameState))) |bytes| {
            const state: *GameState = @ptrCast(@alignCast(bytes.ptr));
            self.host_state = state;
            self.guest_state = state;
            const ecs_align = @as(usize, @alignOf(game_state.SharedEcsWorld));
            const ecs_offset = offset + @as(u32, @intCast((@sizeOf(GameState) + ecs_align - 1) & ~(ecs_align - 1)));
            if (wamr.getGuestMemorySliceMut(inst, ecs_offset, @sizeOf(game_state.SharedEcsWorld))) |ecs_bytes| {
                const ecs: *game_state.SharedEcsWorld = @ptrCast(@alignCast(ecs_bytes.ptr));
                self.shared_ecs = ecs;
                if (self.ecs) |ew| ew.attachSharedWorld(ecs);
            }
            return state;
        }
        return self.host_state;
    }

    /// Pre-tick preparation: updates time, delta_time, and input state directly in shared memory.
    pub fn preTickPrepare(self: *EngineContext, mod_inst: ?c.wasm_module_inst_t, dt: f32) void {
        if (self.refreshSharedState(mod_inst)) |state| {
            state.header.time = self.time;
            state.header.delta_time = dt;
            state.events.count = 0;
            if (self.input) |inp| {
                inp.updateSharedState(&state.input);
            }
        }
    }

    /// Post-tick step: sanitizes in-place guest mutations, resolves scene graph hierarchy,
    /// integrates kinematic velocities, and synchronizes to `EcsWorld` and `Scene`.
    pub fn postTickReconcile(self: *EngineContext, dt: f32) void {
        if (self.input) |inp| {
            if (self.host_state) |state| {
                inp.updateSharedState(&state.input);
            }
        }

        if (self.host_state) |state| {
            if (self.ecs) |ew| {
                if (self.physics) |physics| ew.syncDirtyToPhysics(physics);
            }
            state.stepAndResolve(dt);

            if (std.math.isFinite(state.scene.rotation_x)) {
                self.scene.rotation_x = state.scene.rotation_x;
            }
            if (std.math.isFinite(state.scene.rotation_y)) {
                self.scene.rotation_y = state.scene.rotation_y;
            }
            if (std.math.isFinite(state.scene.camera_distance) and state.scene.camera_distance >= 1.0 and state.scene.camera_distance <= 50.0) {
                self.scene.camera_distance = state.scene.camera_distance;
            }
            for (0..6) |face| {
                const col = state.scene.cube_face_colors[face];
                self.scene.setFaceColor(
                    @intCast(face),
                    std.math.clamp(col[0], 0.0, 1.0),
                    std.math.clamp(col[1], 0.0, 1.0),
                    std.math.clamp(col[2], 0.0, 1.0),
                );
            }

            if (self.ecs) |ew| {
                for (&state.entities, 0..) |*ent, idx| {
                    const slot: u32 = @intCast(idx);
                    if (ent.active != 0) {
                        if (!ew.isAlive(slot)) {
                            _ = ew.initSlot(slot, null);
                        }
                        if (!ew.hasComponent(slot, ew.id_transform)) {
                            ew.setPosition(slot, .{ .x = ent.position.x, .y = ent.position.y, .z = ent.position.z });
                            ew.setRotation(slot, .{ .x = ent.rotation.x, .y = ent.rotation.y, .z = ent.rotation.z });
                            ew.setScale(slot, .{ .x = ent.scale.x, .y = ent.scale.y, .z = ent.scale.z });
                        } else if (!ew.hasComponent(slot, ew.id_phys)) {
                            // Hierarchy resolution produces world transforms in GameState.
                            // Non-physics children, including camera parents, must consume
                            // that resolved transform rather than retaining local ECS values.
                            ew.setPosition(slot, .{ .x = ent.position.x, .y = ent.position.y, .z = ent.position.z });
                            ew.setRotation(slot, .{ .x = ent.rotation.x, .y = ent.rotation.y, .z = ent.rotation.z });
                            ew.setScale(slot, .{ .x = ent.scale.x, .y = ent.scale.y, .z = ent.scale.z });
                        } else if (ew.getPosition(slot)) |position| {
                            ent.position = .{ .x = position.x, .y = position.y, .z = position.z };
                            ent.local_position = ent.position;
                            if (ew.getRotation(slot)) |rotation| {
                                ent.rotation = .{ .x = rotation.x, .y = rotation.y, .z = rotation.z };
                                ent.local_rotation = ent.rotation;
                            }
                        }
                        // Scale is not simulated by Jolt. Guest local-scale writes
                        // therefore remain authoritative and must reach ECS/rendering.
                        ew.setScale(slot, .{ .x = ent.scale.x, .y = ent.scale.y, .z = ent.scale.z });
                        if (!ew.hasComponent(slot, ew.id_mesh)) {
                            ew.setMesh(slot, .{
                                .primitive_type = ent.entity_type % 5,
                                .color = ent.color,
                                .metallic = ent.metallic,
                                .roughness = ent.roughness,
                                .visible = true,
                            });
                        }
                    }
                }
            }
            if (self.ecs) |ew| {
                if (self.physics) |physics| ew.syncDirtyToPhysics(physics);
            }
            // Bodies may be created or simulated during the WASM tick. Refresh
            // ECS once more before rendering so visual transforms are current.
            if (self.ecs) |ew| {
                if (self.physics) |physics| ew.syncFromPhysics(physics);
            }

            if (self.ecs) |ew| {
                self.scene.clearObjects();
                ew.syncToScene(self.scene);
            } else if (state.header.entity_count > 0 or self.scene.object_count > 0) {
                // Keep the legacy renderer path only for contexts without ECS.
                self.scene.syncFromGameState(state);
            }
        }
        if (self.task_scheduler) |ts| {
            ts.step(dt);
        }
    }
};

fn getContext(exec_env: c.wasm_exec_env_t) *EngineContext {
    const mod_inst = c.wasm_runtime_get_module_inst(exec_env);
    const raw_ptr = c.wasm_runtime_get_custom_data(mod_inst);
    const ctx: *EngineContext = @ptrCast(@alignCast(raw_ptr.?));
    _ = ctx.refreshSharedState(mod_inst);
    return ctx;
}

// -------------------------------------------------------------------------------------------------
// Host API Functions Linked to WebAssembly Guest Environment (WAMR Native Symbols)
// -------------------------------------------------------------------------------------------------

fn host_log(exec_env: c.wasm_exec_env_t, offset: u32, len: u32) callconv(.c) void {
    const ctx = getContext(exec_env);
    const mod_inst = c.wasm_runtime_get_module_inst(exec_env);
    if (wamr.getGuestMemorySlice(mod_inst, offset, len)) |msg| {
        const copy_len = @min(msg.len, ctx.last_log.len);
        @memcpy(ctx.last_log[0..copy_len], msg[0..copy_len]);
        ctx.last_log_len = copy_len;
        ctx.log_count += 1;
        std.debug.print("{s}\n", .{msg});
    }
}

fn host_apply_impulse(exec_env: c.wasm_exec_env_t, id: u64, x: f32, y: f32, z: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    const impulse = Vec3.init(x, y, z);
    if (!isFiniteVec3(impulse) or impulse.lengthSq() > MAX_IMPULSE_MAGNITUDE * MAX_IMPULSE_MAGNITUDE) return;
    if (ctx.host_state) |state| {
        if (id < game_state.MAX_PLAYERS and state.players[@intCast(id)].active != 0) {
            state.players[@intCast(id)].velocity = state.players[@intCast(id)].velocity.add(impulse);
        } else if (id < game_state.MAX_ENTITIES and state.entities[@intCast(id)].active != 0) {
            state.entities[@intCast(id)].velocity = state.entities[@intCast(id)].velocity.add(impulse);
        }
    }
}

fn host_set_player_velocity(exec_env: c.wasm_exec_env_t, id: u32, x: f32, y: f32, z: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    const vel = Vec3.init(x, y, z);
    if (id < game_state.MAX_PLAYERS and isFiniteVec3(vel) and vel.lengthSq() <= MAX_SPEED * MAX_SPEED) {
        if (ctx.host_state) |state| {
            if (state.players[id].active != 0) {
                state.players[id].velocity = vel;
            }
        }
    }
}

fn host_teleport_player(exec_env: c.wasm_exec_env_t, id: u32, x: f32, y: f32, z: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    const pos = Vec3.init(x, y, z);
    if (id < game_state.MAX_PLAYERS and isFiniteVec3(pos) and
        @abs(pos.x) <= BOUND_LIMIT and @abs(pos.y) <= BOUND_LIMIT and @abs(pos.z) <= BOUND_LIMIT)
    {
        if (ctx.host_state) |state| {
            if (state.players[id].active != 0) {
                state.players[id].position = pos;
                state.players[id].velocity = .{};
            }
        }
    }
}

fn host_spawn_entity(exec_env: c.wasm_exec_env_t, entity_type: u32, x: f32, y: f32, z: f32, r: f32, g: f32, b: f32, a: f32) callconv(.c) u64 {
    const ctx = getContext(exec_env);
    const pos = Vec3.init(x, y, z);
    if (!isFiniteVec3(pos)) return game_state.NO_PARENT;

    const color = [_]f32{ r, g, b, a };
    if (ctx.ecs) |ew| {
        const entity = ew.newEntity(null);
        if (entity == ecs_mod.INVALID_ENTITY) return game_state.NO_PARENT;

        if (ctx.host_state) |state| {
            state.initSlot(@intCast(entity));
            state.entities[@intCast(entity)].entity_type = entity_type;
            state.entities[@intCast(entity)].local_position = pos;
            state.entities[@intCast(entity)].position = pos;
            state.entities[@intCast(entity)].color = color;
        }

        ew.setPosition(entity, .{ .x = x, .y = y, .z = z });
        ew.setScale(entity, .{ .x = 1.0, .y = 1.0, .z = 1.0 });
        ew.setMesh(entity, .{
            .primitive_type = entity_type % 5,
            .color = color,
            .metallic = 0.0,
            .roughness = 0.5,
            .visible = true,
        });
        ew.setHierarchy(entity, .{ .parent_id = ecs_mod.INVALID_ENTITY });
        ew.setMetadata(entity, .{ .entity_type = entity_type });
        return entity;
    }

    if (ctx.host_state) |state| {
        for (&state.entities, 0..) |*ent, idx| {
            const slot: u32 = @intCast(idx);
            if (ent.active == 0) {
                state.initSlot(slot);
                ent.entity_type = entity_type;
                ent.local_position = pos;
                ent.position = pos;
                ent.color = color;
                return slot;
            }
        }
    }
    return game_state.NO_PARENT;
}

fn host_despawn_entity(exec_env: c.wasm_exec_env_t, id: u64) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (ctx.host_state) |state| {
        _ = state.freeEntitySlot(id);
    }
    if (ctx.ecs) |ew| {
        ew.deleteEntity(id);
    }
}

fn host_rotate(exec_env: c.wasm_exec_env_t, dx: f32, dy: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (std.math.isFinite(dx) and std.math.isFinite(dy)) {
        ctx.scene.rotation_x += dx;
        ctx.scene.rotation_y += dy;
        if (ctx.host_state) |state| {
            state.scene.rotation_x = ctx.scene.rotation_x;
            state.scene.rotation_y = ctx.scene.rotation_y;
        }
    }
}

fn host_set_scene_rotation(exec_env: c.wasm_exec_env_t, rx: f32, ry: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (std.math.isFinite(rx) and std.math.isFinite(ry)) {
        ctx.scene.rotation_x = rx;
        ctx.scene.rotation_y = ry;
        if (ctx.host_state) |state| {
            state.scene.rotation_x = rx;
            state.scene.rotation_y = ry;
        }
    }
}

fn host_set_camera_distance(exec_env: c.wasm_exec_env_t, val: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (std.math.isFinite(val) and val >= 1.0 and val <= 50.0) {
        ctx.scene.camera_distance = val;
        if (ctx.host_state) |state| {
            state.scene.camera_distance = val;
        }
    }
}

fn host_set_cube_color(exec_env: c.wasm_exec_env_t, face_idx: u32, r: f32, g: f32, b: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (face_idx < 6) {
        const cr = std.math.clamp(r, 0.0, 1.0);
        const cg = std.math.clamp(g, 0.0, 1.0);
        const cb = std.math.clamp(b, 0.0, 1.0);
        ctx.scene.setFaceColor(@intCast(face_idx), cr, cg, cb);
        if (ctx.host_state) |state| {
            state.scene.cube_face_colors[face_idx] = [_]f32{ cr, cg, cb, 1.0 };
        }
    }
}

fn host_set_entity_local_pos(exec_env: c.wasm_exec_env_t, id: u64, x: f32, y: f32, z: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    const pos = Vec3.init(x, y, z);
    if (ctx.host_state) |state| {
        if (id < game_state.MAX_ENTITIES and state.entities[@intCast(id)].active != 0 and
            isFiniteVec3(pos) and @abs(pos.x) <= BOUND_LIMIT and @abs(pos.y) <= BOUND_LIMIT and @abs(pos.z) <= BOUND_LIMIT)
        {
            state.entities[@intCast(id)].local_position = pos;
            state.entities[@intCast(id)].position = pos;
            if (ctx.ecs) |ew| ew.setPosition(id, .{ .x = x, .y = y, .z = z });
        }
    }
}

fn host_set_entity_local_rot(exec_env: c.wasm_exec_env_t, id: u64, rx: f32, ry: f32, rz: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    const rot = Vec3.init(rx, ry, rz);
    if (ctx.host_state) |state| {
        if (id < game_state.MAX_ENTITIES and state.entities[@intCast(id)].active != 0 and isFiniteVec3(rot)) {
            state.entities[@intCast(id)].local_rotation = rot;
            state.entities[@intCast(id)].rotation = rot;
            if (ctx.ecs) |ew| ew.setRotation(id, .{ .x = rx, .y = ry, .z = rz });
        }
    }
}

fn host_set_entity_local_scale(exec_env: c.wasm_exec_env_t, id: u64, sx: f32, sy: f32, sz: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    const sc = Vec3.init(sx, sy, sz);
    if (ctx.host_state) |state| {
        if (id < game_state.MAX_ENTITIES and state.entities[@intCast(id)].active != 0 and
            isFiniteVec3(sc) and sc.x >= 0.0 and sc.y >= 0.0 and sc.z >= 0.0)
        {
            state.entities[@intCast(id)].local_scale = sc;
            state.entities[@intCast(id)].scale = sc;
            if (ctx.ecs) |ew| ew.setScale(id, .{ .x = sx, .y = sy, .z = sz });
        }
    }
}

fn host_set_entity_parent(exec_env: c.wasm_exec_env_t, child_id: u64, parent_id: u64) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (ctx.host_state) |state| {
        if (child_id < game_state.MAX_ENTITIES and state.entities[@intCast(child_id)].active != 0) {
            if (parent_id == game_state.NO_PARENT) {
                state.entities[@intCast(child_id)].parent_id = game_state.NO_PARENT;
            } else if (parent_id < game_state.MAX_ENTITIES and state.entities[@intCast(parent_id)].active != 0 and parent_id != child_id) {
                var has_cycle = false;
                var curr = parent_id;
                var depth: u32 = 0;
                while (curr != game_state.NO_PARENT and depth < 16) : (depth += 1) {
                    if (curr == child_id) {
                        has_cycle = true;
                        break;
                    }
                    curr = state.entities[@intCast(curr)].parent_id;
                }
                if (!has_cycle) {
                    state.entities[@intCast(child_id)].parent_id = parent_id;
                    if (ctx.ecs) |ew| {
                        ew.setHierarchy(child_id, .{ .parent_id = parent_id });
                    }
                }
            }
            if (parent_id == game_state.NO_PARENT) {
                if (ctx.ecs) |ew| ew.setHierarchy(child_id, .{ .parent_id = ecs_mod.INVALID_ENTITY });
            }
        }
    }
}

fn host_set_entity_collider(exec_env: c.wasm_exec_env_t, id: u64, col_type: u32, ex: f32, ey: f32, ez: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    const extents = Vec3.init(ex, ey, ez);
    if (ctx.host_state) |state| {
        if (id < game_state.MAX_ENTITIES and state.entities[@intCast(id)].active != 0 and col_type <= 3 and isFiniteVec3(extents)) {
            state.entities[@intCast(id)].collider_type = @enumFromInt(col_type);
            state.entities[@intCast(id)].collider_extents = extents;
            state.entities[@intCast(id)].component_mask |= game_state.ComponentMask.COLLIDER;
            if (ctx.ecs) |ew| ew.setCollider(id, .{
                .collider_type = col_type,
                .extents = .{ .x = ex, .y = ey, .z = ez },
            });
        }
    }
}

fn host_set_entity_tag(exec_env: c.wasm_exec_env_t, id: u64, tag_ptr: u32, tag_len: u32) callconv(.c) void {
    const ctx = getContext(exec_env);
    const mod_inst = c.wasm_runtime_get_module_inst(exec_env);
    if (wamr.getGuestMemorySlice(mod_inst, tag_ptr, tag_len)) |tag_str| {
        if (ctx.host_state) |state| {
            if (id < game_state.MAX_ENTITIES and state.entities[@intCast(id)].active != 0) {
                const len = @min(tag_str.len, 16);
                @memset(&state.entities[@intCast(id)].tag, 0);
                @memcpy(state.entities[@intCast(id)].tag[0..len], tag_str[0..len]);
                if (ctx.ecs) |ew| {
                    var metadata = ecs_mod.Metadata{};
                    if (ew.getComponentPtrConst(id, ew.id_metadata, ecs_mod.Metadata)) |current| {
                        metadata = current.*;
                    }
                    @memset(&metadata.tag, 0);
                    @memcpy(metadata.tag[0..len], tag_str[0..len]);
                    ew.setMetadata(id, metadata);
                }
            }
        }
    }
}

fn host_set_entity_motion_type(exec_env: c.wasm_exec_env_t, id: u64, motion_type: u32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (ctx.host_state) |state| {
        if (id < game_state.MAX_ENTITIES and state.entities[@intCast(id)].active != 0 and motion_type <= 2) {
            state.entities[@intCast(id)].motion_type = @enumFromInt(motion_type);
            state.entities[@intCast(id)].component_mask |= game_state.ComponentMask.RIGID_BODY;
            if (ctx.ecs) |ew| {
                if (ew.getPhysicsBody(id)) |body| {
                    var physics_body = body.*;
                    physics_body.is_dynamic = motion_type == @intFromEnum(game_state.MotionType.dynamic);
                    _ = ew.setComponentData(id, ew.id_phys, std.mem.asBytes(&physics_body));
                }
            }
        }
    }
}

fn host_set_entity_material(exec_env: c.wasm_exec_env_t, id: u64, metallic: f32, roughness: f32, emissive: f32, shading_model: u32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (ctx.host_state) |state| {
        if (id < game_state.MAX_ENTITIES and state.entities[@intCast(id)].active != 0) {
            state.entities[@intCast(id)].metallic = metallic;
            state.entities[@intCast(id)].roughness = roughness;
            state.entities[@intCast(id)].emissive = emissive;
            state.entities[@intCast(id)].shading_model = shading_model;
            if (ctx.ecs) |ew| {
                ew.setMaterial(id, .{
                    .metallic = metallic,
                    .roughness = roughness,
                    .emissive = emissive,
                    .shading_model = shading_model,
                });
                if (ew.getMesh(id)) |current| {
                    var mesh = current.*;
                    mesh.metallic = metallic;
                    mesh.roughness = roughness;
                    mesh.visible = true;
                    ew.setMesh(id, mesh);
                }
            }
        }
    }
}

fn host_set_entity_color(exec_env: c.wasm_exec_env_t, id: u64, r: f32, g: f32, b: f32, a: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (ctx.host_state) |state| {
        if (id < game_state.MAX_ENTITIES and state.entities[@intCast(id)].active != 0) {
            state.entities[@intCast(id)].color = [_]f32{ r, g, b, a };
            if (ctx.ecs) |ew| {
                if (ew.getMesh(id)) |current| {
                    var mesh = current.*;
                    mesh.color = .{ r, g, b, a };
                    ew.setMesh(id, mesh);
                }
            }
        }
    }
}

fn host_emit_event(
    exec_env: c.wasm_exec_env_t,
    ev_type: u32,
    src_id: u64,
    tgt_id: u64,
    d0: f32,
    d1: f32,
    d2: f32,
    d3: f32,
    tag_ptr: u32,
    tag_len: u32,
) callconv(.c) void {
    const ctx = getContext(exec_env);
    const mod_inst = c.wasm_runtime_get_module_inst(exec_env);
    const tag_slice = if (tag_len > 0) (wamr.getGuestMemorySlice(mod_inst, tag_ptr, tag_len) orelse "") else "";
    if (ctx.host_state) |state| {
        if (state.events.count < game_state.MAX_SHARED_EVENTS) {
            state.events.events[state.events.count] = GameEvent.make(ev_type, src_id, tgt_id, [_]f32{ d0, d1, d2, d3 }, tag_slice);
            state.events.count += 1;
        }
    }
}

fn host_get_time(exec_env: c.wasm_exec_env_t) callconv(.c) f32 {
    const ctx = getContext(exec_env);
    return ctx.time;
}

fn host_get_delta_time(exec_env: c.wasm_exec_env_t) callconv(.c) f32 {
    const ctx = getContext(exec_env);
    return ctx.delta_time;
}

fn host_get_rotation_x(exec_env: c.wasm_exec_env_t) callconv(.c) f32 {
    const ctx = getContext(exec_env);
    return ctx.scene.rotation_x;
}

fn host_set_rotation_x(exec_env: c.wasm_exec_env_t, val: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (std.math.isFinite(val)) {
        ctx.scene.rotation_x = val;
        if (ctx.host_state) |state| {
            state.scene.rotation_x = val;
        }
    }
}

fn host_get_rotation_y(exec_env: c.wasm_exec_env_t) callconv(.c) f32 {
    const ctx = getContext(exec_env);
    return ctx.scene.rotation_y;
}

fn host_set_rotation_y(exec_env: c.wasm_exec_env_t, val: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (std.math.isFinite(val)) {
        ctx.scene.rotation_y = val;
        if (ctx.host_state) |state| {
            state.scene.rotation_y = val;
        }
    }
}

fn host_get_camera_distance(exec_env: c.wasm_exec_env_t) callconv(.c) f32 {
    const ctx = getContext(exec_env);
    return ctx.scene.camera_distance;
}

fn host_is_key_down(exec_env: c.wasm_exec_env_t, scancode: u32) callconv(.c) u32 {
    const ctx = getContext(exec_env);
    if (ctx.input) |inp| {
        if (scancode < 512 and inp.keys_down[scancode]) return 1;
    }
    return 0;
}

fn host_is_mouse_button_down(exec_env: c.wasm_exec_env_t, btn: u32) callconv(.c) u32 {
    const ctx = getContext(exec_env);
    if (ctx.input) |inp| {
        if (btn < 8 and inp.mouse_buttons[btn]) return 1;
    }
    return 0;
}

fn host_is_action_down(exec_env: c.wasm_exec_env_t, action_id: u32) callconv(.c) u32 {
    const ctx = getContext(exec_env);
    if (ctx.input) |inp| {
        if (action_id < 16) {
            const act: ActionId = @enumFromInt(action_id);
            if (inp.isActionDown(act)) return 1;
        }
    }
    return 0;
}

fn host_is_action_pressed(exec_env: c.wasm_exec_env_t, action_id: u32) callconv(.c) u32 {
    const ctx = getContext(exec_env);
    if (ctx.input) |inp| {
        if (action_id < 16) {
            const act: ActionId = @enumFromInt(action_id);
            if (inp.isActionPressed(act)) return 1;
        }
    }
    return 0;
}

fn host_get_axis(exec_env: c.wasm_exec_env_t, axis_id: u32) callconv(.c) f32 {
    const ctx = getContext(exec_env);
    if (ctx.input) |inp| {
        if (axis_id < 8) {
            const axis: AxisId = @enumFromInt(axis_id);
            return inp.getAxis(axis);
        }
    }
    return 0.0;
}

fn host_sin(_: c.wasm_exec_env_t, val: f32) callconv(.c) f32 {
    return @sin(val);
}

fn host_cos(_: c.wasm_exec_env_t, val: f32) callconv(.c) f32 {
    return @cos(val);
}

fn host_physics_create_body(exec_env: c.wasm_exec_env_t, entity_id: u64, shape_type: u32, x: f32, y: f32, z: f32, is_dynamic: u32) callconv(.c) u32 {
    const ctx = getContext(exec_env);
    // Body creation can be requested both explicitly by gameplay and lazily by
    // a script system. Keep the ABI idempotent so one entity cannot acquire
    // multiple colliders.
    if (ctx.ecs) |ew| {
        if (ew.getPhysicsBody(entity_id)) |existing| {
            if (existing.body_id != 0) return existing.body_id;
        }
    }
    var body_id: u32 = 0;
    if (ctx.physics) |phys| {
        const dyn = (is_dynamic != 0);
        if (shape_type == 0) {
            // Box / Floor
            if (!dyn) {
                body_id = phys.createFloor(50.0, 0.5, 50.0, y) catch 0;
            } else {
                var half_extents = [_]f32{ 0.5, 0.5, 0.5 };
                var scale = Vec3.init(1.0, 1.0, 1.0);
                // Guest scale writes land in shared GameState before this ABI
                // call. Prefer that value because ECS reconciliation happens
                // after the script tick and would otherwise still report 1.0.
                if (ctx.host_state) |state| {
                    if (entity_id < game_state.MAX_ENTITIES) {
                        scale = state.entities[@intCast(entity_id)].scale;
                    }
                } else if (ctx.ecs) |ew| {
                    if (ew.getScale(entity_id)) |ecs_scale| {
                        scale = Vec3.init(ecs_scale.x, ecs_scale.y, ecs_scale.z);
                    }
                }
                half_extents = .{
                    0.5 * @max(scale.x, 0.001),
                    0.5 * @max(scale.y, 0.001),
                    0.5 * @max(scale.z, 0.001),
                };
                body_id = phys.createBox(.{ x, y, z }, half_extents, true) catch |err| {
                    std.log.err("{s}", .{@errorName(err)});
                    return 0;
                };
            }
        } else {
            // Sphere
            var radius: f32 = 0.5;
            if (dyn) {
                var scale = Vec3.init(1.0, 1.0, 1.0);
                if (ctx.host_state) |state| {
                    if (entity_id < game_state.MAX_ENTITIES) {
                        scale = state.entities[@intCast(entity_id)].scale;
                    }
                } else if (ctx.ecs) |ew| {
                    if (ew.getScale(entity_id)) |ecs_scale| {
                        scale = Vec3.init(ecs_scale.x, ecs_scale.y, ecs_scale.z);
                    }
                }
                radius *= @max(scale.x, @max(scale.y, scale.z));
            }
            body_id = phys.createSphere(.{ x, y, z }, radius, dyn) catch 0;
        }

        joltc.JPH_BodyInterface_SetUserData(phys.body_interface, body_id, entity_id);
        if (body_id != 0) {
            if (ctx.ecs) |ew| {
                ew.setPhysicsBody(entity_id, .{
                    .body_id = body_id,
                    .is_dynamic = dyn,
                });
            }
            if (dyn) {
                if (phys.getWorldBounds(body_id)) |bounds| {
                    const center = phys.getPosition(body_id);
                    std.log.info(
                        "Jolt body {d} entity {d}: center y={d:.3}, bounds y=[{d:.3}, {d:.3}], scale={d:.3},{d:.3},{d:.3}",
                        .{
                            body_id,
                            entity_id,
                            center[1],
                            bounds.min[1],
                            bounds.max[1],
                            if (ctx.host_state) |state|
                                if (entity_id < game_state.MAX_ENTITIES) state.entities[@intCast(entity_id)].scale.x else 1.0
                            else
                                1.0,
                            if (ctx.host_state) |state|
                                if (entity_id < game_state.MAX_ENTITIES) state.entities[@intCast(entity_id)].scale.y else 1.0
                            else
                                1.0,
                            if (ctx.host_state) |state|
                                if (entity_id < game_state.MAX_ENTITIES) state.entities[@intCast(entity_id)].scale.z else 1.0
                            else
                                1.0,
                        },
                    );
                }
            }
        }
    }

    return body_id;
}

fn host_physics_apply_impulse(exec_env: c.wasm_exec_env_t, body_id: u32, x: f32, y: f32, z: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (ctx.physics) |phys| {
        phys.addImpulse(body_id, .{ x, y, z });
    }
}

fn host_physics_get_pos_x(exec_env: c.wasm_exec_env_t, body_id: u32) callconv(.c) f32 {
    const ctx = getContext(exec_env);
    if (ctx.physics) |phys| {
        return phys.getPosition(body_id)[0];
    }
    return 0.0;
}

fn host_physics_get_pos_y(exec_env: c.wasm_exec_env_t, body_id: u32) callconv(.c) f32 {
    const ctx = getContext(exec_env);
    if (ctx.physics) |phys| {
        return phys.getPosition(body_id)[1];
    }
    return 0.0;
}

fn host_physics_get_pos_z(exec_env: c.wasm_exec_env_t, body_id: u32) callconv(.c) f32 {
    const ctx = getContext(exec_env);
    if (ctx.physics) |phys| {
        return phys.getPosition(body_id)[2];
    }
    return 0.0;
}

fn host_physics_get_vel_y(exec_env: c.wasm_exec_env_t, body_id: u32) callconv(.c) f32 {
    const ctx = getContext(exec_env);
    if (ctx.physics) |phys| {
        return phys.getLinearVelocity(body_id)[1];
    }
    return 0.0;
}

fn host_physics_is_active(exec_env: c.wasm_exec_env_t, body_id: u32) callconv(.c) u32 {
    const ctx = getContext(exec_env);
    if (ctx.physics) |phys| {
        if (phys.isBodyActive(body_id)) return 1;
    }
    return 0;
}

// Camera Host Functions
fn host_camera_set_pos(exec_env: c.wasm_exec_env_t, x: f32, y: f32, z: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (ctx.camera) |cam| {
        cam.position = @import("../math.zig").Vec3.init(x, y, z);
    }
}

fn host_camera_set_rot(exec_env: c.wasm_exec_env_t, yaw: f32, pitch: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (ctx.camera) |cam| {
        cam.yaw = yaw;
        cam.pitch = pitch;
    }
}

fn host_camera_set_fov(exec_env: c.wasm_exec_env_t, fov_deg: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (ctx.camera) |cam| {
        cam.fov_deg = fov_deg;
    }
}

fn host_camera_get_pos_x(exec_env: c.wasm_exec_env_t) callconv(.c) f32 {
    const ctx = getContext(exec_env);
    if (ctx.camera) |cam| return cam.position.x;
    return 0.0;
}

fn host_camera_get_pos_y(exec_env: c.wasm_exec_env_t) callconv(.c) f32 {
    const ctx = getContext(exec_env);
    if (ctx.camera) |cam| return cam.position.y;
    return 0.0;
}

fn host_camera_get_pos_z(exec_env: c.wasm_exec_env_t) callconv(.c) f32 {
    const ctx = getContext(exec_env);
    if (ctx.camera) |cam| return cam.position.z;
    return 0.0;
}

fn host_camera_get_yaw(exec_env: c.wasm_exec_env_t) callconv(.c) f32 {
    const ctx = getContext(exec_env);
    if (ctx.camera) |cam| return cam.yaw;
    return 0.0;
}

fn host_camera_get_pitch(exec_env: c.wasm_exec_env_t) callconv(.c) f32 {
    const ctx = getContext(exec_env);
    if (ctx.camera) |cam| return cam.pitch;
    return 0.0;
}

fn host_camera_screen_to_ray(exec_env: c.wasm_exec_env_t, sx: f32, sy: f32, sw: f32, sh: f32) callconv(.c) u32 {
    const ctx = getContext(exec_env);
    if (ctx.camera) |cam| {
        if (cam.screenToRay(sx, sy, sw, sh)) |ray| {
            ctx.last_ray_origin = .{ ray.origin.x, ray.origin.y, ray.origin.z };
            ctx.last_ray_dir = .{ ray.direction.x, ray.direction.y, ray.direction.z };
            return 1;
        }
    }
    return 0;
}

fn host_camera_get_ray_origin_x(exec_env: c.wasm_exec_env_t) callconv(.c) f32 {
    return getContext(exec_env).last_ray_origin[0];
}

fn host_camera_get_ray_origin_y(exec_env: c.wasm_exec_env_t) callconv(.c) f32 {
    return getContext(exec_env).last_ray_origin[1];
}

fn host_camera_get_ray_origin_z(exec_env: c.wasm_exec_env_t) callconv(.c) f32 {
    return getContext(exec_env).last_ray_origin[2];
}

fn host_camera_get_ray_dir_x(exec_env: c.wasm_exec_env_t) callconv(.c) f32 {
    return getContext(exec_env).last_ray_dir[0];
}

fn host_camera_get_ray_dir_y(exec_env: c.wasm_exec_env_t) callconv(.c) f32 {
    return getContext(exec_env).last_ray_dir[1];
}

fn host_camera_get_ray_dir_z(exec_env: c.wasm_exec_env_t) callconv(.c) f32 {
    return getContext(exec_env).last_ray_dir[2];
}

// Physics Raycast & Shapecast Host Functions
const ShapeCastHit = @import("../physics/jolt.zig").ShapeCastHit;

fn host_physics_cast_ray(exec_env: c.wasm_exec_env_t, ox: f32, oy: f32, oz: f32, dx: f32, dy: f32, dz: f32, out_pointer: u32) callconv(.c) u32 {
    const ctx = getContext(exec_env);
    if (ctx.physics) |phys| {
        if (phys.castRay(.{ ox, oy, oz }, .{ dx, dy, dz })) |hit| {
            const mod_inst = c.wasm_runtime_get_module_inst(exec_env);
            const bytes = wamr.getGuestMemorySliceMut(mod_inst, out_pointer, @sizeOf(PhysicsWorld.RaycastHit)) orelse return 0;
            const out_hit: *PhysicsWorld.RaycastHit = @ptrCast(@alignCast(bytes.ptr));
            out_hit.* = hit;
            return 1;
        }
    }
    return 0;
}

fn writeShapeCastHit(exec_env: c.wasm_exec_env_t, out_pointer: u32, hit: ShapeCastHit) u32 {
    const mod_inst = c.wasm_runtime_get_module_inst(exec_env);
    const bytes = wamr.getGuestMemorySliceMut(mod_inst, out_pointer, @sizeOf(ShapeCastHit)) orelse return 0;
    const out_hit: *ShapeCastHit = @ptrCast(@alignCast(bytes.ptr));
    out_hit.* = hit;
    return 1;
}

fn host_physics_cast_sphere(exec_env: c.wasm_exec_env_t, radius: f32, ox: f32, oy: f32, oz: f32, dx: f32, dy: f32, dz: f32, layer_mask: u32, out_pointer: u32) callconv(.c) u32 {
    const ctx = getContext(exec_env);
    if (ctx.physics) |phys| {
        if (phys.castSphere(radius, .{ ox, oy, oz }, .{ dx, dy, dz }, layer_mask)) |hit| {
            return writeShapeCastHit(exec_env, out_pointer, hit);
        }
    }
    return 0;
}

fn host_physics_cast_box(exec_env: c.wasm_exec_env_t, hx: f32, hy: f32, hz: f32, ox: f32, oy: f32, oz: f32, dx: f32, dy: f32, dz: f32, layer_mask: u32, out_pointer: u32) callconv(.c) u32 {
    const ctx = getContext(exec_env);
    if (ctx.physics) |phys| {
        if (phys.castBox(.{ hx, hy, hz }, .{ ox, oy, oz }, .{ dx, dy, dz }, layer_mask)) |hit| {
            return writeShapeCastHit(exec_env, out_pointer, hit);
        }
    }
    return 0;
}

fn host_physics_set_collision_layer(exec_env: c.wasm_exec_env_t, body_id: u32, layer: u32) callconv(.c) void {
    if (getContext(exec_env).physics) |phys| phys.setCollisionLayer(body_id, layer);
}

fn host_physics_set_layer_collision(exec_env: c.wasm_exec_env_t, a: u32, b: u32, enabled: u32) callconv(.c) void {
    if (getContext(exec_env).physics) |phys| phys.setLayerCollision(a, b, enabled != 0);
}

// Character Controller Host Functions
fn host_character_create(exec_env: c.wasm_exec_env_t, x: f32, y: f32, z: f32, half_height: f32, radius: f32) callconv(.c) u32 {
    if (getContext(exec_env).physics) |phys| {
        return phys.createCharacter(.{ x, y, z }, half_height, radius) catch 0;
    }
    return 0;
}

fn host_character_destroy(exec_env: c.wasm_exec_env_t, id: u32) callconv(.c) void {
    if (getContext(exec_env).physics) |phys| phys.destroyCharacter(id);
}

fn host_character_set_linear_velocity(exec_env: c.wasm_exec_env_t, id: u32, vx: f32, vy: f32, vz: f32) callconv(.c) void {
    if (getContext(exec_env).physics) |phys| phys.setCharacterLinearVelocity(id, .{ vx, vy, vz });
}

fn host_character_set_position(exec_env: c.wasm_exec_env_t, id: u32, x: f32, y: f32, z: f32) callconv(.c) void {
    if (getContext(exec_env).physics) |phys| phys.setCharacterPosition(id, .{ x, y, z });
}

fn host_character_get_ground_state(exec_env: c.wasm_exec_env_t, id: u32) callconv(.c) u32 {
    if (getContext(exec_env).physics) |phys| return @intFromEnum(phys.getCharacterGroundState(id));
    return 2;
}

fn host_character_get_pos_x(exec_env: c.wasm_exec_env_t, id: u32) callconv(.c) f32 {
    if (getContext(exec_env).physics) |phys| return phys.getCharacterPosition(id)[0];
    return 0.0;
}

fn host_character_get_pos_y(exec_env: c.wasm_exec_env_t, id: u32) callconv(.c) f32 {
    if (getContext(exec_env).physics) |phys| return phys.getCharacterPosition(id)[1];
    return 0.0;
}

fn host_character_get_pos_z(exec_env: c.wasm_exec_env_t, id: u32) callconv(.c) f32 {
    if (getContext(exec_env).physics) |phys| return phys.getCharacterPosition(id)[2];
    return 0.0;
}

fn host_character_get_vel_y(exec_env: c.wasm_exec_env_t, id: u32) callconv(.c) f32 {
    if (getContext(exec_env).physics) |phys| return phys.getCharacterLinearVelocity(id)[1];
    return 0.0;
}

// Physics Constraint Host Functions
fn host_constraint_create_hinge(exec_env: c.wasm_exec_env_t, body_a: u32, body_b: u32, px: f32, py: f32, pz: f32, ax: f32, ay: f32, az: f32, limit_min: f32, limit_max: f32) callconv(.c) u32 {
    if (getContext(exec_env).physics) |phys| {
        return phys.createHingeConstraint(body_a, body_b, .{ px, py, pz }, .{ ax, ay, az }, limit_min, limit_max) catch 0;
    }
    return 0;
}

fn host_constraint_create_ball_socket(exec_env: c.wasm_exec_env_t, body_a: u32, body_b: u32, px: f32, py: f32, pz: f32) callconv(.c) u32 {
    if (getContext(exec_env).physics) |phys| {
        return phys.createBallSocketConstraint(body_a, body_b, .{ px, py, pz }) catch 0;
    }
    return 0;
}

fn host_constraint_create_slider(exec_env: c.wasm_exec_env_t, body_a: u32, body_b: u32, ax: f32, ay: f32, az: f32, limit_min: f32, limit_max: f32) callconv(.c) u32 {
    if (getContext(exec_env).physics) |phys| {
        return phys.createSliderConstraint(body_a, body_b, .{ ax, ay, az }, limit_min, limit_max) catch 0;
    }
    return 0;
}

fn host_constraint_create_weld(exec_env: c.wasm_exec_env_t, body_a: u32, body_b: u32) callconv(.c) u32 {
    if (getContext(exec_env).physics) |phys| {
        return phys.createWeldConstraint(body_a, body_b) catch 0;
    }
    return 0;
}

fn host_constraint_destroy(exec_env: c.wasm_exec_env_t, id: u32) callconv(.c) void {
    if (getContext(exec_env).physics) |phys| phys.destroyConstraint(id);
}

// UI Host Functions
fn host_ui_draw_rect(exec_env: c.wasm_exec_env_t, x: f32, y: f32, w: f32, h: f32, r: f32, g: f32, b: f32, a: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (ctx.ui) |ui| {
        ui.drawRect(x, y, w, h, .{ r, g, b, a });
    }
}

fn host_ui_draw_rect_border(exec_env: c.wasm_exec_env_t, x: f32, y: f32, w: f32, h: f32, thickness: f32, r: f32, g: f32, b: f32, a: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (ctx.ui) |ui| {
        ui.drawRectBorder(x, y, w, h, thickness, .{ r, g, b, a });
    }
}

fn host_ui_draw_crosshair(exec_env: c.wasm_exec_env_t, cx: f32, cy: f32, size: f32, thickness: f32, r: f32, g: f32, b: f32, a: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (ctx.ui) |ui| {
        ui.drawCrosshair(cx, cy, size, thickness, .{ r, g, b, a });
    }
}

fn host_ui_draw_progress_bar(exec_env: c.wasm_exec_env_t, x: f32, y: f32, w: f32, h: f32, frac: f32, fr: f32, fg: f32, fb: f32, fa: f32, br: f32, bg: f32, bb: f32, ba: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (ctx.ui) |ui| {
        ui.drawProgressBar(x, y, w, h, frac, .{ fr, fg, fb, fa }, .{ br, bg, bb, ba });
    }
}

fn host_ui_draw_selection_box(exec_env: c.wasm_exec_env_t, x1: f32, y1: f32, x2: f32, y2: f32, fr: f32, fg: f32, fb: f32, fa: f32, br: f32, bg: f32, bb: f32, ba: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (ctx.ui) |ui| {
        ui.drawSelectionBox(x1, y1, x2, y2, .{ fr, fg, fb, fa }, .{ br, bg, bb, ba });
    }
}

fn host_ui_draw_text(
    exec_env: c.wasm_exec_env_t,
    text_ptr: u32,
    text_len: u32,
    x: f32,
    y: f32,
    font_size: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
) callconv(.c) void {
    const ctx = getContext(exec_env);
    const mod_inst = c.wasm_runtime_get_module_inst(exec_env);
    if (wamr.getGuestMemorySlice(mod_inst, text_ptr, text_len)) |text| {
        if (ctx.ui) |ui| {
            ui.drawText(text, x, y, font_size, .{ r, g, b, a });
        }
    }
}

// Audio Host Functions
fn host_audio_play_tone(exec_env: c.wasm_exec_env_t, freq: f32, duration: f32, vol: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (ctx.audio) |aud| {
        aud.playTone(freq, duration, vol);
    }
}

fn host_audio_play_impact(exec_env: c.wasm_exec_env_t, vol: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (ctx.audio) |aud| {
        aud.playImpact(vol);
    }
}

fn host_audio_play_chime(exec_env: c.wasm_exec_env_t, vol: f32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (ctx.audio) |aud| {
        aud.playChime(vol);
    }
}

// Window Host Functions
fn host_window_set_relative_mouse(exec_env: c.wasm_exec_env_t, enabled: u32) callconv(.c) u32 {
    const ctx = getContext(exec_env);
    if (ctx.window) |win| {
        return if (win.setRelativeMouseMode(enabled != 0)) 1 else 0;
    }
    return 0;
}

fn host_window_get_screen_w(exec_env: c.wasm_exec_env_t) callconv(.c) f32 {
    const ctx = getContext(exec_env);
    if (ctx.window) |win| return @as(f32, @floatFromInt(win.width));
    return 1024.0;
}

fn host_window_get_screen_h(exec_env: c.wasm_exec_env_t) callconv(.c) f32 {
    const ctx = getContext(exec_env);
    if (ctx.window) |win| return @as(f32, @floatFromInt(win.height));
    return 680.0;
}

fn host_particle_spawn_burst(
    exec_env: c.wasm_exec_env_t,
    x: f32,
    y: f32,
    z: f32,
    count: u32,
    speed: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    size: f32,
    lifetime: f32,
) callconv(.c) void {
    const ctx = getContext(exec_env);
    const pos = Vec3.init(x, y, z);
    const color = [4]f32{ r, g, b, a };
    if (ctx.particles) |p| {
        p.spawnBurst(@import("../math.zig").Vec3.init(pos.x, pos.y, pos.z), count, speed, color, size, lifetime);
    }
}

// Networking RemoteEvent Host Implementations
fn host_net_fire_server(exec_env: c.wasm_exec_env_t, name_ptr: u32, name_len: u32, data_ptr: u32, data_len: u32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (ctx.remote_events) |mgr| {
        const mod_inst = c.wasm_runtime_get_module_inst(exec_env);
        const name_host: [*]const u8 = @ptrCast(c.wasm_runtime_addr_app_to_native(mod_inst, name_ptr) orelse return);
        const data_host: [*]const u8 = @ptrCast(c.wasm_runtime_addr_app_to_native(mod_inst, data_ptr) orelse return);
        const name_slice = name_host[0..name_len];
        const data_slice = data_host[0..data_len];
        const msg = @import("../net/replication.zig").RemoteEventMessage.init(ctx.client_id, name_slice, data_slice);
        _ = mgr.pushOutgoing(msg);
    }
}

fn host_net_fire_client(exec_env: c.wasm_exec_env_t, target_client_id: u32, name_ptr: u32, name_len: u32, data_ptr: u32, data_len: u32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (ctx.remote_events) |mgr| {
        const mod_inst = c.wasm_runtime_get_module_inst(exec_env);
        const name_host: [*]const u8 = @ptrCast(c.wasm_runtime_addr_app_to_native(mod_inst, name_ptr) orelse return);
        const data_host: [*]const u8 = @ptrCast(c.wasm_runtime_addr_app_to_native(mod_inst, data_ptr) orelse return);
        const name_slice = name_host[0..name_len];
        const data_slice = data_host[0..data_len];
        const msg = @import("../net/replication.zig").RemoteEventMessage.init(target_client_id, name_slice, data_slice);
        _ = mgr.pushOutgoing(msg);
    }
}

fn host_net_fire_all_clients(exec_env: c.wasm_exec_env_t, name_ptr: u32, name_len: u32, data_ptr: u32, data_len: u32) callconv(.c) void {
    const ctx = getContext(exec_env);
    if (ctx.remote_events) |mgr| {
        const mod_inst = c.wasm_runtime_get_module_inst(exec_env);
        const name_host: [*]const u8 = @ptrCast(c.wasm_runtime_addr_app_to_native(mod_inst, name_ptr) orelse return);
        const data_host: [*]const u8 = @ptrCast(c.wasm_runtime_addr_app_to_native(mod_inst, data_ptr) orelse return);
        const name_slice = name_host[0..name_len];
        const data_slice = data_host[0..data_len];
        const msg = @import("../net/replication.zig").RemoteEventMessage.init(0xFFFF_FFFF, name_slice, data_slice);
        _ = mgr.pushOutgoing(msg);
    }
}

fn host_net_poll_event(exec_env: c.wasm_exec_env_t, name_buf_ptr: u32, max_name_len: u32, data_buf_ptr: u32, max_data_len: u32, out_sender_id_ptr: u32) callconv(.c) u32 {
    const ctx = getContext(exec_env);
    if (ctx.remote_events) |mgr| {
        if (mgr.popIncoming()) |msg| {
            const mod_inst = c.wasm_runtime_get_module_inst(exec_env);
            const name_host: [*]u8 = @ptrCast(c.wasm_runtime_addr_app_to_native(mod_inst, name_buf_ptr) orelse return 0);
            const data_host: [*]u8 = @ptrCast(c.wasm_runtime_addr_app_to_native(mod_inst, data_buf_ptr) orelse return 0);
            const sender_host: *u32 = @ptrCast(@alignCast(c.wasm_runtime_addr_app_to_native(mod_inst, out_sender_id_ptr) orelse return 0));

            const copy_name_len = @min(msg.name_len, max_name_len);
            @memcpy(name_host[0..copy_name_len], msg.name[0..copy_name_len]);

            const copy_data_len = @min(msg.payload_len, max_data_len);
            @memcpy(data_host[0..copy_data_len], msg.payload[0..copy_data_len]);

            sender_host.* = msg.sender_id;
            return (@as(u32, copy_name_len) << 16) | @as(u32, copy_data_len);
        }
    }
    return 0;
}

fn host_net_get_rtt(exec_env: c.wasm_exec_env_t) callconv(.c) f32 {
    const ctx = getContext(exec_env);
    return ctx.rtt_ms;
}

fn host_net_is_connected(exec_env: c.wasm_exec_env_t) callconv(.c) u32 {
    const ctx = getContext(exec_env);
    return if (ctx.is_connected) 1 else 0;
}

fn host_net_get_client_id(exec_env: c.wasm_exec_env_t) callconv(.c) u32 {
    const ctx = getContext(exec_env);
    return ctx.client_id;
}

fn host_task_wait(exec_env: c.wasm_exec_env_t, slot_id: u32, seconds: f32) callconv(.c) f32 {
    const ctx = getContext(exec_env);
    if (ctx.task_scheduler) |ts| {
        return ts.wait(slot_id, seconds);
    }
    return 0.0;
}

fn host_task_cancel(exec_env: c.wasm_exec_env_t, task_id: u32) callconv(.c) i32 {
    const ctx = getContext(exec_env);
    if (ctx.task_scheduler) |ts| {
        return if (ts.cancel(task_id)) 1 else 0;
    }
    return 0;
}

// -------------------------------------------------------------------------------------------------
// Custom Zig ECS Host API Implementations (1:1 Unified Entity IDs)
// -------------------------------------------------------------------------------------------------

fn host_ecs_register_component(
    exec_env: c.wasm_exec_env_t,
    name_ptr: u32,
    name_len: u32,
    size: u32,
    align_val: u32,
) callconv(.c) u64 {
    const ctx = getContext(exec_env);
    const ecs = ctx.ecs orelse return 0;
    const mod_inst = c.wasm_runtime_get_module_inst(exec_env);
    const name_slice = if (name_len > 0) (wamr.getGuestMemorySlice(mod_inst, name_ptr, name_len) orelse return 0) else return 0;
    return ecs.registerDynamicComponent(name_slice, size, align_val);
}

fn host_ecs_get_component_id(
    exec_env: c.wasm_exec_env_t,
    name_ptr: u32,
    name_len: u32,
) callconv(.c) u64 {
    const ctx = getContext(exec_env);
    const ecs = ctx.ecs orelse return 0;
    const mod_inst = c.wasm_runtime_get_module_inst(exec_env);
    const name_slice = if (name_len > 0) (wamr.getGuestMemorySlice(mod_inst, name_ptr, name_len) orelse return 0) else return 0;
    return ecs.getComponentIdByName(name_slice) orelse 0;
}

fn host_ecs_get_builtin_component(
    exec_env: c.wasm_exec_env_t,
    builtin_type: u32,
) callconv(.c) u64 {
    const ctx = getContext(exec_env);
    const ecs = ctx.ecs orelse return 0;
    return ecs.getBuiltinComponentId(builtin_type) orelse 0;
}

fn host_ecs_new_entity(
    exec_env: c.wasm_exec_env_t,
    name_ptr: u32,
    name_len: u32,
) callconv(.c) u64 {
    const ctx = getContext(exec_env);
    const ecs = ctx.ecs orelse return 0;
    var name_buf: [65]u8 = [_]u8{0} ** 65;
    const name_slice: ?[:0]const u8 = if (name_len > 0) blk: {
        const mod_inst = c.wasm_runtime_get_module_inst(exec_env);
        if (wamr.getGuestMemorySlice(mod_inst, name_ptr, name_len)) |slice| {
            const len = @min(slice.len, 64);
            @memcpy(name_buf[0..len], slice[0..len]);
            name_buf[len] = 0;
            break :blk name_buf[0..len :0];
        }
        break :blk null;
    } else null;

    // Allocate a unified 1:1 entity slot (starting at 1 so > 0 for ECS callers)
    var slot: u32 = 1;
    while (slot < game_state.MAX_ENTITIES) : (slot += 1) {
        const state_busy = if (ctx.host_state) |state| state.entities[slot].active != 0 else false;
        if (!state_busy and !ecs.isAlive(slot)) {
            if (ctx.host_state) |state| {
                state.initSlot(slot);
            }
            const new_ent_id = ecs.initSlot(slot, name_slice);
            std.debug.print("host_ecs_new_entity: Created entity with ID {d} and name '{s}'\n", .{ new_ent_id, name_slice orelse "Unnamed" });
            return new_ent_id;
        }
    }

    return 0;
}

fn host_ecs_delete_entity(
    exec_env: c.wasm_exec_env_t,
    entity_id: u64,
) callconv(.c) i32 {
    const ctx = getContext(exec_env);
    const ecs = ctx.ecs orelse return 0;
    if (ecs.isAlive(entity_id)) {
        ecs.deleteEntity(entity_id);
        if (ctx.host_state) |state| {
            _ = state.freeEntitySlot(entity_id);
        }
        return 1;
    }
    return 0;
}

fn host_ecs_is_alive(
    exec_env: c.wasm_exec_env_t,
    entity_id: u64,
) callconv(.c) i32 {
    const ctx = getContext(exec_env);
    const ecs = ctx.ecs orelse return 0;
    return if (ecs.isAlive(entity_id)) 1 else 0;
}

fn host_ecs_set_component(
    exec_env: c.wasm_exec_env_t,
    entity_id: u64,
    comp_id: u64,
    data_ptr: u32,
    data_len: u32,
) callconv(.c) i32 {
    const ctx = getContext(exec_env);
    const ecs = ctx.ecs orelse return 0;
    if (entity_id >= game_state.MAX_ENTITIES or comp_id == 0) return 0;
    const mod_inst = c.wasm_runtime_get_module_inst(exec_env);
    const data_slice = if (data_len > 0) (wamr.getGuestMemorySlice(mod_inst, data_ptr, data_len) orelse return 0) else &[_]u8{};
    return if (ecs.setComponentData(entity_id, comp_id, data_slice)) 1 else 0;
}

fn host_ecs_get_component(
    exec_env: c.wasm_exec_env_t,
    entity_id: u64,
    comp_id: u64,
    out_ptr: u32,
    max_len: u32,
) callconv(.c) i32 {
    const ctx = getContext(exec_env);
    const ecs = ctx.ecs orelse return -1;
    if (entity_id >= game_state.MAX_ENTITIES or comp_id == 0 or max_len == 0) return -1;
    const mod_inst = c.wasm_runtime_get_module_inst(exec_env);
    const out_slice = wamr.getGuestMemorySliceMut(mod_inst, out_ptr, max_len) orelse return -1;
    if (ecs.getComponentData(entity_id, comp_id, out_slice)) |copied| {
        return @intCast(copied);
    }
    return -1;
}

fn host_ecs_has_component(
    exec_env: c.wasm_exec_env_t,
    entity_id: u64,
    comp_id: u64,
) callconv(.c) i32 {
    const ctx = getContext(exec_env);
    const ecs = ctx.ecs orelse return 0;
    return if (ecs.hasComponent(entity_id, comp_id)) 1 else 0;
}

fn host_ecs_remove_component(
    exec_env: c.wasm_exec_env_t,
    entity_id: u64,
    comp_id: u64,
) callconv(.c) i32 {
    const ctx = getContext(exec_env);
    const ecs = ctx.ecs orelse return 0;
    if (entity_id < game_state.MAX_ENTITIES and comp_id != 0) {
        ecs.removeComponent(entity_id, comp_id);
        return 1;
    }
    return 0;
}

fn host_ecs_query_entities(
    exec_env: c.wasm_exec_env_t,
    comp_ids_ptr: u32,
    comp_count: u32,
    out_entities_ptr: u32,
    max_entities: u32,
) callconv(.c) u32 {
    const ctx = getContext(exec_env);
    const ecs = ctx.ecs orelse return 0;
    if (comp_count == 0 or max_entities == 0) return 0;

    const mod_inst = c.wasm_runtime_get_module_inst(exec_env);
    const comp_bytes = wamr.getGuestMemorySlice(mod_inst, comp_ids_ptr, comp_count * @sizeOf(u64)) orelse return 0;
    const out_bytes = wamr.getGuestMemorySliceMut(mod_inst, out_entities_ptr, max_entities * @sizeOf(u64)) orelse return 0;

    var comp_ids_buf: [8]u64 = [_]u64{0} ** 8;
    const safe_comp_count = @min(comp_count, 8);
    for (0..safe_comp_count) |i| {
        const offset = i * @sizeOf(u64);
        if (offset + @sizeOf(u64) <= comp_bytes.len) {
            comp_ids_buf[i] = std.mem.readInt(u64, comp_bytes[offset..][0..8], .little);
        }
    }

    var temp_buf: [game_state.MAX_ENTITIES]u64 = undefined;
    const fetch_limit = @min(max_entities, temp_buf.len);
    const found = ecs.queryEntities(comp_ids_buf[0..safe_comp_count], temp_buf[0..fetch_limit]);
    for (0..found) |i| {
        const val = temp_buf[i];
        const offset = i * @sizeOf(u64);
        if (offset + @sizeOf(u64) <= out_bytes.len) {
            std.mem.writeInt(u64, out_bytes[offset..][0..8], val, .little);
        }
    }
    return @intCast(found);
}

fn host_ecs_query_count(
    exec_env: c.wasm_exec_env_t,
    comp_ids_ptr: u32,
    comp_count: u32,
) callconv(.c) u32 {
    const ctx = getContext(exec_env);
    const ecs = ctx.ecs orelse return 0;
    if (comp_count == 0) return 0;

    const mod_inst = c.wasm_runtime_get_module_inst(exec_env);
    const comp_bytes = wamr.getGuestMemorySlice(mod_inst, comp_ids_ptr, comp_count * @sizeOf(u64)) orelse return 0;

    var comp_ids_buf: [8]u64 = [_]u64{0} ** 8;
    const safe_count = @min(comp_count, 8);
    for (0..safe_count) |i| {
        const offset = i * @sizeOf(u64);
        if (offset + @sizeOf(u64) <= comp_bytes.len) {
            comp_ids_buf[i] = std.mem.readInt(u64, comp_bytes[offset..][0..8], .little);
        }
    }

    return @intCast(ecs.countEntities(comp_ids_buf[0..safe_count]));
}

fn host_ecs_register_system(
    exec_env: c.wasm_exec_env_t,
    name_ptr: u32,
    name_len: u32,
    comp_ids_ptr: u32,
    comp_count: u32,
) callconv(.c) u32 {
    const ctx = getContext(exec_env);
    const ecs = ctx.ecs orelse return 0;
    const mod_inst = c.wasm_runtime_get_module_inst(exec_env);

    const name_slice = if (name_len > 0) (wamr.getGuestMemorySlice(mod_inst, name_ptr, name_len) orelse "System") else "System";

    var comp_ids_buf: [8]u64 = [_]u64{0} ** 8;
    const safe_count = @min(comp_count, 8);
    if (safe_count > 0) {
        if (wamr.getGuestMemorySlice(mod_inst, comp_ids_ptr, safe_count * @sizeOf(u64))) |bytes| {
            for (0..safe_count) |i| {
                const offset = i * @sizeOf(u64);
                if (offset + @sizeOf(u64) <= bytes.len) {
                    comp_ids_buf[i] = std.mem.readInt(u64, bytes[offset..][0..8], .little);
                }
            }
        }
    }

    return ecs.registerSystem(name_slice, comp_ids_buf[0..safe_count]);
}

fn host_ecs_set_system_enabled(
    exec_env: c.wasm_exec_env_t,
    sys_id: u32,
    enabled: u32,
) callconv(.c) i32 {
    const ctx = getContext(exec_env);
    const ecs = ctx.ecs orelse return 0;
    return if (ecs.setSystemEnabled(sys_id, enabled != 0)) 1 else 0;
}

// -------------------------------------------------------------------------------------------------
// Native Symbol Table for WAMR Registration
// -------------------------------------------------------------------------------------------------

fn toFuncPtr(f: anytype) ?*anyopaque {
    return @ptrCast(@constCast(&f));
}

var native_symbols = [_]c.NativeSymbol{
    .{ .symbol = "engine_apply_impulse", .func_ptr = toFuncPtr(host_apply_impulse), .signature = "(Ifff)", .attachment = null },
    .{ .symbol = "engine_set_player_velocity", .func_ptr = toFuncPtr(host_set_player_velocity), .signature = "(ifff)", .attachment = null },
    .{ .symbol = "engine_teleport_player", .func_ptr = toFuncPtr(host_teleport_player), .signature = "(ifff)", .attachment = null },
    .{ .symbol = "engine_spawn_entity", .func_ptr = toFuncPtr(host_spawn_entity), .signature = "(ifffffff)I", .attachment = null },
    .{ .symbol = "engine_despawn_entity", .func_ptr = toFuncPtr(host_despawn_entity), .signature = "(I)", .attachment = null },
    .{ .symbol = "engine_rotate", .func_ptr = toFuncPtr(host_rotate), .signature = "(ff)", .attachment = null },
    .{ .symbol = "engine_set_scene_rotation", .func_ptr = toFuncPtr(host_set_scene_rotation), .signature = "(ff)", .attachment = null },
    .{ .symbol = "engine_set_camera_distance", .func_ptr = toFuncPtr(host_set_camera_distance), .signature = "(f)", .attachment = null },
    .{ .symbol = "engine_set_cube_color", .func_ptr = toFuncPtr(host_set_cube_color), .signature = "(ifff)", .attachment = null },
    .{ .symbol = "engine_log", .func_ptr = toFuncPtr(host_log), .signature = "(ii)", .attachment = null },
    .{ .symbol = "engine_set_entity_local_pos", .func_ptr = toFuncPtr(host_set_entity_local_pos), .signature = "(Ifff)", .attachment = null },
    .{ .symbol = "engine_set_entity_local_rot", .func_ptr = toFuncPtr(host_set_entity_local_rot), .signature = "(Ifff)", .attachment = null },
    .{ .symbol = "engine_set_entity_local_scale", .func_ptr = toFuncPtr(host_set_entity_local_scale), .signature = "(Ifff)", .attachment = null },
    .{ .symbol = "engine_set_entity_parent", .func_ptr = toFuncPtr(host_set_entity_parent), .signature = "(II)", .attachment = null },
    .{ .symbol = "engine_set_entity_collider", .func_ptr = toFuncPtr(host_set_entity_collider), .signature = "(Iifff)", .attachment = null },
    .{ .symbol = "engine_set_entity_tag", .func_ptr = toFuncPtr(host_set_entity_tag), .signature = "(Iii)", .attachment = null },
    .{ .symbol = "engine_set_entity_motion_type", .func_ptr = toFuncPtr(host_set_entity_motion_type), .signature = "(Ii)", .attachment = null },
    .{ .symbol = "engine_set_entity_material", .func_ptr = toFuncPtr(host_set_entity_material), .signature = "(Ifffi)", .attachment = null },
    .{ .symbol = "engine_set_entity_color", .func_ptr = toFuncPtr(host_set_entity_color), .signature = "(Iffff)", .attachment = null },
    .{ .symbol = "engine_emit_event", .func_ptr = toFuncPtr(host_emit_event), .signature = "(iIIffffii)", .attachment = null },
    .{ .symbol = "engine_is_action_down", .func_ptr = toFuncPtr(host_is_action_down), .signature = "(i)i", .attachment = null },
    .{ .symbol = "engine_is_action_pressed", .func_ptr = toFuncPtr(host_is_action_pressed), .signature = "(i)i", .attachment = null },
    .{ .symbol = "engine_get_axis", .func_ptr = toFuncPtr(host_get_axis), .signature = "(i)f", .attachment = null },
    .{ .symbol = "engine_get_time", .func_ptr = toFuncPtr(host_get_time), .signature = "()f", .attachment = null },
    .{ .symbol = "engine_get_delta_time", .func_ptr = toFuncPtr(host_get_delta_time), .signature = "()f", .attachment = null },
    .{ .symbol = "engine_get_rotation_x", .func_ptr = toFuncPtr(host_get_rotation_x), .signature = "()f", .attachment = null },
    .{ .symbol = "engine_set_rotation_x", .func_ptr = toFuncPtr(host_set_rotation_x), .signature = "(f)", .attachment = null },
    .{ .symbol = "engine_get_rotation_y", .func_ptr = toFuncPtr(host_get_rotation_y), .signature = "()f", .attachment = null },
    .{ .symbol = "engine_set_rotation_y", .func_ptr = toFuncPtr(host_set_rotation_y), .signature = "(f)", .attachment = null },
    .{ .symbol = "engine_get_camera_distance", .func_ptr = toFuncPtr(host_get_camera_distance), .signature = "()f", .attachment = null },
    .{ .symbol = "engine_is_key_down", .func_ptr = toFuncPtr(host_is_key_down), .signature = "(i)i", .attachment = null },
    .{ .symbol = "engine_is_mouse_button_down", .func_ptr = toFuncPtr(host_is_mouse_button_down), .signature = "(i)i", .attachment = null },
    .{ .symbol = "engine_sin", .func_ptr = toFuncPtr(host_sin), .signature = "(f)f", .attachment = null },
    .{ .symbol = "engine_cos", .func_ptr = toFuncPtr(host_cos), .signature = "(f)f", .attachment = null },
    .{ .symbol = "engine_physics_create_body", .func_ptr = toFuncPtr(host_physics_create_body), .signature = "(Iifffi)i", .attachment = null },
    .{ .symbol = "engine_physics_apply_impulse", .func_ptr = toFuncPtr(host_physics_apply_impulse), .signature = "(ifff)", .attachment = null },
    .{ .symbol = "engine_physics_get_pos_x", .func_ptr = toFuncPtr(host_physics_get_pos_x), .signature = "(i)f", .attachment = null },
    .{ .symbol = "engine_physics_get_pos_y", .func_ptr = toFuncPtr(host_physics_get_pos_y), .signature = "(i)f", .attachment = null },
    .{ .symbol = "engine_physics_get_pos_z", .func_ptr = toFuncPtr(host_physics_get_pos_z), .signature = "(i)f", .attachment = null },
    .{ .symbol = "engine_physics_get_vel_y", .func_ptr = toFuncPtr(host_physics_get_vel_y), .signature = "(i)f", .attachment = null },
    .{ .symbol = "engine_physics_is_active", .func_ptr = toFuncPtr(host_physics_is_active), .signature = "(i)i", .attachment = null },

    // Camera exports
    .{ .symbol = "engine_camera_set_pos", .func_ptr = toFuncPtr(host_camera_set_pos), .signature = "(fff)", .attachment = null },
    .{ .symbol = "engine_camera_set_rot", .func_ptr = toFuncPtr(host_camera_set_rot), .signature = "(ff)", .attachment = null },
    .{ .symbol = "engine_camera_set_fov", .func_ptr = toFuncPtr(host_camera_set_fov), .signature = "(f)", .attachment = null },
    .{ .symbol = "engine_camera_get_pos_x", .func_ptr = toFuncPtr(host_camera_get_pos_x), .signature = "()f", .attachment = null },
    .{ .symbol = "engine_camera_get_pos_y", .func_ptr = toFuncPtr(host_camera_get_pos_y), .signature = "()f", .attachment = null },
    .{ .symbol = "engine_camera_get_pos_z", .func_ptr = toFuncPtr(host_camera_get_pos_z), .signature = "()f", .attachment = null },
    .{ .symbol = "engine_camera_get_yaw", .func_ptr = toFuncPtr(host_camera_get_yaw), .signature = "()f", .attachment = null },
    .{ .symbol = "engine_camera_get_pitch", .func_ptr = toFuncPtr(host_camera_get_pitch), .signature = "()f", .attachment = null },
    .{ .symbol = "engine_camera_screen_to_ray", .func_ptr = toFuncPtr(host_camera_screen_to_ray), .signature = "(ffff)i", .attachment = null },
    .{ .symbol = "engine_camera_get_ray_origin_x", .func_ptr = toFuncPtr(host_camera_get_ray_origin_x), .signature = "()f", .attachment = null },
    .{ .symbol = "engine_camera_get_ray_origin_y", .func_ptr = toFuncPtr(host_camera_get_ray_origin_y), .signature = "()f", .attachment = null },
    .{ .symbol = "engine_camera_get_ray_origin_z", .func_ptr = toFuncPtr(host_camera_get_ray_origin_z), .signature = "()f", .attachment = null },
    .{ .symbol = "engine_camera_get_ray_dir_x", .func_ptr = toFuncPtr(host_camera_get_ray_dir_x), .signature = "()f", .attachment = null },
    .{ .symbol = "engine_camera_get_ray_dir_y", .func_ptr = toFuncPtr(host_camera_get_ray_dir_y), .signature = "()f", .attachment = null },
    .{ .symbol = "engine_camera_get_ray_dir_z", .func_ptr = toFuncPtr(host_camera_get_ray_dir_z), .signature = "()f", .attachment = null },

    // Raycast exports
    .{ .symbol = "engine_physics_cast_ray", .func_ptr = toFuncPtr(host_physics_cast_ray), .signature = "(ffffffi)i", .attachment = null },

    // Shapecast & collision layer exports
    .{ .symbol = "engine_physics_cast_sphere", .func_ptr = toFuncPtr(host_physics_cast_sphere), .signature = "(fffffffii)i", .attachment = null },
    .{ .symbol = "engine_physics_cast_box", .func_ptr = toFuncPtr(host_physics_cast_box), .signature = "(fffffffffii)i", .attachment = null },
    .{ .symbol = "engine_physics_set_collision_layer", .func_ptr = toFuncPtr(host_physics_set_collision_layer), .signature = "(ii)", .attachment = null },
    .{ .symbol = "engine_physics_set_layer_collision", .func_ptr = toFuncPtr(host_physics_set_layer_collision), .signature = "(iii)", .attachment = null },

    // Character controller exports
    .{ .symbol = "engine_character_create", .func_ptr = toFuncPtr(host_character_create), .signature = "(fffff)i", .attachment = null },
    .{ .symbol = "engine_character_destroy", .func_ptr = toFuncPtr(host_character_destroy), .signature = "(i)", .attachment = null },
    .{ .symbol = "engine_character_set_linear_velocity", .func_ptr = toFuncPtr(host_character_set_linear_velocity), .signature = "(ifff)", .attachment = null },
    .{ .symbol = "engine_character_set_position", .func_ptr = toFuncPtr(host_character_set_position), .signature = "(ifff)", .attachment = null },
    .{ .symbol = "engine_character_get_ground_state", .func_ptr = toFuncPtr(host_character_get_ground_state), .signature = "(i)i", .attachment = null },
    .{ .symbol = "engine_character_get_pos_x", .func_ptr = toFuncPtr(host_character_get_pos_x), .signature = "(i)f", .attachment = null },
    .{ .symbol = "engine_character_get_pos_y", .func_ptr = toFuncPtr(host_character_get_pos_y), .signature = "(i)f", .attachment = null },
    .{ .symbol = "engine_character_get_pos_z", .func_ptr = toFuncPtr(host_character_get_pos_z), .signature = "(i)f", .attachment = null },
    .{ .symbol = "engine_character_get_vel_y", .func_ptr = toFuncPtr(host_character_get_vel_y), .signature = "(i)f", .attachment = null },

    // Constraint exports
    .{ .symbol = "engine_constraint_create_hinge", .func_ptr = toFuncPtr(host_constraint_create_hinge), .signature = "(iiffffffff)i", .attachment = null },
    .{ .symbol = "engine_constraint_create_ball_socket", .func_ptr = toFuncPtr(host_constraint_create_ball_socket), .signature = "(iifff)i", .attachment = null },
    .{ .symbol = "engine_constraint_create_slider", .func_ptr = toFuncPtr(host_constraint_create_slider), .signature = "(iifffff)i", .attachment = null },
    .{ .symbol = "engine_constraint_create_weld", .func_ptr = toFuncPtr(host_constraint_create_weld), .signature = "(ii)i", .attachment = null },
    .{ .symbol = "engine_constraint_destroy", .func_ptr = toFuncPtr(host_constraint_destroy), .signature = "(i)", .attachment = null },

    // UI exports
    .{ .symbol = "engine_ui_draw_rect", .func_ptr = toFuncPtr(host_ui_draw_rect), .signature = "(ffffffff)", .attachment = null },
    .{ .symbol = "engine_ui_draw_rect_border", .func_ptr = toFuncPtr(host_ui_draw_rect_border), .signature = "(fffffffff)", .attachment = null },
    .{ .symbol = "engine_ui_draw_crosshair", .func_ptr = toFuncPtr(host_ui_draw_crosshair), .signature = "(ffffffff)", .attachment = null },
    .{ .symbol = "engine_ui_draw_progress_bar", .func_ptr = toFuncPtr(host_ui_draw_progress_bar), .signature = "(fffffffffffff)", .attachment = null },
    .{ .symbol = "engine_ui_draw_selection_box", .func_ptr = toFuncPtr(host_ui_draw_selection_box), .signature = "(ffffffffffff)", .attachment = null },
    .{ .symbol = "engine_ui_draw_text", .func_ptr = toFuncPtr(host_ui_draw_text), .signature = "(iifffffff)", .attachment = null },

    // Audio exports
    .{ .symbol = "engine_audio_play_tone", .func_ptr = toFuncPtr(host_audio_play_tone), .signature = "(fff)", .attachment = null },
    .{ .symbol = "engine_audio_play_impact", .func_ptr = toFuncPtr(host_audio_play_impact), .signature = "(f)", .attachment = null },
    .{ .symbol = "engine_audio_play_chime", .func_ptr = toFuncPtr(host_audio_play_chime), .signature = "(f)", .attachment = null },

    // Window exports
    .{ .symbol = "engine_window_set_relative_mouse", .func_ptr = toFuncPtr(host_window_set_relative_mouse), .signature = "(i)i", .attachment = null },
    .{ .symbol = "engine_window_get_screen_w", .func_ptr = toFuncPtr(host_window_get_screen_w), .signature = "()f", .attachment = null },
    .{ .symbol = "engine_window_get_screen_h", .func_ptr = toFuncPtr(host_window_get_screen_h), .signature = "()f", .attachment = null },

    // Particle exports
    .{ .symbol = "engine_particle_spawn_burst", .func_ptr = toFuncPtr(host_particle_spawn_burst), .signature = "(fffifffffff)", .attachment = null },

    // Networking exports
    .{ .symbol = "engine_net_fire_server", .func_ptr = toFuncPtr(host_net_fire_server), .signature = "(iiii)", .attachment = null },
    .{ .symbol = "engine_net_fire_client", .func_ptr = toFuncPtr(host_net_fire_client), .signature = "(iiiii)", .attachment = null },
    .{ .symbol = "engine_net_fire_all_clients", .func_ptr = toFuncPtr(host_net_fire_all_clients), .signature = "(iiii)", .attachment = null },
    .{ .symbol = "engine_net_poll_event", .func_ptr = toFuncPtr(host_net_poll_event), .signature = "(iiiii)i", .attachment = null },
    .{ .symbol = "engine_net_get_rtt", .func_ptr = toFuncPtr(host_net_get_rtt), .signature = "()f", .attachment = null },
    .{ .symbol = "engine_net_is_connected", .func_ptr = toFuncPtr(host_net_is_connected), .signature = "()i", .attachment = null },
    .{ .symbol = "engine_net_get_client_id", .func_ptr = toFuncPtr(host_net_get_client_id), .signature = "()i", .attachment = null },

    // Task scheduler exports
    .{ .symbol = "engine_task_wait", .func_ptr = toFuncPtr(host_task_wait), .signature = "(if)f", .attachment = null },
    .{ .symbol = "engine_task_cancel", .func_ptr = toFuncPtr(host_task_cancel), .signature = "(i)i", .attachment = null },

    // Flecs ECS dynamic component, entity, and system exports
    .{ .symbol = "engine_ecs_register_component", .func_ptr = toFuncPtr(host_ecs_register_component), .signature = "(iiii)I", .attachment = null },
    .{ .symbol = "engine_ecs_get_component_id", .func_ptr = toFuncPtr(host_ecs_get_component_id), .signature = "(ii)I", .attachment = null },
    .{ .symbol = "engine_ecs_get_builtin_component", .func_ptr = toFuncPtr(host_ecs_get_builtin_component), .signature = "(i)I", .attachment = null },
    .{ .symbol = "engine_ecs_new_entity", .func_ptr = toFuncPtr(host_ecs_new_entity), .signature = "(ii)I", .attachment = null },
    .{ .symbol = "engine_ecs_delete_entity", .func_ptr = toFuncPtr(host_ecs_delete_entity), .signature = "(I)i", .attachment = null },
    .{ .symbol = "engine_ecs_is_alive", .func_ptr = toFuncPtr(host_ecs_is_alive), .signature = "(I)i", .attachment = null },
    .{ .symbol = "engine_ecs_set_component", .func_ptr = toFuncPtr(host_ecs_set_component), .signature = "(IIii)i", .attachment = null },
    .{ .symbol = "engine_ecs_get_component", .func_ptr = toFuncPtr(host_ecs_get_component), .signature = "(IIii)i", .attachment = null },
    .{ .symbol = "engine_ecs_has_component", .func_ptr = toFuncPtr(host_ecs_has_component), .signature = "(II)i", .attachment = null },
    .{ .symbol = "engine_ecs_remove_component", .func_ptr = toFuncPtr(host_ecs_remove_component), .signature = "(II)i", .attachment = null },
    .{ .symbol = "engine_ecs_query_entities", .func_ptr = toFuncPtr(host_ecs_query_entities), .signature = "(iiii)i", .attachment = null },
    .{ .symbol = "engine_ecs_query_count", .func_ptr = toFuncPtr(host_ecs_query_count), .signature = "(ii)i", .attachment = null },
    .{ .symbol = "engine_ecs_register_system", .func_ptr = toFuncPtr(host_ecs_register_system), .signature = "(iiii)i", .attachment = null },
    .{ .symbol = "engine_ecs_set_system_enabled", .func_ptr = toFuncPtr(host_ecs_set_system_enabled), .signature = "(ii)i", .attachment = null },
};

var apis_registered: bool = false;

pub fn registerEngineApis() wamr.WasmError!void {
    if (apis_registered) return;
    if (!c.wasm_runtime_register_natives("engine", &native_symbols, native_symbols.len)) {
        return wamr.WasmError.LinkFunctionFailed;
    }
    apis_registered = true;
}

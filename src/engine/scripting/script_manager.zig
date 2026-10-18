const std = @import("std");
const wamr = @import("wamr_bindings.zig");
const c = wamr.c;
const engine_api = @import("engine_api.zig");
const EngineContext = engine_api.EngineContext;
const flecs = @import("../ecs/ecs.zig");
const game_state = @import("../state/game_state.zig");
const GameState = game_state.GameState;

extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) c_int;
extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) c_int;
extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

pub fn sleepMs(ms: u32) void {
    if (@import("builtin").os.tag == .windows) {
        Sleep(ms);
    } else {
        _ = std.c.usleep(ms * 1000);
    }
}

pub fn getTimestampNs() i64 {
    if (@import("builtin").os.tag == .windows) {
        var count: i64 = 0;
        var freq: i64 = 1;
        _ = QueryPerformanceCounter(&count);
        _ = QueryPerformanceFrequency(&freq);
        if (freq <= 0) return 0;
        const total_ns = @divTrunc(@as(i128, count) * 1_000_000_000, @as(i128, freq));
        return @intCast(total_ns);
    } else {
        return @intCast(std.c.time(null) * 1_000_000_000);
    }
}

/// Watchdog thread that monitors script instance execution deadlines.
/// If an instance exceeds its allocated execution timeout, the watchdog triggers
/// wasm_runtime_terminate() asynchronously, cleanly interrupting rogue scripts.
pub const Watchdog = struct {
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    active_inst: std.atomic.Value(c.wasm_module_inst_t) = std.atomic.Value(c.wasm_module_inst_t).init(null),
    deadline_ns: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    terminated: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init() !Watchdog {
        var self = Watchdog{};
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, watchdogWorker, .{&self});
        return self;
    }

    pub fn deinit(self: *Watchdog) void {
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn arm(self: *Watchdog, inst: c.wasm_module_inst_t, timeout_ns: u64) void {
        const now = getTimestampNs();
        self.terminated.store(false, .release);
        self.deadline_ns.store(now + @as(i64, @intCast(timeout_ns)), .release);
        self.active_inst.store(inst, .release);
    }

    pub fn disarm(self: *Watchdog) bool {
        const was_term = self.terminated.swap(false, .acq_rel);
        self.active_inst.store(null, .release);
        self.deadline_ns.store(0, .release);
        return was_term;
    }

    fn watchdogWorker(self: *Watchdog) void {
        while (self.running.load(.acquire)) {
            const inst_opt = self.active_inst.load(.acquire);
            if (inst_opt) |inst| {
                const deadline = self.deadline_ns.load(.acquire);
                const now = getTimestampNs();

                if (deadline > 0 and now >= deadline) {
                    // Deadline exceeded! Terminate module instance
                    c.wasm_runtime_terminate(inst);
                    self.terminated.store(true, .release);
                    self.active_inst.store(null, .release);
                    self.deadline_ns.store(0, .release);
                }
            }
            sleepMs(1);
        }
    }
};

pub const LoadedModule = struct {
    id: u32,
    module: c.wasm_module_t,
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    owned_bytes: ?[]u8 = null,
    is_aot: bool = false,
};

pub const ScriptInstance = struct {
    id: u32,
    module_id: u32,
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
    entity: ?flecs.Entity = null,
    entity_id: u64 = 0,
    module_inst: ?c.wasm_module_inst_t = null,
    exec_env: ?c.wasm_exec_env_t = null,
    fn_init: ?wamr.WasmFunction = null,
    fn_update: ?wamr.WasmFunction = null,
    fn_get_shared_buf: ?wamr.WasmFunction = null,
    guest_buffer_offset: ?u32 = null,
    stack_size: u32 = 65536,
    heap_size: u32 = 65536,

    enabled: bool = true,
    errored: bool = false,
    error_msg: [128]u8 = [_]u8{0} ** 128,
    error_msg_len: usize = 0,

    instruction_limit: i32 = -1,
    timeout_ns: u64 = 50_000_000, // 50ms default watchdog timeout
    execution_count: u64 = 0,
    last_execution_duration_ns: u64 = 0,
    total_execution_duration_ns: u64 = 0,

    pub fn getName(self: *const ScriptInstance) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getError(self: *const ScriptInstance) []const u8 {
        return self.error_msg[0..self.error_msg_len];
    }

    pub fn getLinearMemory(self: *const ScriptInstance) ?[]u8 {
        const inst = self.module_inst orelse return null;
        return wamr.getModuleLinearMemory(inst);
    }
};

pub const ScriptManager = struct {
    allocator: std.mem.Allocator,
    context: *EngineContext,
    modules: std.ArrayListUnmanaged(LoadedModule) = .empty,
    instances: std.ArrayListUnmanaged(ScriptInstance) = .empty,
    next_module_id: u32 = 1,
    next_instance_id: u32 = 1,
    watchdog: ?Watchdog = null,
    default_timeout_ns: u64 = 50_000_000, // 50ms
    default_instruction_limit: i32 = -1,

    pub fn init(allocator: std.mem.Allocator, context: *EngineContext) !ScriptManager {
        if (!c.wasm_runtime_init()) {
            return wamr.WasmError.RuntimeInitFailed;
        }

        try engine_api.registerEngineApis();

        const watchdog = Watchdog.init() catch null;

        return .{
            .allocator = allocator,
            .context = context,
            .watchdog = watchdog,
        };
    }

    pub fn deinit(self: *ScriptManager) void {
        if (self.watchdog) |*wd| {
            wd.deinit();
            self.watchdog = null;
        }

        for (self.instances.items) |*inst| {
            self.destroyInstanceInternal(inst);
        }
        self.instances.deinit(self.allocator);

        for (self.modules.items) |*mod| {
            c.wasm_runtime_unload(mod.module);
            if (mod.owned_bytes) |bytes| {
                self.allocator.free(bytes);
            }
        }
        self.modules.deinit(self.allocator);
    }

    pub fn loadModule(self: *ScriptManager, wasm_bytes: []const u8, name: []const u8) !u32 {
        var error_buf: [128]u8 = [_]u8{0} ** 128;

        const owned = try self.allocator.alloc(u8, wasm_bytes.len);
        @memcpy(owned, wasm_bytes);

        var load_args = std.mem.zeroes(c.LoadArgs);
        load_args.wasm_binary_freeable = false;

        const mod = c.wasm_runtime_load_ex(
            owned.ptr,
            @intCast(owned.len),
            &load_args,
            &error_buf,
            error_buf.len,
        ) orelse {
            self.allocator.free(owned);
            std.log.err("ScriptManager: wasm_runtime_load_ex failed: {s}", .{&error_buf});
            return error.LoadModuleFailed;
        };

        const is_aot = (c.wasm_runtime_get_module_package_type(mod) == c.Wasm_Module_AoT);
        const mod_id = self.next_module_id;
        self.next_module_id += 1;

        var loaded = LoadedModule{
            .id = mod_id,
            .module = mod,
            .owned_bytes = owned,
            .is_aot = is_aot,
        };
        const copy_name_len = @min(name.len, loaded.name.len);
        @memcpy(loaded.name[0..copy_name_len], name[0..copy_name_len]);
        loaded.name_len = copy_name_len;

        try self.modules.append(self.allocator, loaded);
        return mod_id;
    }

    pub fn getModule(self: *ScriptManager, module_id: u32) ?*LoadedModule {
        for (self.modules.items) |*mod| {
            if (mod.id == module_id) return mod;
        }
        return null;
    }

    pub fn createInstance(self: *ScriptManager, module_id: u32, name: ?[]const u8) !*ScriptInstance {
        const mod = self.getModule(module_id) orelse return error.ModuleNotFound;
        var error_buf: [128]u8 = [_]u8{0} ** 128;

        const stack_size: u32 = 65536;
        const heap_size: u32 = 65536;

        const inst = c.wasm_runtime_instantiate(
            mod.module,
            stack_size,
            heap_size,
            &error_buf,
            error_buf.len,
        ) orelse {
            std.log.err("ScriptManager: wasm_runtime_instantiate failed: {s}", .{&error_buf});
            return error.InstantiateModuleFailed;
        };

        c.wasm_runtime_set_custom_data(inst, @ptrCast(self.context));

        const exec_env = c.wasm_runtime_create_exec_env(inst, stack_size) orelse {
            c.wasm_runtime_deinstantiate(inst);
            return error.CreateExecEnvFailed;
        };

        const instance_id = self.next_instance_id;
        self.next_instance_id += 1;

        var script_inst = ScriptInstance{
            .id = instance_id,
            .module_id = module_id,
            .module_inst = inst,
            .exec_env = exec_env,
            .stack_size = stack_size,
            .heap_size = heap_size,
            .instruction_limit = self.default_instruction_limit,
            .timeout_ns = self.default_timeout_ns,
        };

        if (name) |n| {
            const clen = @min(n.len, script_inst.name.len);
            @memcpy(script_inst.name[0..clen], n[0..clen]);
            script_inst.name_len = clen;
        }

        // Discover entrypoints
        if (c.wasm_runtime_lookup_function(inst, "on_init")) |f| {
            script_inst.fn_init = .{ .raw = f, .exec_env = exec_env, .module_inst = inst };
        }
        if (c.wasm_runtime_lookup_function(inst, "on_update")) |f| {
            script_inst.fn_update = .{ .raw = f, .exec_env = exec_env, .module_inst = inst };
        }
        if (c.wasm_runtime_lookup_function(inst, "get_shared_buffer_ptr")) |f| {
            script_inst.fn_get_shared_buf = .{ .raw = f, .exec_env = exec_env, .module_inst = inst };
        }

        if (script_inst.fn_get_shared_buf) |f| {
            if (f.call0RetU32()) |offset| {
                script_inst.guest_buffer_offset = offset;
                if (wamr.getGuestMemorySliceMut(inst, offset, @sizeOf(GameState))) |slice| {
                    const wasm_state: *GameState = @ptrCast(@alignCast(slice.ptr));
                    if (self.context.host_state) |prev| {
                        if (prev != wasm_state) {
                            wasm_state.* = prev.*;
                        }
                    } else {
                        wasm_state.* = GameState.initDefault();
                    }
                    self.context.guest_buffer_offset = offset;
                    self.context.host_state = wasm_state;
                    self.context.guest_state = wasm_state;
                    const ecs_align = @as(usize, @alignOf(game_state.SharedEcsWorld));
                    const ecs_offset = offset + @as(u32, @intCast((@sizeOf(GameState) + ecs_align - 1) & ~(ecs_align - 1)));
                    if (wamr.getGuestMemorySliceMut(inst, ecs_offset, @sizeOf(game_state.SharedEcsWorld))) |ecs_slice| {
                        const wasm_ecs: *game_state.SharedEcsWorld = @ptrCast(@alignCast(ecs_slice.ptr));
                        if (self.context.shared_ecs) |prev_ecs| {
                            if (prev_ecs != wasm_ecs) wasm_ecs.* = prev_ecs.*;
                        } else {
                            wasm_ecs.* = .{};
                        }
                        self.context.shared_ecs = wasm_ecs;
                        if (self.context.ecs) |ew| ew.attachSharedWorld(wasm_ecs);
                    }
                }
            } else |_| {}
        }

        try self.instances.append(self.allocator, script_inst);
        return &self.instances.items[self.instances.items.len - 1];
    }

    pub fn createInstanceFromBytes(self: *ScriptManager, wasm_bytes: []const u8, name: ?[]const u8) !*ScriptInstance {
        const mod_name = name orelse "unnamed_script";
        const mod_id = try self.loadModule(wasm_bytes, mod_name);
        return try self.createInstance(mod_id, name);
    }

    pub fn getInstance(self: *ScriptManager, instance_id: u32) ?*ScriptInstance {
        for (self.instances.items) |*inst| {
            if (inst.id == instance_id) return inst;
        }
        return null;
    }

    pub fn getInstanceByEntity(self: *ScriptManager, entity: flecs.Entity) ?*ScriptInstance {
        for (self.instances.items) |*inst| {
            if (inst.entity != null and inst.entity.? == entity) return inst;
        }
        return null;
    }

    pub fn attachToEntity(self: *ScriptManager, instance_id: u32, entity: flecs.Entity) !void {
        const inst = self.getInstance(instance_id) orelse return error.InstanceNotFound;
        inst.entity = entity;
        inst.entity_id = entity;

        if (self.context.ecs) |world| {
            world.setScript(entity, .{
                .instance_id = instance_id,
                .enabled = inst.enabled,
            });
        }
    }

    fn destroyInstanceInternal(self: *ScriptManager, inst: *ScriptInstance) void {
        _ = self;
        if (inst.exec_env) |env| {
            c.wasm_runtime_destroy_exec_env(env);
            inst.exec_env = null;
        }
        if (inst.module_inst) |mod_inst| {
            c.wasm_runtime_deinstantiate(mod_inst);
            inst.module_inst = null;
        }
    }

    pub fn destroyInstance(self: *ScriptManager, instance_id: u32) void {
        var found_idx: ?usize = null;
        for (self.instances.items, 0..) |*inst, i| {
            if (inst.id == instance_id) {
                if (inst.entity) |e| {
                    if (self.context.ecs) |world| {
                        world.removeScript(e);
                    }
                }
                self.destroyInstanceInternal(inst);
                found_idx = i;
                break;
            }
        }
        if (found_idx) |idx| {
            _ = self.instances.swapRemove(idx);
        }
    }

    pub fn syncSharedState(self: *ScriptManager, inst: *ScriptInstance) void {
        self.context.guest_buffer_offset = inst.guest_buffer_offset;
        _ = self.context.refreshSharedState(inst.module_inst);
    }

    pub fn callInit(self: *ScriptManager, inst: *ScriptInstance) !void {
        if (!inst.enabled or inst.errored) return;
        self.context.guest_buffer_offset = inst.guest_buffer_offset;
        self.context.preTickPrepare(inst.module_inst, 0.0);

        if (inst.fn_init) |f| {
            if (self.watchdog) |*wd| {
                if (inst.module_inst) |m_inst| {
                    wd.arm(m_inst, @max(inst.timeout_ns, 2_000_000_000));
                }
            }
            defer {
                if (self.watchdog) |*wd| {
                    _ = wd.disarm();
                }
            }

            f.call0() catch |err| {
                self.recordError(inst, err);
                return err;
            };
        }

        _ = self.context.refreshSharedState(inst.module_inst);
        self.context.postTickReconcile(0.0);
    }

    pub fn callUpdate(self: *ScriptManager, inst: *ScriptInstance, dt: f32) !void {
        if (!inst.enabled or inst.errored) return;

        self.context.guest_buffer_offset = inst.guest_buffer_offset;
        self.context.preTickPrepare(inst.module_inst, dt);

        if (inst.fn_update) |f| {
            const start_ns = getTimestampNs();

            if (self.watchdog) |*wd| {
                if (inst.module_inst) |m_inst| {
                    wd.arm(m_inst, inst.timeout_ns);
                }
            }

            var errored = false;
            f.call1F32(dt) catch |err| {
                errored = true;
                self.recordError(inst, err);
            };

            const end_ns = getTimestampNs();
            const duration: u64 = if (end_ns > start_ns) @intCast(end_ns - start_ns) else 0;

            const was_watchdog_term = if (self.watchdog) |*wd| wd.disarm() else false;
            if (was_watchdog_term and !errored) {
                errored = true;
                self.recordError(inst, error.ExecutionTimeout);
            }

            inst.last_execution_duration_ns = duration;
            inst.total_execution_duration_ns += duration;
            inst.execution_count += 1;

            if (errored) {
                return error.ScriptExecutionFailed;
            }
        }

        _ = self.context.refreshSharedState(inst.module_inst);
        self.context.postTickReconcile(dt);
    }

    fn recordError(self: *ScriptManager, inst: *ScriptInstance, err: anyerror) void {
        _ = self;
        inst.errored = true;
        inst.enabled = false;

        var err_str: []const u8 = "Unknown error";
        if (inst.module_inst) |m_inst| {
            const raw_exc = c.wasm_runtime_get_exception(m_inst);
            if (raw_exc != null) {
                err_str = std.mem.span(raw_exc);
                c.wasm_runtime_clear_exception(m_inst);
            } else {
                err_str = @errorName(err);
            }
        } else {
            err_str = @errorName(err);
        }

        const copy_len = @min(err_str.len, inst.error_msg.len);
        @memcpy(inst.error_msg[0..copy_len], err_str[0..copy_len]);
        inst.error_msg_len = copy_len;
        std.log.warn("ScriptManager: Instance {d} ('{s}') terminated: {s}", .{
            inst.id,
            inst.getName(),
            inst.getError(),
        });
    }

    /// Step all active registered script instances
    pub fn stepAll(self: *ScriptManager, dt: f32) void {
        for (self.instances.items) |*inst| {
            if (inst.enabled and !inst.errored) {
                self.callUpdate(inst, dt) catch {};
            }
        }
    }

    /// Step scripts attached to ECS entities
    pub fn stepEntityScripts(self: *ScriptManager, ecs: *flecs.EcsWorld, dt: f32) void {
        var entities_buf: [flecs.MAX_ENTITIES]flecs.Entity = undefined;
        const count = ecs.queryEntities(&[_]flecs.ComponentId{ecs.id_script}, &entities_buf);
        for (entities_buf[0..count]) |entity| {
            const sc = ecs.getScript(entity) orelse continue;
            if (!sc.enabled) continue;
            if (self.getInstance(sc.instance_id)) |inst| {
                if (inst.enabled and !inst.errored) {
                    self.callUpdate(inst, dt) catch {};
                }
            }
        }
    }

    pub fn getInstanceCount(self: *const ScriptManager) usize {
        return self.instances.items.len;
    }

    pub fn getActiveCount(self: *const ScriptManager) usize {
        var count: usize = 0;
        for (self.instances.items) |*inst| {
            if (inst.enabled and !inst.errored) count += 1;
        }
        return count;
    }
};

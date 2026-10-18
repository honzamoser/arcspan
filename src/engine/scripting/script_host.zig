const std = @import("std");
const wamr = @import("wamr_bindings.zig");
const c = wamr.c;
const engine_api = @import("engine_api.zig");
const EngineContext = engine_api.EngineContext;
const game_state = @import("../state/game_state.zig");
const GameState = game_state.GameState;

pub const ScriptHost = struct {
    module: ?c.wasm_module_t = null,
    module_inst: ?c.wasm_module_inst_t = null,
    exec_env: ?c.wasm_exec_env_t = null,
    fn_init: ?wamr.WasmFunction = null,
    fn_update: ?wamr.WasmFunction = null,
    fn_get_shared_buf: ?wamr.WasmFunction = null,
    owned_bytes: ?[]const u8 = null,
    allocator: ?std.mem.Allocator = null,
    context: *EngineContext,
    stack_size: u32 = 65536,

    // Fallback heap state before/without a loaded WASM module; once WASM loads,
    // context.host_state and context.guest_state point directly into WASM linear memory.
    fallback_state: ?*GameState = null,
    guest_buffer_offset: ?u32 = null,

    pub fn init(context: *EngineContext, stack_size: u32) wamr.WasmError!ScriptHost {
        // Initialize WAMR runtime environment
        if (!c.wasm_runtime_init()) {
            return wamr.WasmError.RuntimeInitFailed;
        }

        // Register host engine native APIs
        try engine_api.registerEngineApis();

        // Allocate fallback initial state until WASM module's shared_memory_buffer is bound
        const fb = std.heap.page_allocator.create(GameState) catch null;
        if (fb) |state| {
            state.* = GameState.initDefault();
            state.scene.rotation_x = context.scene.rotation_x;
            state.scene.rotation_y = context.scene.rotation_y;
            state.scene.camera_distance = context.scene.camera_distance;
            for (0..6) |i| {
                const col = context.scene.getFaceColor(@intCast(i));
                state.scene.cube_face_colors[i] = [_]f32{ col[0], col[1], col[2], 1.0 };
            }

            context.host_state = state;
            context.guest_state = state;
        }

        return .{
            .context = context,
            .stack_size = stack_size,
            .fallback_state = fb,
        };
    }

    pub fn deinit(self: *ScriptHost) void {
        self.context.host_state = null;
        self.context.guest_state = null;
        self.context.guest_buffer_offset = null;

        if (self.fallback_state) |fb| {
            std.heap.page_allocator.destroy(fb);
            self.fallback_state = null;
        }
        if (self.exec_env) |env| {
            c.wasm_runtime_destroy_exec_env(env);
            self.exec_env = null;
        }
        if (self.module_inst) |inst| {
            c.wasm_runtime_deinstantiate(inst);
            self.module_inst = null;
        }
        if (self.module) |mod| {
            c.wasm_runtime_unload(mod);
            self.module = null;
        }
        if (self.owned_bytes) |bytes| {
            if (self.allocator) |alloc| {
                alloc.free(bytes);
            }
            self.owned_bytes = null;
        }
        self.* = undefined;
    }

    pub fn isAot(self: *const ScriptHost) bool {
        if (self.module) |mod| {
            return c.wasm_runtime_get_module_package_type(mod) == c.Wasm_Module_AoT;
        }
        return false;
    }

    pub fn loadScriptBytes(self: *ScriptHost, wasm_bytes: []const u8) wamr.WasmError!void {
        var error_buf: [128]u8 = [_]u8{0} ** 128;

        // If not already owned and heap-allocated, allocate a mutable buffer copy so WAMR interpreter can rewrite bytecodes
        const mutable_bytes: []u8 = if (self.owned_bytes) |ob| @constCast(ob) else blk: {
            const buf = std.heap.page_allocator.alloc(u8, wasm_bytes.len) catch return wamr.WasmError.LoadModuleFailed;
            @memcpy(buf, wasm_bytes);
            self.owned_bytes = buf;
            self.allocator = std.heap.page_allocator;
            break :blk buf;
        };

        var load_args = std.mem.zeroes(c.LoadArgs);
        load_args.wasm_binary_freeable = false;
        const mod = c.wasm_runtime_load_ex(
            mutable_bytes.ptr,
            @intCast(mutable_bytes.len),
            &load_args,
            &error_buf,
            error_buf.len,
        ) orelse {
            std.log.err("WAMR load module failed: {s}", .{&error_buf});
            return wamr.WasmError.LoadModuleFailed;
        };
        self.module = mod;

        // Instantiate WASM / AOT module
        const inst = c.wasm_runtime_instantiate(
            mod,
            self.stack_size,
            65536,
            &error_buf,
            error_buf.len,
        ) orelse {
            std.log.err("WAMR instantiate module failed: {s}", .{&error_buf});
            return wamr.WasmError.InstantiateModuleFailed;
        };
        self.module_inst = inst;

        // Attach EngineContext to module instance
        c.wasm_runtime_set_custom_data(inst, @ptrCast(self.context));

        // Create execution environment
        const exec_env = c.wasm_runtime_create_exec_env(inst, self.stack_size) orelse {
            return wamr.WasmError.CreateExecEnvFailed;
        };
        self.exec_env = exec_env;

        // Discover optional script entry points
        if (c.wasm_runtime_lookup_function(inst, "on_init")) |f| {
            self.fn_init = .{ .raw = f, .exec_env = exec_env, .module_inst = inst };
        }
        if (c.wasm_runtime_lookup_function(inst, "on_update")) |f| {
            self.fn_update = .{ .raw = f, .exec_env = exec_env, .module_inst = inst };
        }
        if (c.wasm_runtime_lookup_function(inst, "get_shared_buffer_ptr")) |f| {
            self.fn_get_shared_buf = .{ .raw = f, .exec_env = exec_env, .module_inst = inst };
        }

        if (self.fn_get_shared_buf) |f| {
            if (f.call0RetU32()) |offset| {
                self.guest_buffer_offset = offset;
                self.context.guest_buffer_offset = offset;

                // Bind EngineContext.host_state and guest_state directly into WASM's shared_memory_buffer!
                if (wamr.getGuestMemorySliceMut(inst, offset, @sizeOf(GameState))) |slice| {
                    const wasm_state: *GameState = @ptrCast(@alignCast(slice.ptr));
                    if (self.context.host_state) |prev| {
                        if (prev != wasm_state) {
                            wasm_state.* = prev.*;
                        }
                    } else {
                        wasm_state.* = GameState.initDefault();
                    }
                    self.context.host_state = wasm_state;
                    self.context.guest_state = wasm_state;
                }
            } else |_| {}
        }
    }

    pub fn loadScriptFile(self: *ScriptHost, allocator: std.mem.Allocator, file_path: []const u8) !void {
        const libc = @cImport({
            @cInclude("stdio.h");
        });

        const path_z = try allocator.dupeZ(u8, file_path);
        defer allocator.free(path_z);

        const file = libc.fopen(path_z.ptr, "rb") orelse return error.FileNotFound;
        defer _ = libc.fclose(file);

        _ = libc.fseek(file, 0, libc.SEEK_END);
        const file_len = libc.ftell(file);
        if (file_len < 0) return error.FileReadFailed;
        const size: usize = @intCast(file_len);
        _ = libc.fseek(file, 0, libc.SEEK_SET);

        const bytes = try allocator.alloc(u8, size);
        errdefer allocator.free(bytes);

        const read_count = libc.fread(bytes.ptr, 1, size, file);
        if (read_count != size) return error.FileReadFailed;

        self.owned_bytes = bytes;
        self.allocator = allocator;

        try self.loadScriptBytes(bytes);
    }

    /// Re-bind EngineContext.host_state to WASM's in-place shared_memory_buffer
    /// (zero @memcpy; guarantees pointer validity if WASM linear memory grew).
    pub fn syncSharedStateToGuest(self: *ScriptHost) void {
        _ = self.context.refreshSharedState(self.module_inst);
    }

    pub fn callInit(self: *ScriptHost) wamr.WasmError!void {
        self.context.preTickPrepare(self.module_inst, 0.0);
        if (self.fn_init) |f| {
            try f.call0();
        }
        // Post-init host reconciliation in-place on WASM shared_memory_buffer
        _ = self.context.refreshSharedState(self.module_inst);
        self.context.postTickReconcile(0.0);
    }

    pub fn callUpdate(self: *ScriptHost, dt: f32) wamr.WasmError!void {
        // 1. Pre-tick: Update in-place shared GameState header time & delta_time
        self.context.preTickPrepare(self.module_inst, dt);

        // 2. Guest execution: Direct zero-overhead reads AND in-place writes on shared_memory_buffer
        if (self.fn_update) |f| {
            try f.call1F32(dt);
        }

        // 3. Post-tick reconciliation: Step velocities, resolve hierarchy, and sync ECS/Physics in-place
        _ = self.context.refreshSharedState(self.module_inst);
        self.context.postTickReconcile(dt);
    }
};

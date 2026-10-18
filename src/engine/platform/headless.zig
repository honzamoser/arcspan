//! Headless Platform & Dedicated Server Simulation Runner
//! Executes high-performance 3D game simulation ticks without windowing,
//! graphics device, swapchain, or GPU rendering dependencies.

const std = @import("std");
const Scene = @import("../renderer/scene.zig").Scene;
const Camera = @import("../camera/camera.zig").Camera;
const PhysicsWorld = @import("../physics/jolt.zig").PhysicsWorld;
const EcsWorld = @import("../ecs/ecs.zig").EcsWorld;
const scripting = @import("../scripting/engine_api.zig");
const EngineContext = scripting.EngineContext;
const ScriptHost = @import("../scripting/script_host.zig").ScriptHost;
const GameState = @import("../state/game_state.zig").GameState;

pub const ServerConfig = struct {
    tick_rate_hz: u32 = 60,
    port: u16 = 7777,
    max_clients: u32 = 32,
    enable_physics: bool = true,
    enable_ecs: bool = true,
};

pub const HeadlessServer = struct {
    allocator: std.mem.Allocator,
    config: ServerConfig,
    scene: Scene,
    camera: Camera,
    physics: ?PhysicsWorld = null,
    ecs: ?EcsWorld = null,
    game_state: GameState,
    shared_ecs: @import("../state/game_state.zig").SharedEcsWorld,
    script_context: EngineContext,
    script_host: ?ScriptHost = null,

    is_running: bool = false,
    total_time: f32 = 0.0,
    tick_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) !*HeadlessServer {
        const self = try allocator.create(HeadlessServer);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.config = config;
        self.scene = Scene.initDefault();
        self.camera = Camera.initDefault();
        self.game_state = GameState.initDefault();
        self.shared_ecs = .{};
        self.is_running = false;
        self.total_time = 0.0;
        self.tick_count = 0;
        self.script_host = null;

        if (config.enable_physics) {
            self.physics = PhysicsWorld.init() catch |err| blk: {
                std.debug.print("[HEADLESS SERVER] Warning: Failed to init Jolt Physics: {}\n", .{err});
                break :blk null;
            };
        } else {
            self.physics = null;
        }

        if (config.enable_ecs) {
            self.ecs = EcsWorld.init() catch |err| blk: {
                std.debug.print("[HEADLESS SERVER] Warning: Failed to init Flecs ECS: {}\n", .{err});
                break :blk null;
            };
        } else {
            self.ecs = null;
        }
        if (self.ecs) |*e| e.bindSharedWorld(&self.shared_ecs);

        self.script_context = EngineContext{
            .scene = &self.scene,
            .camera = &self.camera,
            .input = null,
            .physics = if (self.physics) |*p| p else null,
            .audio = null,
            .ui = null,
            .window = null,
            .ecs = if (self.ecs) |*e| e else null,
            .particles = null,
            .host_state = &self.game_state,
        };
        if (self.ecs) |*e| e.setSystemContext(&self.script_context);

        return self;
    }

    pub fn deinit(self: *HeadlessServer) void {
        if (self.script_host) |*host| {
            host.deinit();
            self.script_host = null;
        }
        if (self.ecs) |*e| {
            e.deinit();
        }
        if (self.physics) |*p| {
            p.deinit();
        }
        self.allocator.destroy(self);
    }

    pub fn loadScriptBytes(self: *HeadlessServer, bytes: []const u8) !void {
        var host = try ScriptHost.init(&self.script_context, 64 * 1024);
        errdefer host.deinit();

        try host.loadScriptBytes(bytes);
        try host.callInit();

        self.script_host = host;
        std.debug.print("[HEADLESS SERVER] WebAssembly script loaded successfully ({s})\n", .{
            if (host.isAot()) "AOT Native" else "Bytecode",
        });
    }

    pub fn loadScriptFile(self: *HeadlessServer, path: []const u8) !void {
        var host = try ScriptHost.init(&self.script_context, 64 * 1024);
        errdefer host.deinit();

        _ = try host.loadScriptFile(self.allocator, path);
        try host.callInit();

        self.script_host = host;
        std.debug.print("[HEADLESS SERVER] WebAssembly script loaded from '{s}'\n", .{path});
    }

    /// Advance server simulation by one tick `dt`.
    pub fn tick(self: *HeadlessServer, dt: f32) !void {
        self.total_time += dt;
        self.tick_count += 1;
        self.script_context.time = self.total_time;
        self.script_context.delta_time = dt;

        // 1. Step Jolt Physics simulation
        if (self.physics) |*p| {
            p.update(dt);
        }

        // 2. Synchronize Physics -> Flecs ECS
        if (self.ecs) |*e| {
            if (self.physics) |*p| {
                e.syncFromPhysics(p);
            }
            // 3. Step Flecs ECS Subsystem
            _ = e.progress(dt);
        }

        // 4. WebAssembly Script Execution
        if (self.script_host) |*host| {
            try host.callUpdate(dt);
        }

        // 5. Post-tick reconciliation (resolves outbox commands, transforms)
        self.script_context.postTickReconcile(dt);
    }

    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.c) void;
    extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.c) c_int;
    extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.c) c_int;

    pub fn nowNs() u64 {
        if (comptime @import("builtin").os.tag == .windows) {
            var count: i64 = 0;
            var freq: i64 = 0;
            _ = QueryPerformanceCounter(&count);
            _ = QueryPerformanceFrequency(&freq);
            if (freq == 0) return 0;
            const count_128: u128 = @intCast(@max(0, count));
            const freq_128: u128 = @intCast(@max(1, freq));
            return @intCast((count_128 * 1_000_000_000) / freq_128);
        } else {
            var ts: std.posix.timespec = undefined;
            _ = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
            return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
        }
    }

    pub fn sleepMs(ms: u32) void {
        if (comptime @import("builtin").os.tag == .windows) {
            Sleep(ms);
        } else {
            const req = std.posix.timespec{
                .sec = @intCast(ms / 1000),
                .nsec = @intCast((ms % 1000) * 1_000_000),
            };
            _ = std.posix.nanosleep(&req, null);
        }
    }

    /// Run the server loop at fixed tick rate.
    /// If `max_ticks` is provided, exits after that many ticks.
    pub fn run(self: *HeadlessServer, max_ticks: ?usize) !void {
        self.is_running = true;
        const tick_interval_ns: u64 = @divFloor(1_000_000_000, self.config.tick_rate_hz);
        const dt: f32 = 1.0 / @as(f32, @floatFromInt(self.config.tick_rate_hz));

        var last_tick_time = nowNs();
        var simulated_ticks: usize = 0;

        std.debug.print("[HEADLESS SERVER] Server running at {d} Hz (dt = {d:.4}s)\n", .{
            self.config.tick_rate_hz,
            dt,
        });

        while (self.is_running) {
            if (max_ticks) |limit| {
                if (simulated_ticks >= limit) break;
            }

            try self.tick(dt);
            simulated_ticks += 1;

            const now = nowNs();
            const elapsed_ns: u64 = if (now >= last_tick_time) now - last_tick_time else 0;
            last_tick_time = now;

            if (elapsed_ns < tick_interval_ns) {
                const sleep_ns = tick_interval_ns - elapsed_ns;
                const sleep_ms: u32 = @intCast(sleep_ns / 1_000_000);
                if (sleep_ms > 0) {
                    sleepMs(sleep_ms);
                }
            }
        }

        std.debug.print("[HEADLESS SERVER] Stopped gracefully after {d} ticks ({d:.2}s simulation)\n", .{
            self.tick_count,
            self.total_time,
        });
    }

    pub fn stop(self: *HeadlessServer) void {
        self.is_running = false;
    }
};

const std = @import("std");
const engine = @import("engine");

const HeadlessServer = engine.platform.HeadlessServer;
const ServerConfig = engine.platform.ServerConfig;

pub fn main(init: std.process.Init) !void {
    std.debug.print("====================================================================\n", .{});
    std.debug.print("  Zig 0.16+ Game Engine Runtime: Headless Dedicated Server Mode     \n", .{});
    std.debug.print("  Jolt Physics | Zig ECS | WebAssembly UGC Scripting | UDP Net      \n", .{});
    std.debug.print("====================================================================\n", .{});

    const allocator = init.gpa;

    var config = ServerConfig{};
    var max_ticks: ?usize = null;

    // Parse command line arguments
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();

    _ = args.next(); // Skip executable path
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            if (args.next()) |val| {
                config.port = try std.fmt.parseInt(u16, val, 10);
            }
        } else if (std.mem.eql(u8, arg, "--tick-rate")) {
            if (args.next()) |val| {
                config.tick_rate_hz = try std.fmt.parseInt(u32, val, 10);
            }
        } else if (std.mem.eql(u8, arg, "--ticks")) {
            if (args.next()) |val| {
                max_ticks = try std.fmt.parseInt(usize, val, 10);
            }
        } else if (std.mem.eql(u8, arg, "--no-physics")) {
            config.enable_physics = false;
        } else if (std.mem.eql(u8, arg, "--no-ecs")) {
            config.enable_ecs = false;
        }
    }

    std.debug.print("[HEADLESS SERVER] Initializing server on port {d}...\n", .{config.port});
    var server = try HeadlessServer.init(allocator, config);
    defer server.deinit();

    // Load server-side gameplay script
    const disk_paths = [_][]const u8{
        "zig-out/scripts/scene_controller.aot",
        "scripts/scene_controller.aot",
        "zig-out/scripts/scene_controller.wasm",
        "scripts/scene_controller.wasm",
    };
    var loaded = false;
    for (disk_paths) |path| {
        if (server.loadScriptFile(path)) |_| {
            loaded = true;
            break;
        } else |_| {}
    }
    if (!loaded) {
        const embedded_wasm = @embedFile("scene_controller.aot");
        server.loadScriptBytes(embedded_wasm) catch |err| {
            std.debug.print("[HEADLESS SERVER] Warning: Failed to load embedded script: {}\n", .{err});
        };
    }

    std.debug.print("[HEADLESS SERVER] Starting fixed-step simulation loop...\n", .{});
    try server.run(max_ticks);
    std.debug.print("[HEADLESS SERVER] Server shutdown complete.\n", .{});
}

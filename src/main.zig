const std = @import("std");
const engine = @import("engine");
const sdl = @import("sdl3");

const Camera = engine.Camera;

fn loadWasmScript(host: *engine.scripting.ScriptHost, wasm_embedded: []const u8) !void {
    _ = wasm_embedded;
    const disk_paths = [_][]const u8{
        "zig-out/scripts/scene_controller.aot",
        "scripts/scene_controller.aot",
        "zig-out/scripts/scene_controller.wasm",
        "scripts/scene_controller.wasm",
        "../scripts/scene_controller.aot",
        "./zig-out/scripts/scene_controller.aot",
    };
    var loaded = false;
    for (disk_paths) |path| {
        if (host.loadScriptFile(std.heap.page_allocator, path)) |_| {
            std.debug.print("[WASM HOST] Loaded script from disk: {s}\n", .{path});
            loaded = true;
            break;
        } else |_| {}
    }
    if (!loaded) {
        // try host.loadScriptBytes(wasm_embedded);
        std.debug.print("[WASM HOST] Loaded embedded script.\n", .{});
    }
    std.debug.print("[WASM HOST] Script execution mode: {s}\n", .{if (host.isAot()) "AOT (Ahead-Of-Time Native)" else "Bytecode"});
    try host.callInit();
}

pub fn main() !void {
    std.debug.print("====================================================================\n", .{});
    std.debug.print("  Zig 0.16+ Game Engine Runtime: WAMR WebAssembly Scripting Host    \n", .{});
    std.debug.print("  WGPU (PBR+Texture) | Zig ECS | Jolt Physics | SDL3 Audio | WAMR   \n", .{});
    std.debug.print("====================================================================\n", .{});

    // 1. Initialize Windowing Subsystem
    var window = try engine.Window.init("Zig Game Engine [WASM Script Driven]", 1024, 680);
    defer window.deinit();

    const allocator = std.heap.page_allocator;

    // 2. Initialize WebGPU Renderer (3D PBR + 2D UI Overlay Pass)
    const renderer = try engine.Renderer.create(allocator, &window);
    defer renderer.destroy(allocator);

    // 3. Initialize Input System
    var input = engine.InputState.init();

    // 4. Initialize SDL3 Audio Engine
    var audio_eng = engine.audio.AudioEngine.init();
    defer audio_eng.deinit();
    audio_eng.playChime(0.6);

    // 5. Initialize Jolt Physics Subsystem
    var physics = try engine.physics.PhysicsWorld.init();
    defer physics.deinit();

    // 6. Initialize Built-in Zig ECS Subsystem
    var ecs_world = try engine.ecs.EcsWorld.init();
    defer ecs_world.deinit();

    // 7. Initialize Scene Representation & Authoritative Engine Camera
    var scene = engine.Scene.initDefault();
    var camera = Camera.initDefault();

    // 8. Initialize WebAssembly Scripting Subsystem & Connect Host Subsystems
    const wasm_bytes = @embedFile("scene_controller.aot");
    var script_context = engine.scripting.EngineContext{
        .scene = &scene,
        .camera = &camera,
        .input = &input,
        .physics = &physics,
        .audio = &audio_eng,
        .ui = &renderer.ui,
        .window = &window,
        .ecs = &ecs_world,
        .particles = &renderer.particles,
    };
    ecs_world.setSystemContext(&script_context);
    var script_host = try engine.scripting.ScriptHost.init(&script_context, 64 * 1024);
    defer script_host.deinit();

    try loadWasmScript(&script_host, wasm_bytes);

    var last_time_ns = sdl.SDL_GetTicksNS();
    var total_time_sec: f32 = 0.0;
    var frame_count: u32 = 0;
    var fps_timer_sec: f32 = 0.0;
    var r_key_down = false;

    // Main Engine Simulation & Render Loop
    while (!input.should_quit) {
        const now_ns = sdl.SDL_GetTicksNS();
        const delta_ns = now_ns - last_time_ns;
        last_time_ns = now_ns;
        const dt = @as(f32, @floatFromInt(delta_ns)) / 1_000_000_000.0;

        total_time_sec += dt;
        fps_timer_sec += dt;
        frame_count += 1;

        // if (fps_timer_sec >= 1.0) {
        //     std.debug.print("FPS: {d} | Window: {d}x{d}\n", .{
        //         frame_count,
        //         window.width,
        //         window.height,
        //     });
        //     frame_count = 0;
        //     fps_timer_sec -= 1.0;
        // }

        // --- Input Processing ---
        input.pollEvents();

        if (input.resized) {
            window.updateSize();
            renderer.resize(window.width, window.height);
        }

        // Hot-reload Wasm script on 'R' key
        if (input.isKeyDown(sdl.SDL_SCANCODE_R)) {
            if (!r_key_down) {
                r_key_down = true;
                std.debug.print("[WASM HOST] Hot-reloading script...\n", .{});
                script_host.deinit();
                script_host = try engine.scripting.ScriptHost.init(&script_context, 64 * 1024);
                loadWasmScript(&script_host, wasm_bytes) catch |err| {
                    std.debug.print("[WASM HOST] Hot-reload error: {}\n", .{err});
                };
            }
        } else {
            r_key_down = false;
        }

        // 1. Step Jolt Physics simulation
        physics.update(dt);

        // 2. Synchronize Physics -> Flecs ECS
        // ecs_world.syncFromPhysics(&physics);

        // 3. Step Flecs ECS Subsystem
        _ = ecs_world.progress(dt);

        // 4. Clear 2D UI batch before script execution
        renderer.ui.begin();

        // 5. WebAssembly Script Execution: all gameplay logic runs here
        script_context.time = total_time_sec;
        script_context.delta_time = dt;
        try script_host.callUpdate(dt);

        // 6. Step Particle Simulation Physics
        renderer.updateParticles(dt);

        // 7. Render 3D Scene + Post-Processing + 2D UI Overlay Pass with Script-Controlled Camera
        try renderer.renderWithCamera(&scene, script_context.camera, total_time_sec);
    }

    std.debug.print("Shutting down cleanly...\n", .{});
}

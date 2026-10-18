const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Dependencies
    const wgpu_native_dep = b.dependency("wgpu_native_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const wgpu_mod = wgpu_native_dep.module("wgpu");

    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .sanitize_c = .off,
    });
    const sdl_lib = sdl_dep.artifact("SDL3");

    // 2. High-Performance WebAssembly Micro Runtime (WAMR with AOT & Classic Interpreter)
    const wamr_include = b.path("external/wamr/core/iwasm/include");
    const wamr_platform_include = b.path("external/wamr/core/shared/platform/include");
    const wamr_lib_path = b.path("external/wamr/lib");
    const wamr_build_dir = "external/wamr/build_upstream";
    const wamrc_build_dir = "external/wamr/wamr-compiler/build";

    // WAMR runtime library setup. The CMake target is named `vmlib`, but its
    // installed output is named `iwasm` and is placed under external/wamr/lib.
    const configure_wamr = b.addSystemCommand(&.{
        "cmake",
        "-S", "external/wamr",
        "-B", wamr_build_dir,
        "-G", "Visual Studio 17 2022",
        "-A", "x64",
        "-DWAMR_BUILD_PLATFORM=windows",
        "-DWAMR_BUILD_TARGET=X86_64",
        "-DWAMR_BUILD_INTERP=1",
        "-DWAMR_BUILD_FAST_INTERP=0",
        "-DWAMR_BUILD_AOT=1",
        "-DWAMR_BUILD_LIBC_BUILTIN=1",
        "-DWAMR_BUILD_LIBC_WASI=0",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW",
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
    });
    const build_wamr = b.addSystemCommand(&.{
        "cmake",
        "--build", wamr_build_dir,
        "--config", "Release",
        "--target", "vmlib",
    });
    build_wamr.step.dependOn(&configure_wamr.step);
    const install_wamr = b.addSystemCommand(&.{
        "cmake",
        "--install", wamr_build_dir,
        "--config", "Release",
        "--prefix", "external/wamr",
    });
    install_wamr.step.dependOn(&build_wamr.step);

    const setup_wamr = b.step(
        "setup-wamr",
        "Configure, build, and install the WAMR runtime library",
    );
    setup_wamr.dependOn(&install_wamr.step);

    // WAMR AOT compiler setup. This is intentionally a separate explicit
    // step because building LLVM is substantially more expensive than a
    // normal engine build.
    const build_wamr_llvm = b.addSystemCommand(&.{
        "python",
        "external/wamr/wamr-compiler/build_llvm.py",
    });
    const configure_wamrc = b.addSystemCommand(&.{
        "cmake",
        "-S", "external/wamr/wamr-compiler",
        "-B", wamrc_build_dir,
        "-G", "Visual Studio 17 2022",
        "-A", "x64",
    });
    configure_wamrc.step.dependOn(&build_wamr_llvm.step);
    const build_wamrc = b.addSystemCommand(&.{
        "cmake",
        "--build", wamrc_build_dir,
        "--config", "Release",
        "--target", "wamrc",
    });
    build_wamrc.step.dependOn(&configure_wamrc.step);
    const install_wamrc = b.addSystemCommand(&.{
        "cmake",
        "--install", wamrc_build_dir,
        "--config", "Release",
        "--prefix", "external/wamr",
    });
    install_wamrc.step.dependOn(&build_wamrc.step);

    const setup_wamrc = b.step(
        "setup-wamrc",
        "Build LLVM, compile the WAMR AOT compiler, and install wamrc",
    );
    setup_wamrc.dependOn(&install_wamrc.step);

    // 2.b Built-in Pure Zig Entity Component System (src/engine/ecs/ecs.zig)

    // 3. User Script Compilation Target (Zig -> wasm32-freestanding -> WAMR AOT)
    const script_opt = b.option([]const u8, "script", "Path to script file (default: scripts/scene_controller.zig)") orelse "scripts/scene_controller.zig";

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path(script_opt),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const wasm_script = b.addExecutable(.{
        .name = "scene_controller",
        .root_module = wasm_mod,
    });
    wasm_script.entry = .disabled;
    wasm_script.rdynamic = true;

    const install_wasm = b.addInstallArtifact(wasm_script, .{
        .dest_dir = .{ .override = .{ .custom = "scripts" } },
    });
    b.getInstallStep().dependOn(&install_wasm.step);

    // WAMR Ahead-of-Time (.aot) compiler invocation
    const run_wamrc = b.addSystemCommand(&.{
        "external/wamr/bin/wamrc.exe",
        "--bounds-checks=1",
        "--stack-bounds-checks=0",
        "--size-level=0",
        "-o",
    });
    const aot_file = run_wamrc.addOutputFileArg("scene_controller.aot");
    run_wamrc.addFileArg(wasm_script.getEmittedBin());

    const install_aot = b.addInstallFile(aot_file, "scripts/scene_controller.aot");
    b.getInstallStep().dependOn(&install_aot.step);

    const aot_step = b.step("aot", "Build AOT-compiled WebAssembly guest scripts (scripts/scene_controller.zig -> zig-out/scripts/scene_controller.aot)");
    aot_step.dependOn(&install_aot.step);

    const wasm_step = b.step("wasm", "Build WebAssembly guest scripts and AOT binary");
    wasm_step.dependOn(&install_wasm.step);
    wasm_step.dependOn(&install_aot.step);

    const scripts_step = b.step("scripts", "Alias for 'aot' / 'wasm' build step");
    scripts_step.dependOn(&install_aot.step);

    // SDL3 generated bindings module
    const sdl3_mod = b.createModule(.{
        .root_source_file = b.path("src/sdl3.zig"),
        .target = target,
        .optimize = optimize,
    });
    sdl3_mod.linkLibrary(sdl_lib);

    // 4. Core Engine Module
    const engine_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine_mod.addImport("sdl3", sdl3_mod);
    engine_mod.addImport("wgpu", wgpu_mod);
    engine_mod.linkLibrary(sdl_lib);
    engine_mod.addIncludePath(wamr_include);
    engine_mod.addIncludePath(wamr_platform_include);
    engine_mod.addLibraryPath(wamr_lib_path);
    engine_mod.linkSystemLibrary("iwasm", .{});
    engine_mod.addIncludePath(b.path("external/jolt/include"));
    engine_mod.addLibraryPath(b.path("external/jolt/lib"));
    engine_mod.linkSystemLibrary("joltc", .{});
    if (target.result.os.tag == .windows) {
        engine_mod.linkSystemLibrary("ws2_32", .{});
    }
    engine_mod.link_libc = true;

    // 5. Root Module for Application / Game Engine
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    app_mod.addImport("engine", engine_mod);
    app_mod.addImport("sdl3", sdl3_mod);
    app_mod.addImport("wgpu", wgpu_mod);
    app_mod.linkLibrary(sdl_lib);
    app_mod.addIncludePath(wamr_include);
    app_mod.addIncludePath(wamr_platform_include);
    app_mod.addLibraryPath(wamr_lib_path);
    app_mod.linkSystemLibrary("iwasm", .{});
    app_mod.addIncludePath(b.path("external/jolt/include"));
    app_mod.addLibraryPath(b.path("external/jolt/lib"));
    app_mod.linkSystemLibrary("joltc", .{});
    if (target.result.os.tag == .windows) {
        app_mod.linkSystemLibrary("ws2_32", .{});
    }
    app_mod.link_libc = true;
    app_mod.addAnonymousImport("scene_controller.aot", .{
        .root_source_file = aot_file,
    });
    app_mod.addAnonymousImport("scene_controller.wasm", .{
        .root_source_file = wasm_script.getEmittedBin(),
    });

    const exe = b.addExecutable(.{
        .name = "wgpu_sdl_renderer",
        .root_module = app_mod,
    });
    exe.stack_size = 16 * 1024 * 1024;

    if (target.result.os.tag == .windows and target.result.abi == .msvc) {
        exe.bundle_compiler_rt = false;
        exe.bundle_ubsan_rt = false;
    }

    b.installArtifact(exe);

    const install_jolt_dll = b.addInstallFile(b.path("external/jolt/bin/joltc.dll"), "bin/joltc.dll");
    b.getInstallStep().dependOn(&install_jolt_dll.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the renderer application");
    run_step.dependOn(&run_cmd.step);

    // 5.b Headless Dedicated Server Executable
    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/server_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_mod.addImport("engine", engine_mod);
    server_mod.addIncludePath(wamr_include);
    server_mod.addIncludePath(wamr_platform_include);
    server_mod.addLibraryPath(wamr_lib_path);
    server_mod.linkSystemLibrary("iwasm", .{});
    server_mod.addIncludePath(b.path("external/jolt/include"));
    server_mod.addLibraryPath(b.path("external/jolt/lib"));
    server_mod.linkSystemLibrary("joltc", .{});
    if (target.result.os.tag == .windows) {
        server_mod.linkSystemLibrary("ws2_32", .{});
    }
    server_mod.link_libc = true;
    server_mod.addAnonymousImport("scene_controller.aot", .{
        .root_source_file = aot_file,
    });
    server_mod.addAnonymousImport("scene_controller.wasm", .{
        .root_source_file = wasm_script.getEmittedBin(),
    });

    const server_exe = b.addExecutable(.{
        .name = "headless_server",
        .root_module = server_mod,
    });
    server_exe.stack_size = 16 * 1024 * 1024;
    if (target.result.os.tag == .windows and target.result.abi == .msvc) {
        server_exe.bundle_compiler_rt = false;
        server_exe.bundle_ubsan_rt = false;
    }

    const install_server = b.addInstallArtifact(server_exe, .{});
    const server_step = b.step("server", "Build the headless dedicated server executable");
    server_step.dependOn(&install_server.step);
    b.getInstallStep().dependOn(&install_server.step);

    const run_server_cmd = b.addRunArtifact(server_exe);
    run_server_cmd.step.dependOn(&install_server.step);
    run_server_cmd.addPathDir(b.pathFromRoot("external/jolt/bin"));
    if (b.args) |args| {
        run_server_cmd.addArgs(args);
    }
    const run_server_step = b.step("run-server", "Run the headless dedicated server");
    run_server_step.dependOn(&run_server_cmd.step);

    // 6. Test Suite (Verifying WebAssembly script interaction with the Scene)
    const test_mod = b.createModule(.{
        .root_source_file = b.path("test/wasm_scene_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const guest_api_mod = b.createModule(.{
        .root_source_file = b.path("scripts/client_engine_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    const rts_mod = b.createModule(.{
        .root_source_file = b.path("scripts/rts_controller.zig"),
        .target = target,
        .optimize = optimize,
    });
    rts_mod.addImport("client_engine_api.zig", guest_api_mod);

    test_mod.addImport("guest_api", guest_api_mod);
    test_mod.addImport("rts_controller", rts_mod);
    test_mod.addImport("engine", engine_mod);
    test_mod.addIncludePath(wamr_include);
    test_mod.addIncludePath(wamr_platform_include);
    test_mod.addLibraryPath(wamr_lib_path);
    test_mod.linkSystemLibrary("iwasm", .{});
    test_mod.addIncludePath(b.path("external/jolt/include"));
    test_mod.addLibraryPath(b.path("external/jolt/lib"));
    test_mod.linkSystemLibrary("joltc", .{});
    if (target.result.os.tag == .windows) {
        test_mod.linkSystemLibrary("ws2_32", .{});
    }
    test_mod.link_libc = true;
    test_mod.addAnonymousImport("scene_controller.aot", .{
        .root_source_file = aot_file,
    });
    test_mod.addAnonymousImport("scene_controller.wasm", .{
        .root_source_file = wasm_script.getEmittedBin(),
    });

    const unit_tests = b.addTest(.{
        .name = "wasm_scene_test",
        .root_module = test_mod,
    });
    if (target.result.os.tag == .windows and target.result.abi == .msvc) {
        unit_tests.bundle_compiler_rt = false;
        unit_tests.bundle_ubsan_rt = false;
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.has_side_effects = true;
    run_unit_tests.addPathDir(b.pathFromRoot("external/jolt/bin"));
    const test_step = b.step("test", "Run WebAssembly engine interaction tests");
    test_step.dependOn(&run_unit_tests.step);
}

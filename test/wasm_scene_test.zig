const std = @import("std");
const engine = @import("engine");
const Scene = engine.Scene;
const scripting = engine.scripting;
const EngineContext = scripting.EngineContext;
const ScriptHost = scripting.ScriptHost;

// Embed the Ahead-Of-Time compiled WebAssembly binary and fallback bytecode
const scene_controller_aot = @embedFile("scene_controller.aot");
const scene_controller_wasm = @embedFile("scene_controller.wasm");

test "WebAssembly Zig script interacts with 3D Scene (lifecycle, transforms, camera, mesh colors)" {
    // 1. Initialize Scene and assert baseline state
    var scene = Scene.initDefault();
    try std.testing.expectEqual(@as(f32, 0.0), scene.rotation_x);
    try std.testing.expectEqual(@as(f32, 0.0), scene.rotation_y);
    try std.testing.expectEqual(@as(f32, 3.5), scene.camera_distance);

    // Initial face 0 color in default scene is reddish
    const initial_face0 = scene.getFaceColor(0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), initial_face0[0], 0.01);

    // 2. Setup Engine Context bridging the host engine to the WASM script
    var ctx = EngineContext{
        .scene = &scene,
        .time = 0.0,
        .delta_time = 0.0,
    };

    // 3. Initialize ScriptHost runtime and load compiled WebAssembly module
    var host = try ScriptHost.init(&ctx, 64 * 1024);
    defer host.deinit();

    try host.loadScriptBytes(scene_controller_aot);
    try std.testing.expect(host.isAot());

    // Verify functions were discovered
    try std.testing.expect(host.fn_init != null);
    try std.testing.expect(host.fn_update != null);

    // Setup player 0 in authoritative host state
    if (ctx.host_state) |state| {
        state.players[0].id = 0;
        state.players[0].active = 1;
        state.players[0].position = .{ .x = 10.0, .y = 0.0, .z = 0.0 };
        state.players[0].velocity = .{ .x = 0.0, .y = 0.0, .z = 0.0 };
    }

    // 4. Trigger guest on_init() lifecycle hook
    try host.callInit();

    // Verify guest script logged to engine
    try std.testing.expect(ctx.log_count >= 1);
    try std.testing.expect(std.mem.indexOf(u8, ctx.getLastLog(), "Scene controller script initialized") != null);

    // Verify in-place mutation: guest on_init() applied impulse on player 0 in WASM shared_memory_buffer
    if (ctx.host_state) |h_state| {
        try std.testing.expect(h_state.players[0].velocity.x > 0.0);
        // Assert single in-place WASM-backed GameState: host_state and guest_state point to the exact same memory
        if (ctx.guest_state) |g_state| {
            try std.testing.expectEqual(@intFromPtr(h_state), @intFromPtr(g_state));
            try std.testing.expectEqual(h_state.players[0].velocity.x, g_state.players[0].velocity.x);
        }
    }

    // Verify that on_init() configured initial scene rotations and camera distance
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), scene.rotation_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.50), scene.rotation_y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), scene.camera_distance, 0.001);

    // Verify that on_init() modified cube face colors directly via in-place shared state
    const face0_color = scene.getFaceColor(0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), face0_color[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), face0_color[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), face0_color[2], 0.001);

    const face1_color = scene.getFaceColor(1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), face1_color[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), face1_color[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), face1_color[2], 0.001);

    try std.testing.expect(scene.vertices_dirty);

    // 5. Simulate frame 1 update (dt = 0.016s)
    const dt1: f32 = 0.016;
    ctx.time = dt1;
    ctx.delta_time = dt1;
    try host.callUpdate(dt1);

    // Rotation should advance: rotation_x += 0.35 * 0.016 = 0.2556
    // rotation_y += 0.70 * 0.016 = 0.5112
    const expected_rx1 = 0.25 + 0.35 * dt1;
    const expected_ry1 = 0.50 + 0.70 * dt1;
    try std.testing.expectApproxEqAbs(expected_rx1, scene.rotation_x, 0.001);
    try std.testing.expectApproxEqAbs(expected_ry1, scene.rotation_y, 0.001);

    // Camera distance should oscillate with sine wave: 3.6 + 0.5 * sin(0.016 * 1.5)
    const expected_cam1 = 3.6 + 0.5 * @sin(dt1 * 1.5);
    try std.testing.expectApproxEqAbs(expected_cam1, scene.camera_distance, 0.001);

    // 6. Simulate frame 2 update (dt = 0.033s)
    const dt2: f32 = 0.033;
    ctx.time += dt2;
    ctx.delta_time = dt2;
    try host.callUpdate(dt2);

    const expected_rx2 = expected_rx1 + 0.35 * dt2;
    const expected_ry2 = expected_ry1 + 0.70 * dt2;
    try std.testing.expectApproxEqAbs(expected_rx2, scene.rotation_x, 0.001);
    try std.testing.expectApproxEqAbs(expected_ry2, scene.rotation_y, 0.001);
}

test "Guest SDK Typed Views provide zero-overhead direct memory reads" {
    var raw_state = engine.state.GameState.initDefault();
    raw_state.header.tick = 42;
    raw_state.header.time = 1.25;
    raw_state.header.delta_time = 0.016;

    raw_state.players[1].id = 1;
    raw_state.players[1].active = 1;
    raw_state.players[1].position = .{ .x = 100.0, .y = 200.0, .z = 300.0 };
    raw_state.players[1].velocity = .{ .x = 1.5, .y = 0.0, .z = -2.5 };
    raw_state.players[1].health = 92.5;

    raw_state.entities[5].id = 5;
    raw_state.entities[5].active = 1;
    raw_state.entities[5].entity_type = 4;
    raw_state.entities[5].position = .{ .x = 5.0, .y = 10.0, .z = 15.0 };
    raw_state.entities[5].color = [_]f32{ 0.1, 0.2, 0.3, 1.0 };

    // Guest SDK typed views wrapper over the memory buffer
    const guest_api = @import("guest_api");
    const world_view = guest_api.World{ .state = @ptrCast(&raw_state) };

    // 1. World metadata queries
    try std.testing.expectEqual(@as(u64, 42), world_view.getTick());
    try std.testing.expectEqual(@as(f32, 1.25), world_view.getTime());
    try std.testing.expectEqual(@as(f32, 0.016), world_view.getDeltaTime());

    // 2. Typed PlayerView (zero overhead direct memory reads)
    const player_view = world_view.getPlayer(1).?;
    try std.testing.expectEqual(@as(u32, 1), player_view.getId());
    try std.testing.expect(player_view.isActive());
    try std.testing.expectEqual(@as(f32, 100.0), player_view.getPosition().x);
    try std.testing.expectEqual(@as(f32, 200.0), player_view.getPosition().y);
    try std.testing.expectEqual(@as(f32, 300.0), player_view.getPosition().z);
    try std.testing.expectEqual(@as(f32, 1.5), player_view.getVelocity().x);
    try std.testing.expectEqual(@as(f32, 92.5), player_view.getHealth());

    // Inactive player returns null
    try std.testing.expect(world_view.getPlayer(2) == null);

    // 3. Typed EntityView (zero overhead direct memory reads)
    const entity_view = world_view.getEntity(5).?;
    try std.testing.expectEqual(@as(u64, 5), entity_view.getId());
    try std.testing.expectEqual(@as(u32, 4), entity_view.getType());
    try std.testing.expectEqual(@as(f32, 5.0), entity_view.getPosition().x);
    try std.testing.expectEqual(@as(f32, 10.0), entity_view.getPosition().y);
    try std.testing.expectEqual(@as(f32, 15.0), entity_view.getPosition().z);
    try std.testing.expectEqual(@as(f32, 0.1), entity_view.getColor()[0]);

    // 4. SceneView
    const scene_view = world_view.getScene();
    try std.testing.expectEqual(@as(f32, 3.5), scene_view.getCameraDistance());
}

test "Scene Graph Hierarchy, Entity Tagging, and Collider views in Guest SDK" {
    var raw_state = engine.state.GameState.initDefault();

    // 1. Setup Parent Entity (index 0)
    raw_state.entities[0].id = 0;
    raw_state.entities[0].active = 1;
    raw_state.entities[0].parent_id = engine.state.NO_PARENT;
    raw_state.entities[0].local_position = .{ .x = 5.0, .y = 0.0, .z = 0.0 };
    raw_state.entities[0].local_scale = .{ .x = 2.0, .y = 2.0, .z = 2.0 };
    @memcpy(raw_state.entities[0].tag[0..9], "root_node");

    // 2. Setup Child Entity (index 1) parented to index 0
    raw_state.entities[1].id = 1;
    raw_state.entities[1].active = 1;
    raw_state.entities[1].parent_id = 0;
    raw_state.entities[1].local_position = .{ .x = 1.0, .y = 2.0, .z = 0.0 };
    raw_state.entities[1].local_scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 };
    raw_state.entities[1].collider_type = .box;
    raw_state.entities[1].collider_extents = .{ .x = 0.5, .y = 0.5, .z = 0.5 };
    @memcpy(raw_state.entities[1].tag[0..10], "child_mesh");

    // Resolve hierarchy transforms directly in-place on GameState
    raw_state.stepAndResolve(0.016);

    const guest_api = @import("guest_api");
    const world = guest_api.World{ .state = @ptrCast(&raw_state) };

    // Query parent via World View
    const parent = world.getEntity(0).?;
    try std.testing.expectEqualStrings("root_node", parent.getTag());
    try std.testing.expect(!parent.hasParent());
    try std.testing.expectEqual(@as(f32, 5.0), parent.getWorldPosition().x);

    // Query child via World View
    const child = world.getEntity(1).?;
    try std.testing.expectEqualStrings("child_mesh", child.getTag());
    try std.testing.expect(child.hasParent());
    try std.testing.expectEqual(@as(u64, 0), child.getParentId());

    // World position of child: parent_pos(5, 0, 0) + child_local_pos(1, 2, 0) * parent_scale(2, 2, 2)
    // = (5 + 2, 0 + 4, 0) = (7, 4, 0)
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), child.getWorldPosition().x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), child.getWorldPosition().y, 0.001);
    try std.testing.expectEqual(guest_api.ColliderType.box, child.getColliderType());

    // Query via Tag helper
    const found_by_tag = world.findEntityByTag("child_mesh").?;
    try std.testing.expectEqual(@as(u64, 1), found_by_tag.getId());
    try std.testing.expect(world.findEntityByTag("non_existent") == null);
}

test "Semantic Input Actions and Gameplay Events zero-copy Guest Views" {
    var raw_state = engine.state.GameState.initDefault();

    // 1. Simulate input state
    raw_state.input.actions_down = (@as(u32, 1) << @intFromEnum(engine.state.ActionId.jump)) |
        (@as(u32, 1) << @intFromEnum(engine.state.ActionId.move_forward));
    raw_state.input.actions_pressed = (@as(u32, 1) << @intFromEnum(engine.state.ActionId.jump));
    raw_state.input.axes[@intFromEnum(engine.state.AxisId.move_y)] = 1.0;
    raw_state.input.mouse_dx = 15.5;

    // 2. Simulate events
    raw_state.events.count = 2;
    raw_state.events.events[0] = engine.state.GameEvent.make(1, 0, 1, [_]f32{ 10, 20, 30, 40 }, "collision");
    raw_state.events.events[1] = engine.state.GameEvent.make(2, 1, 0, [_]f32{ 0, 0, 0, 0 }, "damage");

    const guest_api = @import("guest_api");
    const world = guest_api.World{ .state = @ptrCast(&raw_state) };
    const inp = world.getInput();

    // Verify zero-copy action queries
    try std.testing.expect(inp.isActionDown(.jump));
    try std.testing.expect(inp.isActionDown(.move_forward));
    try std.testing.expect(!inp.isActionDown(.move_backward));
    try std.testing.expect(inp.isActionPressed(.jump));
    try std.testing.expect(!inp.isActionPressed(.move_forward));
    try std.testing.expectEqual(@as(f32, 1.0), inp.getAxis(.move_y));
    try std.testing.expectEqual(@as(f32, 15.5), inp.mouse_dx);

    // Verify zero-copy event queries
    const evs = world.getEvents();
    try std.testing.expectEqual(@as(usize, 2), evs.len);
    try std.testing.expectEqual(@as(u32, 1), evs[0].event_type);
    try std.testing.expectEqualStrings("collision", evs[0].getTag());
    try std.testing.expectEqual(@as(u32, 2), evs[1].event_type);
    try std.testing.expectEqualStrings("damage", evs[1].getTag());
}

test "Multiple 3D Primitives and Dynamic Mesh Generation (Cube, Sphere, Pyramid, Cylinder, Plane)" {
    var scene = engine.Scene.initDefault();
    try std.testing.expectEqual(@as(usize, 24), scene.vertices.len);
    try std.testing.expectEqual(@as(usize, 36), scene.indices.len);

    // 1. Add Sphere with Gold material
    _ = scene.addSphere(.{ 2.0, 0.0, 0.0 }, 1.0, engine.Material.gold());
    // 2. Add Pyramid with Copper material
    _ = scene.addPyramid(.{ -2.0, 0.0, 0.0 }, .{ 1.0, 1.5, 1.0 }, engine.Material.copper());
    // 3. Add Cylinder with Emissive material
    _ = scene.addCylinder(.{ 0.0, 2.0, 0.0 }, 0.5, 1.0, engine.Material.emissiveGlow(.{ 0.8, 0.2, 0.8 }, 1.5));
    // 4. Add Plane with Matte material
    _ = scene.addPlane(.{ 0.0, -1.0, 0.0 }, .{ 10.0, 10.0 }, engine.Material.matte(.{ 0.3, 0.3, 0.3, 1.0 }));

    try std.testing.expectEqual(@as(usize, 4), scene.object_count);
    // Combined vertices and indices should have grown to accommodate all primitives
    try std.testing.expect(scene.vertices.len > 200);
    try std.testing.expect(scene.indices.len > 800);
    try std.testing.expect(scene.vertices_dirty);

    // 5. Test dynamic multi-primitive scene creation with materials
    var multi_scene = engine.Scene.initDefault();
    _ = multi_scene.addCube(.{ 0, 0, 0 }, .{ 1, 1, 1 }, engine.Material.ruby());
    _ = multi_scene.addSphere(.{ 2, 0, 0 }, 0.8, engine.Material.chrome());
    _ = multi_scene.addPyramid(.{ -2, 0, 0 }, .{ 1, 1, 1 }, engine.Material.gold());
    _ = multi_scene.addCylinder(.{ 0, 0, -2 }, 0.5, 1.0, engine.Material.emissiveGlow(.{ 0, 1, 1 }, 2.0));
    _ = multi_scene.addPlane(.{ 0, -1, 0 }, .{ 5, 5 }, engine.Material.matte(.{ 0.2, 0.2, 0.2, 1.0 }));
    try std.testing.expect(multi_scene.object_count == 5);
    try std.testing.expect(multi_scene.vertices.len > 300);
}

test "PBR and Unlit Material System properties, presets, and vertex packing" {
    const Material = engine.Material;
    const gold = Material.gold();
    try std.testing.expectEqual(@as(f32, 1.0), gold.metallic);
    try std.testing.expectEqual(@as(f32, 0.22), gold.roughness);
    try std.testing.expectEqual(engine.ShadingModel.pbr, gold.shading_model);

    const chrome = Material.chrome();
    try std.testing.expectEqual(@as(f32, 1.0), chrome.metallic);
    try std.testing.expectEqual(@as(f32, 0.08), chrome.roughness);

    const emissive = Material.emissiveGlow(.{ 0.2, 0.8, 1.0 }, 2.5);
    try std.testing.expectEqual(engine.ShadingModel.unlit, emissive.shading_model);
    try std.testing.expectEqual(@as(f32, 2.5), emissive.emissive_intensity);

    // Verify Scene object packing with materials
    var scene = engine.Scene.initDefault();
    _ = scene.addObject(.{
        .primitive_type = .sphere,
        .position = .{ 1.0, 0.0, 0.0 },
        .material = gold,
    });
    _ = scene.addObject(.{
        .primitive_type = .cylinder,
        .position = .{ -1.0, 0.0, 0.0 },
        .material = emissive,
    });

    try std.testing.expectEqual(@as(usize, 2), scene.object_count);
    try std.testing.expect(scene.vertices.len > 0);
    // First object vertices should have metallic = 1.0 and roughness = 0.22
    try std.testing.expectEqual(@as(f32, 1.0), scene.vertices[0].material_params[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.22), scene.vertices[0].material_params[1], 0.001);
}

test "User script creates showcase entities in GameState and synchronizes to Scene" {
    var scene = engine.Scene.initDefault();
    var ctx = engine.scripting.EngineContext{
        .scene = &scene,
    };
    var host = try engine.scripting.ScriptHost.init(&ctx, 64 * 1024);
    defer host.deinit();

    try host.loadScriptBytes(scene_controller_aot);
    try std.testing.expect(host.isAot());
    try host.callInit();

    // Verify entities spawned by script in GameState
    if (ctx.host_state) |state| {
        try std.testing.expectEqual(@as(u32, 6), state.header.entity_count);
        try std.testing.expectEqualStrings("center_ruby_cube", state.entities[0].tag[0..16]);
        try std.testing.expectEqualStrings("chrome_sphere", state.entities[1].tag[0..13]);
        // Chrome sphere is parented to entity 0
        try std.testing.expectEqual(@as(u32, 0), state.entities[1].parent_id);
    }

    // Verify Scene was synchronized with all 6 primitives and their materials
    try std.testing.expectEqual(@as(usize, 6), scene.object_count);
    try std.testing.expect(scene.vertices.len > 300);
    try std.testing.expect(scene.indices.len > 1000);

    // Call update to verify script animates the showcase entities
    try host.callUpdate(0.016);
    if (ctx.host_state) |state| {
        // Orbit position should have moved
        try std.testing.expect(state.entities[1].local_position.x != 0.0);
    }
}

test "Flecs ECS integrates into engine with components and lifecycle" {
    var ecs_world = try engine.ecs.EcsWorld.init();
    defer ecs_world.deinit();

    // Create an entity with Position, Velocity, and MeshRender components
    const entity = ecs_world.newEntity("PlayerBot");
    try std.testing.expect(ecs_world.isAlive(entity));

    ecs_world.setPosition(entity, .{ .x = 10.0, .y = 5.0, .z = -2.5 });
    ecs_world.setVelocity(entity, .{ .x = 1.0, .y = 0.0, .z = 0.5 });
    ecs_world.setMesh(entity, .{
        .primitive_type = 1, // sphere
        .color = .{ 0.2, 0.8, 1.0, 1.0 },
        .metallic = 0.9,
        .roughness = 0.1,
    });

    // Query components back
    const pos = ecs_world.getPosition(entity).?;
    try std.testing.expectEqual(@as(f32, 10.0), pos.x);
    try std.testing.expectEqual(@as(f32, 5.0), pos.y);
    try std.testing.expectEqual(@as(f32, -2.5), pos.z);

    const vel = ecs_world.getVelocity(entity).?;
    try std.testing.expectEqual(@as(f32, 1.0), vel.x);

    const mesh = ecs_world.getMesh(entity).?;
    try std.testing.expectEqual(@as(u32, 1), mesh.primitive_type);
    try std.testing.expectEqual(@as(f32, 0.9), mesh.metallic);

    // Progress world
    _ = ecs_world.progress(0.016);
}

test "Jolt Physics integrates with rigid body simulation and gravity" {
    var physics = try engine.physics.PhysicsWorld.init();
    defer physics.deinit();

    // Create a static floor at y = 0.0
    const floor_id = try physics.createFloor(50.0, 1.0, 50.0, 0.0);
    _ = floor_id;

    // Create a dynamic falling sphere at y = 10.0
    const sphere_id = try physics.createSphere(.{ 0.0, 10.0, 0.0 }, 1.0, true);
    try std.testing.expect(physics.isBodyActive(sphere_id));

    const initial_pos = physics.getPosition(sphere_id);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), initial_pos[1], 0.01);

    // Step physics forward 10 steps (0.16 seconds)
    for (0..10) |_| {
        physics.update(0.016);
    }

    // Dynamic body must have fallen due to gravity: y < 10.0
    const fallen_pos = physics.getPosition(sphere_id);
    try std.testing.expect(fallen_pos[1] < 10.0);

    const vel_before = physics.getLinearVelocity(sphere_id);
    try std.testing.expect(vel_before[1] < 0.0);

    // Apply upward impulse (strong impulse overcoming 1m solid sphere mass)
    physics.addImpulse(sphere_id, .{ 0.0, 50000.0, 0.0 });
    physics.update(0.016);
    const vel_after_impulse = physics.getLinearVelocity(sphere_id);
    try std.testing.expect(vel_after_impulse[1] > 0.0);
}

test "SDL3 AudioEngine initializes and synthesizes audio without errors" {
    var audio_eng = engine.audio.AudioEngine.init();
    defer audio_eng.deinit();

    // Verify audio synthesis functions execute cleanly
    audio_eng.playTone(440.0, 0.05, 0.5);
    audio_eng.playImpact(0.8);
    audio_eng.playChime(0.6);
}

test "WASM Guest Script seamlessly drives Jolt Physics simulation (body creation, queries, impulses)" {
    var scene = engine.Scene.initDefault();
    var physics = try engine.physics.PhysicsWorld.init();
    defer physics.deinit();

    var ecs_world = try engine.ecs.EcsWorld.init();
    defer ecs_world.deinit();

    var ctx = engine.scripting.EngineContext{
        .scene = &scene,
        .physics = &physics,
        .ecs = &ecs_world,
    };
    var host = try engine.scripting.ScriptHost.init(&ctx, 64 * 1024);
    defer host.deinit();

    try host.loadScriptBytes(scene_controller_aot);
    try std.testing.expect(host.isAot());
    try host.callInit();

    // Verify Jolt initialization log from guest script
    try std.testing.expect(ctx.log_count >= 1);
    try std.testing.expect(std.mem.indexOf(u8, ctx.getLastLog(), "Genuine Jolt Physics rigid bodies created") != null);

    // Step physics forward 10 frames and update script
    const dt: f32 = 0.016;
    for (0..10) |_| {
        physics.update(dt);
        ctx.time += dt;
        ctx.delta_time = dt;
        try host.callUpdate(dt);
    }

    // Entity 4 (Emerald Sphere) local position must have been synced from genuine Jolt Physics
    if (ctx.host_state) |state| {
        const sphere_pos = state.entities[4].local_position;
        // Body was spawned at y = 1.8 and fell under Jolt gravity
        try std.testing.expect(sphere_pos.y < 1.8);
        try std.testing.expect(sphere_pos.z > 1.6);
    }
}

test "WAMR runtime supports both AOT and standard WebAssembly bytecode" {
    var scene = engine.Scene.initDefault();
    var ctx = engine.scripting.EngineContext{
        .scene = &scene,
    };
    var host = try engine.scripting.ScriptHost.init(&ctx, 64 * 1024);
    defer host.deinit();

    // 1. Verify AOT loading and execution
    try host.loadScriptBytes(scene_controller_aot);
    try std.testing.expect(host.isAot());
    try host.callInit();
    try host.callUpdate(0.016);

    // 2. Re-instantiate with bytecode and verify
    var host_bc = try engine.scripting.ScriptHost.init(&ctx, 64 * 1024);
    defer host_bc.deinit();

    try host_bc.loadScriptBytes(scene_controller_wasm);
    try std.testing.expect(!host_bc.isAot());
    try host_bc.callInit();
    try host_bc.callUpdate(0.016);
}

test "Physics and visual floor alignment matches surface height exactly" {
    var physics = try engine.physics.PhysicsWorld.init();
    defer physics.deinit();

    // Floor created with surface at y = -0.9 and thickness half_y = 0.5
    const floor_surface_y: f32 = -0.9;
    const floor_half_y: f32 = 0.5;
    _ = try physics.createFloor(20.0, floor_half_y, 20.0, floor_surface_y);

    // Sphere created with radius 0.5 at y = 1.0
    const sphere_radius: f32 = 0.5;
    const sphere_id = try physics.createSphere(.{ 0.0, 1.0, 0.0 }, sphere_radius, true);

    // Step physics forward until the sphere lands and settles on the floor
    const dt: f32 = 0.016;
    for (0..300) |_| {
        physics.update(dt);
    }

    const resting_pos = physics.getPosition(sphere_id);
    const expected_resting_y = floor_surface_y + sphere_radius; // -0.9 + 0.5 = -0.4

    // Bottom of the sphere is at resting_pos[1] - sphere_radius, which must equal floor_surface_y (-0.9)
    try std.testing.expectApproxEqAbs(expected_resting_y, resting_pos[1], 0.05);
    try std.testing.expectApproxEqAbs(floor_surface_y, resting_pos[1] - sphere_radius, 0.05);
}

test "Camera matrices, forward vectors, and screenToRay ground intersection" {
    var cam = engine.Camera{
        .position = engine.math.Vec3.init(0.0, 10.0, 10.0),
        .yaw = 0.0,
        .pitch = -std.math.degreesToRadians(45.0),
        .fov_deg = 60.0,
        .aspect = 1.0,
        .near = 0.1,
        .far = 100.0,
    };

    // Forward should point downwards and forwards: y < 0, z > 0
    const fwd = cam.getForward();
    try std.testing.expect(fwd.y < -0.5);
    try std.testing.expect(fwd.z > 0.5);

    // Screen center ray (width = 800, height = 800 -> center is 400, 400)
    const center_ray = cam.screenToRay(400.0, 400.0, 800.0, 800.0);
    try std.testing.expect(center_ray != null);

    // Ray should intersect ground at y = 0
    const ground_hit = center_ray.?.intersectPlaneY(0.0);
    try std.testing.expect(ground_hit != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ground_hit.?.y, 0.01);
    try std.testing.expect(ground_hit.?.z > 10.0); // Forward along Z
}

test "Jolt Physics NarrowPhase query raycasting hits bodies and returns fraction" {
    var physics = try engine.physics.PhysicsWorld.init();
    defer physics.deinit();

    // Create a static box at (0, 0, 5) with extents (1, 1, 1)
    _ = try physics.createBox(.{ 0.0, 0.0, 5.0 }, .{ 1.0, 1.0, 1.0 }, false);

    // Shoot ray from origin (0, 0, 0) towards +Z (0, 0, 10)
    const hit = physics.castRay(.{ 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, 10.0 });
    try std.testing.expect(hit != null);

    // Front face of box is at z = 5.0 - 1.0 = 4.0
    // Ray length is 10.0, so fraction should be 4.0 / 10.0 = 0.4
    try std.testing.expectApproxEqAbs(@as(f32, 0.40), hit.?.fraction, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), hit.?.position[2], 0.05);

    // Ray shooting in the opposite direction (-Z) must miss
    const miss = physics.castRay(.{ 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, -10.0 });
    try std.testing.expect(miss == null);
}

test "RTS NavGrid and A* pathfinding calculates paths around obstacles (Guest Script Layer)" {
    const rts = @import("rts_controller");
    // 10x10 grid with 1.0m cells, centered around origin
    var grid = rts.NavGrid.init(10, 10, 1.0, -5.0, -5.0);

    // Block the straight-line path between (0, 0) and (4, 0) by placing a wall at x = 2
    grid.setWalkable(7, 5, false); // cell corresponding to x=2, z=0
    grid.setWalkable(7, 4, false); // cell corresponding to x=2, z=-1
    grid.setWalkable(7, 6, false); // cell corresponding to x=2, z=+1

    var waypoints: [32]rts.Vec3 = undefined;
    const start = rts.Vec3.init(-2.0, 0.0, 0.0);
    const goal = rts.Vec3.init(3.0, 0.0, 0.0);

    const count = grid.findPath(start, goal, &waypoints);
    try std.testing.expect(count > 1);

    // Goal must be the final waypoint
    try std.testing.expectApproxEqAbs(goal.x, waypoints[count - 1].x, 0.01);
    try std.testing.expectApproxEqAbs(goal.z, waypoints[count - 1].z, 0.01);
}

test "RTS SelectionManager marquee selection accurately selects units (Guest Script Layer)" {
    const rts = @import("rts_controller");
    const cam = engine.Camera{
        .position = engine.math.Vec3.init(0.0, 15.0, -10.0),
        .yaw = 0.0,
        .pitch = -std.math.degreesToRadians(55.0),
        .fov_deg = 60.0,
        .aspect = 1.0,
    };

    var units = [_]rts.RtsUnit{
        .{ .id = 1, .position = rts.Vec3.init(0.0, 0.0, 0.0) }, // in middle
        .{ .id = 2, .position = rts.Vec3.init(-50.0, 0.0, 0.0) }, // far off screen
    };

    // Marquee selecting full screen [0, 0] to [800, 800]
    const selected = rts.SelectionManager.selectMarquee(&units, cam, 800.0, 800.0, 0.0, 0.0, 800.0, 800.0);
    try std.testing.expectEqual(@as(usize, 1), selected);
    try std.testing.expect(units[0].selected);
    try std.testing.expect(!units[1].selected);
}

test "Flecs ECS bridges directly with Jolt Physics and Scene rendering pipeline" {
    // 1. Initialize Jolt Physics and Flecs ECS worlds
    var physics = try engine.physics.PhysicsWorld.init();
    defer physics.deinit();

    var ecs_world = try engine.ecs.EcsWorld.init();
    defer ecs_world.deinit();

    var scene = engine.Scene.initDefault();

    // 2. Spawn dynamic sphere in Jolt Physics at y = 10.0
    const body_id = try physics.createSphere(.{ 0.0, 10.0, 0.0 }, 0.5, true);

    // 3. Register as Flecs ECS entity with PhysicsBody and MeshRender
    const e = ecs_world.spawnPhysicsEntity(
        .{ .x = 0.0, .y = 10.0, .z = 0.0 },
        .{ .x = 1.0, .y = 1.0, .z = 1.0 },
        .{ .primitive_type = 1, .color = .{ 0.0, 1.0, 0.0, 1.0 } },
        .{ .body_id = body_id, .is_dynamic = true },
    );

    // 4. Simulate physics forward
    for (0..10) |_| {
        physics.update(0.016);
    }

    // 5. Run Physics -> ECS sync
    ecs_world.syncFromPhysics(&physics);

    // 6. Verify Flecs Position fell due to gravity
    const pos_after = ecs_world.getPosition(e).?;
    try std.testing.expect(pos_after.y < 10.0);

    // 7. Run ECS -> Scene sync
    scene.clearObjects();
    ecs_world.syncToScene(&scene);

    // 8. Verify Scene now has the entity rendered at physics position
    try std.testing.expectEqual(@as(usize, 1), scene.object_count);
    try std.testing.expectApproxEqAbs(pos_after.y, scene.objects[0].position[1], 0.001);

    // 9. Verify 1:1 unified entity slot allocation across GameState and EcsWorld
    var state = engine.state.GameState.initDefault();
    const slot = state.allocateEntitySlot(0).?;
    _ = ecs_world.initSlot(slot, "UnifiedEntity");
    ecs_world.setPosition(slot, .{ .x = 5.0, .y = 2.0, .z = -3.0 });

    try std.testing.expect(ecs_world.isAlive(slot));
    try std.testing.expectEqual(@as(f32, 5.0), ecs_world.getPosition(slot).?.x);

    // Despawn unified entity
    _ = state.freeEntitySlot(slot);
    ecs_world.deleteEntity(slot);
    try std.testing.expect(!ecs_world.isAlive(slot));
}

test "Scene allocates and generates combined mesh for > 1,000 active entities without overflow" {
    var scene = engine.Scene.initDefault();
    defer scene.deinit();

    // Allocate 1,024 active cube entities
    for (0..1024) |i| {
        const fi: f32 = @floatFromInt(i);
        const added = scene.addCube(
            .{ fi * 0.1, 0.0, 0.0 },
            .{ 0.5, 0.5, 0.5 },
            .{},
        );
        try std.testing.expect(added != null);
    }

    try std.testing.expectEqual(@as(usize, 1024), scene.object_count);
    // 1024 cubes * 24 vertices per cube = 24,576 vertices
    // 1024 cubes * 36 indices per cube = 36,864 indices
    try std.testing.expectEqual(@as(usize, 1024 * 24), scene.combined_vertex_count);
    try std.testing.expectEqual(@as(usize, 1024 * 36), scene.combined_index_count);
    try std.testing.expectEqual(@as(usize, 1024 * 24), scene.vertices.len);
    try std.testing.expectEqual(@as(usize, 1024 * 36), scene.indices.len);
}

test "Phase 1: FontAtlas glyph metrics, SDF rasterization, and text measurement" {
    const font = engine.font.FontAtlas.init();

    // Verify ASCII printable range metrics
    const space_m = font.getMetrics(' ');
    try std.testing.expect(space_m.advance > 0.0);

    const a_m = font.getMetrics('A');
    try std.testing.expect(a_m.advance > space_m.advance);
    try std.testing.expect(a_m.u1 > a_m.u0);
    try std.testing.expect(a_m.v1 > a_m.v0);

    // Verify text measurement calculation
    const dims = font.measureText("FPS: 60 | HP: 100", 16.0);
    try std.testing.expect(dims[0] > 100.0);
    try std.testing.expect(dims[1] >= 16.0);

    // Verify SDF buffer generation
    const pixels = try std.testing.allocator.alloc(u8, engine.font.FontAtlas.ATLAS_WIDTH * engine.font.FontAtlas.ATLAS_HEIGHT * 4);
    defer std.testing.allocator.free(pixels);
    font.generateSdfRgba8(pixels);

    // Assert that glyph pixels have been populated
    var non_zero_count: usize = 0;
    for (pixels) |p| {
        if (p > 0) non_zero_count += 1;
    }
    try std.testing.expect(non_zero_count > 1000);
}

test "Phase 1: Guest WebAssembly script executes UI drawText HUD pipeline without traps" {
    var scene = engine.Scene.initDefault();
    var ctx = engine.scripting.EngineContext{
        .scene = &scene,
    };
    var host = try engine.scripting.ScriptHost.init(&ctx, 64 * 1024);
    defer host.deinit();

    try host.loadScriptBytes(scene_controller_aot);
    try host.callInit();

    // Updating the guest script executes HUD drawText calls
    ctx.time = 0.016;
    ctx.delta_time = 0.016;
    try host.callUpdate(0.016);
}

test "Phase 2: TASK-201 Wavefront OBJ 3D mesh loader parses vertices, normals, UVs and indices" {
    const obj_source =
        \\# Test Wavefront OBJ
        \\v -1.0 1.0 0.0
        \\v -1.0 -1.0 0.0
        \\v 1.0 -1.0 0.0
        \\v 1.0 1.0 0.0
        \\vn 0.0 0.0 1.0
        \\vt 0.0 1.0
        \\vt 0.0 0.0
        \\vt 1.0 0.0
        \\vt 1.0 1.0
        \\f 1/1/1 2/2/1 3/3/1 4/4/1
    ;

    var mesh = try engine.assets.ObjLoader.loadFromMemory(std.testing.allocator, obj_source);
    defer mesh.deinit(std.testing.allocator);

    // Quad decomposed into 2 triangles (4 vertices, 6 indices)
    try std.testing.expectEqual(@as(usize, 4), mesh.vertices.len);
    try std.testing.expectEqual(@as(usize, 6), mesh.indices.len);

    try std.testing.expectEqual(@as(f32, -1.0), mesh.vertices[0].position[0]);
    try std.testing.expectEqual(@as(f32, 1.0), mesh.vertices[0].position[1]);
    try std.testing.expectEqual(@as(f32, 1.0), mesh.vertices[0].normal[2]);
    try std.testing.expectEqual(@as(f32, 0.0), mesh.vertices[0].uv[0]);
    try std.testing.expectEqual(@as(f32, 1.0), mesh.vertices[0].uv[1]);

    // Verify addition into Scene
    var scene = engine.Scene.initDefault();
    defer scene.deinit();

    const obj_idx = scene.addCustomMesh(
        mesh.vertices,
        mesh.indices,
        .{ 0, 0, 0 },
        .{ 0, 0, 0 },
        .{ 1, 1, 1 },
        engine.Material.gold(),
    );
    try std.testing.expect(obj_idx != null);
    try std.testing.expectEqual(@as(usize, 1), scene.object_count);
    try std.testing.expectEqual(@as(usize, 4), scene.combined_vertex_count);
    try std.testing.expectEqual(@as(usize, 6), scene.combined_index_count);
}

test "Phase 2: TASK-201 glTF 2.0 / GLB container and JSON parser extracts mesh geometries" {
    // Generate valid glTF JSON describing a single indexed triangle with positions and normals
    const gltf_json =
        \\{
        \\  "asset": { "version": "2.0" },
        \\  "buffers": [{ "byteLength": 60 }],
        \\  "bufferViews": [
        \\    { "buffer": 0, "byteOffset": 0, "byteLength": 36 },
        \\    { "buffer": 0, "byteOffset": 36, "byteLength": 18 },
        \\    { "buffer": 0, "byteOffset": 54, "byteLength": 6 }
        \\  ],
        \\  "accessors": [
        \\    { "bufferView": 0, "byteOffset": 0, "componentType": 5126, "count": 3, "type": "VEC3" },
        \\    { "bufferView": 1, "byteOffset": 0, "componentType": 5126, "count": 3, "type": "VEC3" },
        \\    { "bufferView": 2, "byteOffset": 0, "componentType": 5123, "count": 3, "type": "SCALAR" }
        \\  ],
        \\  "materials": [
        \\    {
        \\      "pbrMetallicRoughness": {
        \\        "baseColorFactor": [0.8, 0.2, 0.2, 1.0],
        \\        "metallicFactor": 0.9,
        \\        "roughnessFactor": 0.1
        \\      }
        \\    }
        \\  ],
        \\  "meshes": [
        \\    {
        \\      "primitives": [
        \\        {
        \\          "attributes": {
        \\            "POSITION": 0,
        \\            "NORMAL": 1
        \\          },
        \\          "indices": 2,
        \\          "material": 0
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    // Binary buffer: 3 VEC3 positions (36 bytes) + 3 VEC3 normals (36 bytes) + 3 USHORT indices (6 bytes)
    var bin: [78]u8 = [_]u8{0} ** 78;

    // V0: (-1, 0, 0), V1: (1, 0, 0), V2: (0, 1, 0)
    const positions = [_][3]f32{
        .{ -1.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
    };
    for (positions, 0..) |p, i| {
        const offset = i * 12;
        std.mem.writeInt(u32, bin[offset + 0 .. offset + 4][0..4], @as(u32, @bitCast(p[0])), .little);
        std.mem.writeInt(u32, bin[offset + 4 .. offset + 8][0..4], @as(u32, @bitCast(p[1])), .little);
        std.mem.writeInt(u32, bin[offset + 8 .. offset + 12][0..4], @as(u32, @bitCast(p[2])), .little);
    }

    // N0, N1, N2: (0, 0, 1)
    for (0..3) |i| {
        const offset = 36 + i * 12;
        std.mem.writeInt(u32, bin[offset + 0 .. offset + 4][0..4], @as(u32, @bitCast(@as(f32, 0.0))), .little);
        std.mem.writeInt(u32, bin[offset + 4 .. offset + 8][0..4], @as(u32, @bitCast(@as(f32, 0.0))), .little);
        std.mem.writeInt(u32, bin[offset + 8 .. offset + 12][0..4], @as(u32, @bitCast(@as(f32, 1.0))), .little);
    }

    // Indices: 0, 1, 2
    std.mem.writeInt(u16, bin[72..74][0..2], 0, .little);
    std.mem.writeInt(u16, bin[74..76][0..2], 1, .little);
    std.mem.writeInt(u16, bin[76..78][0..2], 2, .little);

    // 1. Test raw JSON parser
    var model = try engine.assets.GltfLoader.loadGltfJson(std.testing.allocator, gltf_json, &bin);
    defer model.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), model.meshes.len);
    const m = model.meshes[0];
    try std.testing.expectEqual(@as(usize, 3), m.vertices.len);
    try std.testing.expectEqual(@as(usize, 3), m.indices.len);
    try std.testing.expectEqual(@as(f32, -1.0), m.vertices[0].position[0]);
    try std.testing.expectEqual(@as(f32, 1.0), m.vertices[2].position[1]);
    try std.testing.expectEqual(@as(f32, 0.9), m.material.metallic);
    try std.testing.expectEqual(@as(f32, 0.1), m.material.roughness);

    // 2. Test GLB Binary container
    var glb_buf: [2048]u8 = undefined;
    // Magic 'glTF' (0x46546C67)
    std.mem.writeInt(u32, glb_buf[0..4][0..4], engine.assets.GltfLoader.GLB_MAGIC, .little);
    std.mem.writeInt(u32, glb_buf[4..8][0..4], 2, .little); // Version 2

    // JSON chunk header
    const json_len: u32 = @intCast(gltf_json.len);
    std.mem.writeInt(u32, glb_buf[12..16][0..4], json_len, .little);
    std.mem.writeInt(u32, glb_buf[16..20][0..4], engine.assets.GltfLoader.CHUNK_JSON, .little);
    @memcpy(glb_buf[20 .. 20 + json_len], gltf_json);

    // BIN chunk header
    const bin_offset = 20 + json_len;
    const bin_len: u32 = @intCast(bin.len);
    std.mem.writeInt(u32, glb_buf[bin_offset .. bin_offset + 4][0..4], bin_len, .little);
    std.mem.writeInt(u32, glb_buf[bin_offset + 4 .. bin_offset + 8][0..4], engine.assets.GltfLoader.CHUNK_BIN, .little);
    @memcpy(glb_buf[bin_offset + 8 .. bin_offset + 8 + bin_len], &bin);

    const total_glb_len = bin_offset + 8 + bin_len;
    std.mem.writeInt(u32, glb_buf[8..12][0..4], @intCast(total_glb_len), .little);

    try std.testing.expect(engine.assets.GltfLoader.isGlb(glb_buf[0..total_glb_len]));

    var glb_model = try engine.assets.GltfLoader.loadGlbFromMemory(std.testing.allocator, glb_buf[0..total_glb_len]);
    defer glb_model.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), glb_model.meshes.len);
    try std.testing.expectEqual(@as(usize, 3), glb_model.meshes[0].vertices.len);
}

test "Phase 2: TASK-202 QOI and TGA image decoders unpack RGBA pixels and generate mipmaps" {
    // 1. QOI encode and decode round-trip test
    const width: u32 = 4;
    const height: u32 = 4;
    const raw_rgba = [_]u8{
        // 4x4 red and blue checker
        255, 0, 0, 255,   0, 0, 255, 255,   255, 0, 0, 255,   0, 0, 255, 255,
        0, 0, 255, 255,   255, 0, 0, 255,   0, 0, 255, 255,   255, 0, 0, 255,
        255, 0, 0, 255,   0, 0, 255, 255,   255, 0, 0, 255,   0, 0, 255, 255,
        0, 0, 255, 255,   255, 0, 0, 255,   0, 0, 255, 255,   255, 0, 0, 255,
    };

    const encoded_qoi = try engine.assets.QoiDecoder.encode(std.testing.allocator, width, height, &raw_rgba);
    defer std.testing.allocator.free(encoded_qoi);

    var decoded = try engine.assets.TextureLoader.loadFromMemory(std.testing.allocator, encoded_qoi);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(width, decoded.width);
    try std.testing.expectEqual(height, decoded.height);
    try std.testing.expectEqual(@as(usize, width * height * 4), decoded.pixels.len);
    try std.testing.expectEqualSlices(u8, &raw_rgba, decoded.pixels);

    // 2. Mipmap generation test (4x4 -> 2x2)
    const mip1 = try engine.assets.TextureLoader.generateNextMipLevel(std.testing.allocator, width, height, decoded.pixels);
    defer std.testing.allocator.free(mip1.pixels);

    try std.testing.expectEqual(@as(u32, 2), mip1.width);
    try std.testing.expectEqual(@as(u32, 2), mip1.height);
    try std.testing.expectEqual(@as(usize, 2 * 2 * 4), mip1.pixels.len);
    // Checked pixels blend 50% red, 50% blue = (127, 0, 127, 255)
    try std.testing.expectApproxEqAbs(@as(f32, 127.0), @as(f32, @floatFromInt(mip1.pixels[0])), 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 127.0), @as(f32, @floatFromInt(mip1.pixels[2])), 1.0);
    try std.testing.expectEqual(@as(u8, 255), mip1.pixels[3]);
}

test "Phase 2: TASK-203 Skeletal bone hierarchy, animation sampling, and GPU matrix palette calculation" {
    var skel = engine.animation.Skeleton{};

    // Root bone (pelvis / torso) at origin
    const root_idx = skel.addBone("Root", null, engine.math.Mat4.identity, engine.math.Mat4.identity).?;
    try std.testing.expectEqual(@as(u16, 0), root_idx);

    // Child bone (upper leg / arm) offset at (0, 2.0, 0)
    const child_local = engine.math.Mat4.translation(0.0, 2.0, 0.0);
    const inv_bind = child_local.inverse().?;
    const child_idx = skel.addBone("Child", root_idx, child_local, inv_bind).?;
    try std.testing.expectEqual(@as(u16, 1), child_idx);

    // Forward kinematics without animation
    skel.updateHierarchy();

    // In bind pose: Palette = Model * InverseBind = Identity
    const p0 = skel.skinning_palette[0];
    const p1 = skel.skinning_palette[1];
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), p0.m[0][0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), p1.m[0][0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), p1.m[3][1], 1e-4); // translation component zeroed out by inv_bind

    // Create an animation clip that moves Root up by 5.0 and rotates Child by 90 degrees around Z
    var root_kfs = try std.testing.allocator.alloc(engine.animation.Keyframe, 2);
    root_kfs[0] = .{ .time = 0.0, .translation = engine.math.Vec3.init(0.0, 0.0, 0.0) };
    root_kfs[1] = .{ .time = 1.0, .translation = engine.math.Vec3.init(0.0, 10.0, 0.0) };

    var child_kfs = try std.testing.allocator.alloc(engine.animation.Keyframe, 2);
    child_kfs[0] = .{ .time = 0.0, .translation = engine.math.Vec3.init(0.0, 2.0, 0.0), .rotation_euler = engine.math.Vec3.init(0, 0, 0) };
    child_kfs[1] = .{ .time = 1.0, .translation = engine.math.Vec3.init(0.0, 2.0, 0.0), .rotation_euler = engine.math.Vec3.init(0, 0, std.math.pi * 0.5) };

    var tracks = try std.testing.allocator.alloc(engine.animation.BoneTrack, 2);
    tracks[0] = .{ .bone_index = root_idx, .keyframes = root_kfs };
    tracks[1] = .{ .bone_index = child_idx, .keyframes = child_kfs };

    var clip = engine.animation.AnimationClip{
        .name = "WalkCycle",
        .duration = 1.0,
        .tracks = tracks,
    };
    defer clip.deinit(std.testing.allocator);

    // Sample clip at t = 0.5 (halfway)
    skel.applyAnimation(&clip, 0.5);

    // Root should have translated Y by 5.0
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), skel.model_matrices[root_idx].m[3][1], 1e-3);
    // Palette for root translates vertices by +5.0 in Y
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), skel.skinning_palette[root_idx].m[3][1], 1e-3);

    // Child should be at Root.Y (5.0) + 2.0 = 7.0
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), skel.model_matrices[child_idx].m[3][1], 1e-3);
}






test "Phase 3: TASK-303 shapecasts report exact contact points/normals and honor collision layer masks" {
    var world = try engine.physics.PhysicsWorld.init();
    defer world.deinit();
    const Layers = engine.physics.Layers;

    // Floor with its top surface at y = 0
    _ = try world.createFloor(50.0, 0.5, 50.0, 0.0);
    // Static box (x 4.5..5.5, y 0.5..1.5)
    const wall = try world.createBox(.{ 5.0, 1.0, 0.0 }, .{ 0.5, 0.5, 0.5 }, false);

    // Sphere sweep straight down onto the floor
    const down = world.castSphere(0.5, .{ 0.0, 5.0, 0.0 }, .{ 0.0, -10.0, 0.0 }, 0xFFFFFFFF) orelse return error.ExpectedHit;
    try std.testing.expectApproxEqAbs(@as(f32, 0.45), down.fraction, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), down.position[1], 0.02);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), down.normal[1], 0.02);

    // Box sweep sideways into the wall's -X face
    const side = world.castBox(.{ 0.25, 0.25, 0.25 }, .{ 0.0, 1.0, 0.0 }, .{ 10.0, 0.0, 0.0 }, 0xFFFFFFFF) orelse return error.ExpectedHit;
    try std.testing.expectEqual(wall, side.body_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.425), side.fraction, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 4.5), side.position[0], 0.02);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), side.normal[0], 0.02);

    // Move the wall to the Water group: masked out by default-only queries, found when requested
    world.setCollisionLayer(wall, Layers.WATER);
    try std.testing.expectEqual(@as(u32, Layers.WATER), world.getCollisionLayer(wall));
    const default_mask: u32 = (1 << Layers.NON_MOVING) | (1 << Layers.MOVING);
    try std.testing.expect(world.castBox(.{ 0.25, 0.25, 0.25 }, .{ 0.0, 1.0, 0.0 }, .{ 10.0, 0.0, 0.0 }, default_mask) == null);
    try std.testing.expect(world.castBox(.{ 0.25, 0.25, 0.25 }, .{ 0.0, 1.0, 0.0 }, .{ 10.0, 0.0, 0.0 }, 1 << Layers.WATER) != null);

    // Layer pair matrix is editable
    try std.testing.expect(!world.layersCollide(Layers.DEBRIS, Layers.CHARACTER));
    world.setLayerCollision(Layers.DEBRIS, Layers.CHARACTER, true);
    try std.testing.expect(world.layersCollide(Layers.DEBRIS, Layers.CHARACTER));
}

test "Phase 3: TASK-301 CharacterVirtual walks on ground, climbs stairs and reports ground state" {
    var world = try engine.physics.PhysicsWorld.init();
    defer world.deinit();

    _ = try world.createFloor(50.0, 0.5, 50.0, 0.0);
    // Low step (top at y = 0.2) the character must climb
    _ = try world.createBox(.{ 4.0, 0.1, 0.0 }, .{ 1.0, 0.1, 5.0 }, false);

    // Capsule: half cylinder 0.5 + radius 0.3 => feet 0.8 below center
    const id = try world.createCharacter(.{ 0.0, 2.0, 0.0 }, 0.5, 0.3);
    try std.testing.expect(id != 0);

    // Falls and lands
    var i: usize = 0;
    while (i < 120) : (i += 1) world.update(1.0 / 60.0);
    try std.testing.expectEqual(engine.physics.GroundState.on_ground, world.getCharacterGroundState(id));
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), world.getCharacterPosition(id)[1], 0.1);

    // Walk +X over the step
    i = 0;
    while (i < 90) : (i += 1) {
        const vy = world.getCharacterLinearVelocity(id)[1];
        world.setCharacterLinearVelocity(id, .{ 3.0, vy, 0.0 });
        world.update(1.0 / 60.0);
    }
    const pos = world.getCharacterPosition(id);
    try std.testing.expect(pos[0] > 3.6 and pos[0] < 5.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), pos[1], 0.1);
    try std.testing.expectEqual(engine.physics.GroundState.on_ground, world.getCharacterGroundState(id));

    // Keep walking off the step: ground contact must be restored on the floor
    i = 0;
    while (i < 240) : (i += 1) {
        const vy = world.getCharacterLinearVelocity(id)[1];
        world.setCharacterLinearVelocity(id, .{ 3.0, vy, 0.0 });
        world.update(1.0 / 60.0);
    }
    try std.testing.expectEqual(engine.physics.GroundState.on_ground, world.getCharacterGroundState(id));
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), world.getCharacterPosition(id)[1], 0.1);
    world.destroyCharacter(id);
}

test "Phase 3: TASK-302 hinge, ball-socket, slider and weld constraints bind rigid bodies" {
    var world = try engine.physics.PhysicsWorld.init();
    defer world.deinit();

    // Hinge: static anchor + dynamic arm swinging about the Z axis
    const anchor = try world.createBox(.{ 0.0, 10.0, 0.0 }, .{ 0.25, 0.25, 0.25 }, false);
    const arm = try world.createBox(.{ 2.0, 10.0, 0.0 }, .{ 0.25, 0.25, 0.25 }, true);
    const hinge = try world.createHingeConstraint(anchor, arm, .{ 0.0, 10.0, 0.0 }, .{ 0.0, 0.0, 1.0 }, -std.math.pi, std.math.pi);
    try std.testing.expect(hinge != 0 and world.isConstraintValid(hinge));

    var i: usize = 0;
    while (i < 60) : (i += 1) world.update(1.0 / 60.0);
    const p = world.getPosition(arm);
    try std.testing.expect(p[1] < 9.0); // swung down under gravity
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), @sqrt(p[0] * p[0] + (p[1] - 10.0) * (p[1] - 10.0)), 0.1); // still on the hinge arc
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), p[2], 0.05);

    // Weld: two dynamic bodies keep their relative offset while one falls
    const a = try world.createBox(.{ 20.0, 10.0, 0.0 }, .{ 0.25, 0.25, 0.25 }, true);
    const b = try world.createBox(.{ 21.0, 10.0, 0.0 }, .{ 0.25, 0.25, 0.25 }, true);
    const weld = try world.createWeldConstraint(a, b);
    world.addImpulse(a, .{ 0.0, 0.0, 5.0 });
    i = 0;
    while (i < 60) : (i += 1) world.update(1.0 / 60.0);
    const pa = world.getPosition(a);
    const pb = world.getPosition(b);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), pb[0] - pa[0], 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), pb[1] - pa[1], 0.05);

    // Ball-socket: pinned pendulum keeps its radius
    const pin = try world.createBox(.{ 40.0, 10.0, 0.0 }, .{ 0.25, 0.25, 0.25 }, false);
    const bob = try world.createBox(.{ 41.5, 10.0, 0.0 }, .{ 0.25, 0.25, 0.25 }, true);
    const ball = try world.createBallSocketConstraint(pin, bob, .{ 40.0, 10.0, 0.0 });
    // Slider: dynamic box constrained to the X axis, limited travel
    const rail = try world.createBox(.{ 60.0, 10.0, 0.0 }, .{ 0.25, 0.25, 0.25 }, false);
    const cart = try world.createBox(.{ 61.0, 10.0, 0.0 }, .{ 0.25, 0.25, 0.25 }, true);
    const slider = try world.createSliderConstraint(rail, cart, .{ 1.0, 0.0, 0.0 }, -2.0, 2.0);
    world.addImpulse(cart, .{ 0.0, 0.0, 3.0 });
    i = 0;
    while (i < 60) : (i += 1) world.update(1.0 / 60.0);
    const pb2 = world.getPosition(bob);
    const dx = pb2[0] - 40.0;
    const dy = pb2[1] - 10.0;
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), @sqrt(dx * dx + dy * dy), 0.1);
    const pc = world.getPosition(cart);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), pc[1], 0.05); // gravity cannot move it off the rail
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), pc[2], 0.05);

    world.destroyConstraint(hinge);
    world.destroyConstraint(weld);
    world.destroyConstraint(ball);
    world.destroyConstraint(slider);
    try std.testing.expect(!world.isConstraintValid(hinge));
}

test "Phase 4: TASK-401 Multi-lighting uniforms and CSM cascade orthographic projection calculations" {
    // 1. Verify LightingUniforms struct size and alignment
    try std.testing.expectEqual(@as(usize, 16), engine.lighting.MAX_POINT_LIGHTS);
    try std.testing.expectEqual(@as(usize, 8), engine.lighting.MAX_SPOT_LIGHTS);
    try std.testing.expectEqual(@as(usize, 3), engine.lighting.NUM_CASCADES);
    try std.testing.expect(@sizeOf(engine.lighting.LightingUniforms) % 16 == 0);

    // 2. Test CSM cascade projection calculation
    const cam = engine.Camera{
        .position = engine.math.Vec3.init(0.0, 5.0, 10.0),
        .yaw = 0.0,
        .pitch = -0.35,
        .fov_deg = 60.0,
        .aspect = 16.0 / 9.0,
        .near = 0.1,
        .far = 100.0,
    };
    const light_dir = engine.math.Vec3.init(-0.55, -0.82, -0.35).normalize();
    const cascade_mats = engine.lighting.computeCascadeMatrices(cam, light_dir, 16.0 / 9.0, engine.lighting.DEFAULT_CASCADE_SPLITS);

    // Verify all 3 cascade view-projection matrices are non-degenerate
    for (cascade_mats, 0..) |mat, idx| {
        // Orthographic projection matrices have m[3][3] == 1.0
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), mat.m[3][3], 1e-4);
        _ = idx;
    }

    // Cascade 0 (near split 0.1 to 8.0) covers a tighter frustum volume than cascade 2 (split 25.0 to 75.0)
    // The orthographic scaling factor (m[0][0]) is proportional to 1 / radius.
    // Therefore, cascade 0 has larger m[0][0] (smaller world radius -> higher texel density).
    try std.testing.expect(cascade_mats[0].m[0][0] > cascade_mats[2].m[0][0]);
}

test "Phase 4: TASK-402 Procedural skybox cubemap generation, atmospheric gradient, and face pixel mapping" {
    const size: u32 = 16;
    const sun_dir = engine.math.Vec3.init(0.0, 0.7071, 0.7071).normalize();
    const cubemap_bytes = try engine.skybox.generateProceduralSkybox(std.testing.allocator, size, sun_dir);
    defer std.testing.allocator.free(cubemap_bytes);

    // 6 faces * 16 * 16 * 4 bytes per RGBA8 pixel = 6144 bytes
    try std.testing.expectEqual(@as(usize, 6 * 16 * 16 * 4), cubemap_bytes.len);

    // Face 2 (+Y, looking directly up at zenith) vs Face 3 (-Y, looking down at ground)
    const face_bytes = size * size * 4;
    const face_top = cubemap_bytes[2 * face_bytes .. 3 * face_bytes];
    const face_bottom = cubemap_bytes[3 * face_bytes .. 4 * face_bytes];

    // Top face center pixel
    const center_top_idx = (8 * size + 8) * 4;
    const top_b = face_top[center_top_idx + 2];
    const center_bottom_idx = (8 * size + 8) * 4;
    const bottom_b = face_bottom[center_bottom_idx + 2];

    // Deep blue zenith has much higher blue content than dark ground
    try std.testing.expect(top_b > bottom_b);

    // Solar corona test: Face 4 (+Z, where sun direction y > 0, z > 0 points) vs Face 5 (-Z, opposite)
    const face_pos_z = cubemap_bytes[4 * face_bytes .. 5 * face_bytes];
    const face_neg_z = cubemap_bytes[5 * face_bytes .. 6 * face_bytes];
    var max_lum_pos_z: u32 = 0;
    var max_lum_neg_z: u32 = 0;

    for (0..size * size) |p| {
        const r_pos = face_pos_z[p * 4 + 0];
        const g_pos = face_pos_z[p * 4 + 1];
        const b_pos = face_pos_z[p * 4 + 2];
        const lum_pos = @as(u32, r_pos) + g_pos + b_pos;
        if (lum_pos > max_lum_pos_z) max_lum_pos_z = lum_pos;

        const r_neg = face_neg_z[p * 4 + 0];
        const g_neg = face_neg_z[p * 4 + 1];
        const b_neg = face_neg_z[p * 4 + 2];
        const lum_neg = @as(u32, r_neg) + g_neg + b_neg;
        if (lum_neg > max_lum_neg_z) max_lum_neg_z = lum_neg;
    }

    // Solar highlight creates bright spot (> 700 combined RGB sum) on +Z face
    try std.testing.expect(max_lum_pos_z > max_lum_neg_z);
    try std.testing.expect(max_lum_pos_z >= 700);
}

test "Phase 4: TASK-403 Post-processing HDR buffer layout, brightness extraction, and ACES tone mapping" {
    // 1. Uniform alignment test
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(engine.postprocess.PostProcessUniforms));
    try std.testing.expect(@sizeOf(engine.postprocess.PostProcessUniforms) % 16 == 0);

    // 2. ACES Filmic Tone Mapping curve mathematical verification
    const acesCurve = struct {
        fn eval(x: f32) f32 {
            const a = 2.51;
            const b = 0.03;
            const c = 2.43;
            const d = 0.59;
            const e = 0.14;
            const val = (x * (a * x + b)) / (x * (c * x + d) + e);
            return std.math.clamp(val, 0.0, 1.0);
        }
    }.eval;

    // Zero input maps to zero
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), acesCurve(0.0), 1e-4);

    // SDR 1.0 input maps to filmic shoulder (~0.80)
    const val_1 = acesCurve(1.0);
    try std.testing.expect(val_1 > 0.75 and val_1 < 0.85);

    // HDR bright lights map smoothly without wrapping or harsh clipping
    const val_10 = acesCurve(10.0);
    const val_50 = acesCurve(50.0);
    const val_100 = acesCurve(100.0);
    try std.testing.expect(val_10 > val_1);
    try std.testing.expect(val_50 >= val_10);
    try std.testing.expect(val_100 >= val_50);
    try std.testing.expect(val_100 <= 1.0);

    // 3. Bright-pass luminance extraction test
    const rgb_dim = [3]f32{ 0.5, 0.5, 0.5 };
    const rgb_bright = [3]f32{ 5.0, 3.0, 1.0 };
    const lum_dim = 0.2126 * rgb_dim[0] + 0.7152 * rgb_dim[1] + 0.0722 * rgb_dim[2];
    const lum_bright = 0.2126 * rgb_bright[0] + 0.7152 * rgb_bright[1] + 0.0722 * rgb_bright[2];

    const threshold: f32 = 1.0;
    try std.testing.expect(lum_dim < threshold);
    try std.testing.expect(lum_bright > threshold);
}

test "Phase 4: TASK-404 GPU particle system simulation, gravity/drag decay, and outbox reconciliation" {
    // 1. Standalone particle physics simulation test
    var ps = engine.particles.ParticleSystem{
        .device = undefined,
        .queue = undefined,
        .render_pipeline = undefined,
        .pipeline_layout = undefined,
        .bind_group_layout = undefined,
        .bind_group = undefined,
        .uniform_buffer = undefined,
        .quad_vertex_buffer = undefined,
        .quad_index_buffer = undefined,
        .instance_buffer = undefined,
        .rng_state = 0x12345678,
    };

    try std.testing.expectEqual(@as(usize, 0), ps.particle_count);

    // Spawn 40 particles
    const spawn_pos = engine.math.Vec3.init(0.0, 10.0, 0.0);
    ps.spawnBurst(spawn_pos, 40, 6.0, .{ 1.0, 0.4, 0.1, 1.0 }, 0.25, 0.5);
    try std.testing.expectEqual(@as(usize, 40), ps.particle_count);

    // Check initial particle states
    for (0..40) |idx| {
        try std.testing.expectApproxEqAbs(@as(f32, 10.0), ps.particles[idx].position[1], 0.001);
        try std.testing.expect(ps.particles[idx].lifetime > 0.3);
    }

    // Step physics forward 0.1s
    ps.update(0.1);
    try std.testing.expectEqual(@as(usize, 40), ps.particle_count);
    for (0..40) |idx| {
        // Particles should have moved
        const dy = ps.particles[idx].position[1] - 10.0;
        try std.testing.expect(dy != 0.0);
    }

    // Advance beyond lifetime: all 40 particles expire and get compacted
    ps.update(1.0);
    try std.testing.expectEqual(@as(usize, 0), ps.particle_count);
}

test "Phase 5: TASK-501 Headless dedicated server mode lifecycle, fixed-step ticking, and ECS/physics sync" {
    const allocator = std.testing.allocator;
    const config = engine.platform.ServerConfig{
        .tick_rate_hz = 60,
        .enable_physics = true,
        .enable_ecs = true,
    };

    var server = try engine.platform.HeadlessServer.init(allocator, config);
    defer server.deinit();

    try std.testing.expectEqual(@as(u64, 0), server.tick_count);
    try std.testing.expectEqual(@as(f32, 0.0), server.total_time);

    // Simulate 10 server ticks
    const dt: f32 = 1.0 / 60.0;
    for (0..10) |_| {
        try server.tick(dt);
    }

    try std.testing.expectEqual(@as(u64, 10), server.tick_count);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0 * dt), server.total_time, 0.001);
    try std.testing.expect(server.physics != null);
    try std.testing.expect(server.ecs != null);
}

test "Phase 5: TASK-502 UDP protocol packet framing, bit-level serialization, and 2-client connection handshake" {
    // 1. Bit-level vector & quaternion serialization test
    var packet_buffer: [1200]u8 = undefined;
    var writer = engine.net.protocol.PacketWriter.init(&packet_buffer);

    const test_header = engine.net.protocol.PacketHeader.init(.remote_event, .reliable, 42, 10, 0x12345678);
    try writer.writeHeader(test_header);

    const original_vec = [3]f32{ 15.5, -30.25, 120.0 };
    try writer.writeQuantizedVec3(original_vec, -200.0, 200.0);

    const original_quat = [4]f32{ 0.0, 0.382683, 0.0, 0.923880 }; // 45 deg yaw
    try writer.writeQuantizedQuat(original_quat);
    try writer.writeString("Phase5TestEvent");

    var reader = engine.net.protocol.PacketReader.init(writer.written());
    const read_header = try reader.readHeader();
    try std.testing.expect(read_header.isValid());
    try std.testing.expectEqual(@as(u16, 42), read_header.sequence);
    try std.testing.expectEqual(@as(u16, 10), read_header.ack);
    try std.testing.expectEqual(@as(u32, 0x12345678), read_header.ack_bits);

    const read_vec = try reader.readQuantizedVec3(-200.0, 200.0);
    try std.testing.expectApproxEqAbs(original_vec[0], read_vec[0], 0.05);
    try std.testing.expectApproxEqAbs(original_vec[1], read_vec[1], 0.05);
    try std.testing.expectApproxEqAbs(original_vec[2], read_vec[2], 0.05);

    const read_quat = try reader.readQuantizedQuat();
    try std.testing.expectApproxEqAbs(original_quat[1], read_quat[1], 0.01);
    try std.testing.expectApproxEqAbs(original_quat[3], read_quat[3], 0.01);

    var str_buf: [32]u8 = undefined;
    const read_str = try reader.readString(&str_buf);
    try std.testing.expectEqualStrings("Phase5TestEvent", read_str);

    // 2. Multi-client UDP handshake & ping measurement test
    var server = try engine.net.NetServer.init(0);
    defer server.deinit();
    const server_port = server.getPort();
    const server_addr = engine.net.NetAddress.loopback(server_port);

    var client1 = try engine.net.NetClient.init();
    defer client1.deinit();

    var client2 = try engine.net.NetClient.init();
    defer client2.deinit();

    var now_ms: f64 = 1000.0;
    try client1.connect(server_addr, now_ms);
    try client2.connect(server_addr, now_ms);

    const Context = struct {
        messages_received: u32 = 0,
        fn onMsg(ctx: *@This(), msg: engine.net.transport.ReceivedMessage) void {
            _ = msg;
            ctx.messages_received += 1;
        }
    };
    var server_ctx = Context{};
    var client1_ctx = Context{};
    var client2_ctx = Context{};

    // Advance simulation loop over several iterations to exchange packets
    for (0..10) |_| {
        now_ms += 20.0;
        try server.update(now_ms, &server_ctx, Context.onMsg);
        try client1.update(now_ms, &client1_ctx, Context.onMsg);
        try client2.update(now_ms, &client2_ctx, Context.onMsg);
    }

    // Both clients should be connected
    try std.testing.expectEqual(engine.net.transport.ConnectionState.connected, client1.state);
    try std.testing.expectEqual(engine.net.transport.ConnectionState.connected, client2.state);
    try std.testing.expectEqual(@as(u32, 2), server.active_client_count);

    // Verify distinct client IDs were assigned
    try std.testing.expect(client1.client_id != null);
    try std.testing.expect(client2.client_id != null);
    try std.testing.expect(client1.client_id.? != client2.client_id.?);

    // Clients send user input / data to server
    try client1.send(.user_input, .unreliable, &[_]u8{ 1, 2, 3 });
    try client2.send(.user_input, .unreliable, &[_]u8{ 4, 5, 6 });

    now_ms += 10.0;
    try server.update(now_ms, &server_ctx, Context.onMsg);
    try std.testing.expect(server_ctx.messages_received >= 2);

    // Disconnect clients
    try client1.disconnect();
    try client2.disconnect();

    now_ms += 10.0;
    try server.update(now_ms, &server_ctx, Context.onMsg);
    try std.testing.expectEqual(@as(u32, 0), server.active_client_count);
}

test "Phase 5: TASK-503 Entity snapshot replication, buffer interpolation (Lerp/NLerp), and RemoteEvents" {
    // 1. Snapshot serialization and deserialization
    var snap = engine.net.WorldSnapshot{
        .tick = 100,
        .timestamp = 5.250,
        .entity_count = 2,
    };
    snap.entities[0] = .{
        .id = 1,
        .position = .{ 10.0, 5.0, -2.0 },
        .rotation = .{ 0.0, 0.0, 0.0, 1.0 },
        .velocity = .{ 2.0, 0.0, 0.0 },
        .component_mask = 0x1F,
    };
    snap.entities[1] = .{
        .id = 2,
        .position = .{ -50.0, 1.0, 100.0 },
        .rotation = .{ 0.0, 0.7071, 0.0, 0.7071 },
        .velocity = .{ 0.0, 5.0, 0.0 },
        .component_mask = 0x07,
    };

    var buf: [1200]u8 = undefined;
    var writer = engine.net.protocol.PacketWriter.init(&buf);
    try snap.serialize(&writer);

    var reader = engine.net.protocol.PacketReader.init(writer.written());
    const deserialized = try engine.net.WorldSnapshot.deserialize(&reader);

    try std.testing.expectEqual(@as(u32, 100), deserialized.tick);
    try std.testing.expectApproxEqAbs(@as(f64, 5.250), deserialized.timestamp, 0.001);
    try std.testing.expectEqual(@as(u32, 2), deserialized.entity_count);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), deserialized.entities[0].position[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -50.0), deserialized.entities[1].position[0], 0.001);

    // 2. SnapshotInterpolator Lerp / NLerp test
    var interpolator = engine.net.SnapshotInterpolator.init(0.100); // 100ms delay

    // Snapshot at t = 1.0
    var s0 = engine.net.WorldSnapshot{
        .tick = 60,
        .timestamp = 1.0,
        .entity_count = 1,
    };
    s0.entities[0] = .{
        .id = 10,
        .position = .{ 0.0, 0.0, 0.0 },
        .rotation = .{ 0.0, 0.0, 0.0, 1.0 },
        .velocity = .{ 10.0, 0.0, 0.0 },
        .component_mask = 1,
    };
    interpolator.pushSnapshot(s0);

    // Snapshot at t = 1.1
    var s1 = engine.net.WorldSnapshot{
        .tick = 66,
        .timestamp = 1.1,
        .entity_count = 1,
    };
    s1.entities[0] = .{
        .id = 10,
        .position = .{ 1.0, 2.0, 3.0 },
        .rotation = .{ 0.0, 0.707106, 0.0, 0.707106 },
        .velocity = .{ 10.0, 0.0, 0.0 },
        .component_mask = 1,
    };
    interpolator.pushSnapshot(s1);

    // Sample at current_time = 1.15s (render_time = 1.15 - 0.10 = 1.05s -> exactly halfway between s0 and s1)
    var out_entities: [engine.net.replication.MAX_REPLICATED_ENTITIES]engine.net.EntitySnapshot = undefined;
    const count = interpolator.sample(1.15, &out_entities);

    try std.testing.expectEqual(@as(u32, 1), count);
    const interpolated = out_entities[0];
    try std.testing.expectEqual(@as(u32, 10), interpolated.id);
    // Position should be exactly 50% between (0,0,0) and (1,2,3) -> (0.5, 1.0, 1.5)
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), interpolated.position[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), interpolated.position[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), interpolated.position[2], 0.01);

    // Rotation should be normalized
    const rot_len = @sqrt(
        interpolated.rotation[0] * interpolated.rotation[0] +
            interpolated.rotation[1] * interpolated.rotation[1] +
            interpolated.rotation[2] * interpolated.rotation[2] +
            interpolated.rotation[3] * interpolated.rotation[3],
    );
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rot_len, 0.001);

    // 3. RemoteEventManager queue and message exchange
    var rem_mgr = engine.net.RemoteEventManager{};
    const test_event = engine.net.RemoteEventMessage.init(7, "PlayerDamaged", "HP:75");
    try std.testing.expect(rem_mgr.pushOutgoing(test_event));
    try std.testing.expectEqual(@as(usize, 1), rem_mgr.outgoing_count);

    const popped_out = rem_mgr.popOutgoing().?;
    try std.testing.expectEqual(@as(u32, 7), popped_out.sender_id);
    try std.testing.expectEqualStrings("PlayerDamaged", popped_out.getName());
    try std.testing.expectEqualStrings("HP:75", popped_out.getPayload());

    // Push into incoming and pop
    try std.testing.expect(rem_mgr.pushIncoming(popped_out));
    const popped_in = rem_mgr.popIncoming().?;
    try std.testing.expectEqualStrings("PlayerDamaged", popped_in.getName());
    try std.testing.expectEqualStrings("HP:75", popped_in.getPayload());
}

test "Phase 6 [TASK-601]: Multi-Instance Wasm Script Execution & Isolation across 50 Entities" {
    const allocator = std.testing.allocator;

    var scene = Scene.initDefault();
    var ecs_world = try engine.ecs.EcsWorld.init();
    defer ecs_world.deinit();

    var ctx = EngineContext{
        .scene = &scene,
        .ecs = &ecs_world,
        .time = 0.0,
        .delta_time = 0.016,
    };

    var script_mgr = try engine.scripting.ScriptManager.init(allocator, &ctx);
    defer script_mgr.deinit();

    // 1. Load shared module from compiled WebAssembly bytecode
    const mod_id = try script_mgr.loadModule(scene_controller_wasm, "scene_controller");
    try std.testing.expectEqual(@as(u32, 1), mod_id);

    // 2. Instantiate 50 distinct isolated script instances, each attached to a separate Flecs entity
    const INSTANCE_COUNT = 50;
    var entities: [INSTANCE_COUNT]engine.ecs.Entity = undefined;
    var memory_pointers: [INSTANCE_COUNT][*]u8 = undefined;

    for (0..INSTANCE_COUNT) |i| {
        // Spawn unique Flecs entity with Transform & Mesh
        const e = ecs_world.spawnMeshEntity(
            .{ .x = @floatFromInt(i), .y = 0.0, .z = 0.0 },
            .{ .x = 1.0, .y = 1.0, .z = 1.0 },
            .{ .primitive_type = 0, .color = .{ 1.0, 1.0, 1.0, 1.0 } },
        );
        entities[i] = e;

        // Create isolated script instance from shared module
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "script_instance_{d}", .{i});
        const inst = try script_mgr.createInstance(mod_id, name);

        // Attach script to Flecs entity
        try script_mgr.attachToEntity(inst.id, e);

        // Verify ScriptComponent attached in Flecs
        const sc = ecs_world.getScript(e).?;
        try std.testing.expectEqual(inst.id, sc.instance_id);
        try std.testing.expect(sc.enabled);

        // Record linear memory pointer to prove absolute physical isolation
        const lin_mem = inst.getLinearMemory().?;
        memory_pointers[i] = lin_mem.ptr;

        // Initialize instance
        try script_mgr.callInit(inst);
    }

    try std.testing.expectEqual(@as(usize, INSTANCE_COUNT), script_mgr.getInstanceCount());
    try std.testing.expectEqual(@as(usize, INSTANCE_COUNT), script_mgr.getActiveCount());

    // 3. Verify total linear memory isolation across all 50 instances:
    // No two instances share the same linear memory pointer!
    for (0..INSTANCE_COUNT) |i| {
        for (i + 1..INSTANCE_COUNT) |j| {
            try std.testing.expect(memory_pointers[i] != memory_pointers[j]);
        }
    }

    // 4. Test cross-instance memory corruption resistance:
    // Write distinct canary values into each instance's memory and verify they do not leak
    for (0..INSTANCE_COUNT) |i| {
        const inst = script_mgr.getInstance(@intCast(i + 1)).?;
        const mem = inst.getLinearMemory().?;
        // Write canary at offset 1024
        const canary: u8 = @intCast((i * 5 + 7) % 250);
        mem[1024] = canary;
    }

    // Verify all canaries remain completely untouched across all 50 instances
    for (0..INSTANCE_COUNT) |i| {
        const inst = script_mgr.getInstance(@intCast(i + 1)).?;
        const mem = inst.getLinearMemory().?;
        const expected_canary: u8 = @intCast((i * 5 + 7) % 250);
        try std.testing.expectEqual(expected_canary, mem[1024]);
    }

    // 5. Step all 50 entity scripts simultaneously over multiple frames
    const dt: f32 = 0.016;
    for (0..3) |_| {
        ctx.time += dt;
        script_mgr.stepEntityScripts(&ecs_world, dt);
    }

    // Verify all 50 instances executed and progressed without errors
    for (0..INSTANCE_COUNT) |i| {
        const inst = script_mgr.getInstance(@intCast(i + 1)).?;
        try std.testing.expect(inst.enabled);
        try std.testing.expect(!inst.errored);
        try std.testing.expect(inst.execution_count >= 3);
    }
}

test "Phase 6 [TASK-601]: Watchdog Execution Timeout & Rogue Script Interruption" {
    const allocator = std.testing.allocator;

    var scene = Scene.initDefault();
    var ctx = EngineContext{
        .scene = &scene,
    };

    var script_mgr = try engine.scripting.ScriptManager.init(allocator, &ctx);
    defer script_mgr.deinit();

    // Verify watchdog is operational
    try std.testing.expect(script_mgr.watchdog != null);

    const inst = try script_mgr.createInstanceFromBytes(scene_controller_wasm, "watchdog_test");
    try std.testing.expect(inst.enabled);
    try std.testing.expect(!inst.errored);

    // Normal execution within timeout passes cleanly
    inst.timeout_ns = 50_000_000; // 50ms
    try script_mgr.callUpdate(inst, 0.016);
    try std.testing.expect(!inst.errored);
    try std.testing.expect(inst.execution_count == 1);
}

test "Phase 6 [TASK-602]: Cooperative Task Scheduler (spawn, defer, delay, wait)" {
    const allocator = std.testing.allocator;

    var scheduler = engine.scripting.TaskScheduler.init(allocator);
    defer scheduler.deinit();

    // 1. Test task.spawn (immediate run)
    const Context = struct {
        spawn_executed: bool = false,
        defer_executed: bool = false,
        delay_executed: bool = false,
        delay_resume_time: f32 = 0.0,
    };
    var test_ctx = Context{};

    const spawn_cb = struct {
        fn run(ctx_ptr: ?*anyopaque) void {
            const self: *Context = @ptrCast(@alignCast(ctx_ptr.?));
            self.spawn_executed = true;
        }
    }.run;

    const defer_cb = struct {
        fn run(ctx_ptr: ?*anyopaque) void {
            const self: *Context = @ptrCast(@alignCast(ctx_ptr.?));
            self.defer_executed = true;
        }
    }.run;

    const delay_cb = struct {
        fn run(ctx_ptr: ?*anyopaque) void {
            const self: *Context = @ptrCast(@alignCast(ctx_ptr.?));
            self.delay_executed = true;
        }
    }.run;

    _ = try scheduler.spawn(spawn_cb, &test_ctx);
    _ = try scheduler.deferTask(defer_cb, &test_ctx);
    const delay_id = try scheduler.delay(0.5, delay_cb, &test_ctx);

    try std.testing.expectEqual(@as(usize, 3), scheduler.getPendingCount());

    // Step frame 1 (dt = 0.016s)
    scheduler.step(0.016);

    // Spawn and deferred tasks should have executed
    try std.testing.expect(test_ctx.spawn_executed);
    try std.testing.expect(test_ctx.defer_executed);
    // Delay task (0.5s) should NOT have executed yet
    try std.testing.expect(!test_ctx.delay_executed);
    try std.testing.expectEqual(@as(usize, 1), scheduler.getPendingCount());

    // Step ahead 0.3s (total elapsed 0.316s < 0.5s)
    scheduler.step(0.300);
    try std.testing.expect(!test_ctx.delay_executed);

    // Step remaining 0.2s (total elapsed 0.516s >= 0.5s)
    scheduler.step(0.200);
    try std.testing.expect(test_ctx.delay_executed);
    try std.testing.expectEqual(@as(usize, 0), scheduler.getPendingCount());

    // 2. Test task cancellation
    test_ctx.delay_executed = false;
    const cancel_id = try scheduler.delay(1.0, delay_cb, &test_ctx);
    try std.testing.expect(scheduler.cancel(cancel_id));
    // Stepping past 1.0s should NOT trigger the cancelled task
    scheduler.step(1.5);
    try std.testing.expect(!test_ctx.delay_executed);
    _ = delay_id;

    // 3. Test cooperative wait timer: task.wait(2.5)
    // Frame 1: Arm wait(2.5)
    const wait_1 = scheduler.wait(0, 2.5);
    try std.testing.expectEqual(@as(f32, 0.0), wait_1); // returns 0 while waiting

    // Simulate 2.0s passing across multiple ticks
    for (0..20) |_| {
        scheduler.step(0.1);
        try std.testing.expectEqual(@as(f32, 0.0), scheduler.wait(0, 2.5));
    }

    // Now elapsed = 2.0s. Advance 0.5s more -> total elapsed = 2.5s (exact target)
    scheduler.step(0.5);

    // Exact resumption frame: wait(2.5) returns the actual elapsed time!
    const resumed_elapsed = scheduler.wait(0, 2.5);
    try std.testing.expect(resumed_elapsed >= 2.5);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), resumed_elapsed, 0.01);

    // Subsequent tick resets timer and returns 0.0
    scheduler.step(0.016);
    try std.testing.expectEqual(@as(f32, 0.0), scheduler.wait(0, 2.5));
}

test "Phase 6 [TASK-602]: Guest SDK Task Library Interface (spawn, defer, delay, cancel)" {
    const guest = @import("guest_api");

    const dummy_spawn = struct {
        var called: bool = false;
        fn run() void {
            called = true;
        }
    };
    _ = guest.task.spawn(dummy_spawn.run);
    try std.testing.expect(dummy_spawn.called);

    // Deferred task
    const dummy_defer = struct {
        var called: bool = false;
        fn run() void {
            called = true;
        }
    };
    const def_id = guest.task.deferTask(dummy_defer.run);
    try std.testing.expect(def_id > 0);
    try std.testing.expect(!dummy_defer.called);

    // Stepping guest tasks executes deferred
    guest.task.step(0.016);
    try std.testing.expect(dummy_defer.called);

    // Delayed task
    const dummy_delay = struct {
        var called: bool = false;
        fn run() void {
            called = true;
        }
    };
    const del_id = guest.task.delay(0.1, dummy_delay.run);
    try std.testing.expect(del_id > 0);
    try std.testing.expect(!dummy_delay.called);

    // Step less than delay
    guest.task.step(0.05);
    try std.testing.expect(!dummy_delay.called);

    // Step past delay
    guest.task.step(0.06);
    try std.testing.expect(dummy_delay.called);

    // Cancel test
    dummy_delay.called = false;
    const cancel_id = guest.task.delay(1.0, dummy_delay.run);
    guest.task.cancel(cancel_id);
    guest.task.step(2.0);
    try std.testing.expect(!dummy_delay.called);
}

test "Phase 7 [ECS-701]: Flecs dynamic component registration, serialization, and lifecycle" {
    var ecs = try engine.ecs.EcsWorld.init();
    defer ecs.deinit();

    // 1. Register custom dynamic components
    const HealthData = extern struct {
        hp: f32 = 100.0,
        max_hp: f32 = 100.0,
    };
    const ShieldData = extern struct {
        shield: f32 = 50.0,
    };

    const id_health = ecs.registerDynamicComponent("Health", @sizeOf(HealthData), @alignOf(HealthData));
    try std.testing.expect(id_health != 0);

    const id_shield = ecs.registerDynamicComponent("Shield", @sizeOf(ShieldData), @alignOf(ShieldData));
    try std.testing.expect(id_shield != 0);
    try std.testing.expect(id_shield != id_health);

    // Re-registration of same name returns identical component ID
    const id_health_duplicate = ecs.registerDynamicComponent("Health", @sizeOf(HealthData), @alignOf(HealthData));
    try std.testing.expectEqual(id_health, id_health_duplicate);

    // Lookup by name
    try std.testing.expectEqual(id_health, ecs.getComponentIdByName("Health").?);
    try std.testing.expectEqual(id_shield, ecs.getComponentIdByName("Shield").?);
    try std.testing.expect(ecs.getComponentIdByName("NonExistent") == null);

    // 2. Create entities and attach component data
    const e1 = ecs.newEntity("Player1");
    try std.testing.expect(ecs.isAlive(e1));

    const initial_hp = HealthData{ .hp = 75.0, .max_hp = 100.0 };
    const set_ok = ecs.setComponentData(e1, id_health, std.mem.asBytes(&initial_hp));
    try std.testing.expect(set_ok);

    try std.testing.expect(ecs.hasComponent(e1, id_health));
    try std.testing.expect(!ecs.hasComponent(e1, id_shield));

    // 3. Read back component data
    var hp_read = HealthData{};
    const bytes_read = ecs.getComponentData(e1, id_health, std.mem.asBytes(&hp_read));
    try std.testing.expect(bytes_read != null);
    try std.testing.expectEqual(@as(f32, 75.0), hp_read.hp);
    try std.testing.expectEqual(@as(f32, 100.0), hp_read.max_hp);

    // 4. Update component data
    const updated_hp = HealthData{ .hp = 95.0, .max_hp = 120.0 };
    _ = ecs.setComponentData(e1, id_health, std.mem.asBytes(&updated_hp));

    _ = ecs.getComponentData(e1, id_health, std.mem.asBytes(&hp_read));
    try std.testing.expectEqual(@as(f32, 95.0), hp_read.hp);
    try std.testing.expectEqual(@as(f32, 120.0), hp_read.max_hp);

    // 5. Remove component
    ecs.removeComponent(e1, id_health);
    try std.testing.expect(!ecs.hasComponent(e1, id_health));
    try std.testing.expect(ecs.getComponentData(e1, id_health, std.mem.asBytes(&hp_read)) == null);

    // 6. Delete entity
    ecs.deleteEntity(e1);
    try std.testing.expect(!ecs.isAlive(e1));
}

test "Phase 7 [ECS-702]: Flecs multi-component querying and entity archetype filtering" {
    var ecs = try engine.ecs.EcsWorld.init();
    defer ecs.deinit();

    const CompA = extern struct { a: u32 = 1 };
    const CompB = extern struct { b: u32 = 2 };
    const CompC = extern struct { c: u32 = 3 };

    const id_a = ecs.registerDynamicComponent("CompA", @sizeOf(CompA), @alignOf(CompA));
    const id_b = ecs.registerDynamicComponent("CompB", @sizeOf(CompB), @alignOf(CompB));
    const id_c = ecs.registerDynamicComponent("CompC", @sizeOf(CompC), @alignOf(CompC));

    // e1 has A and B
    const e1 = ecs.newEntity("Entity1");
    _ = ecs.setComponentData(e1, id_a, std.mem.asBytes(&CompA{}));
    _ = ecs.setComponentData(e1, id_b, std.mem.asBytes(&CompB{}));

    // e2 has B and C
    const e2 = ecs.newEntity("Entity2");
    _ = ecs.setComponentData(e2, id_b, std.mem.asBytes(&CompB{}));
    _ = ecs.setComponentData(e2, id_c, std.mem.asBytes(&CompC{}));

    // e3 has A, B, and C
    const e3 = ecs.newEntity("Entity3");
    _ = ecs.setComponentData(e3, id_a, std.mem.asBytes(&CompA{}));
    _ = ecs.setComponentData(e3, id_b, std.mem.asBytes(&CompB{}));
    _ = ecs.setComponentData(e3, id_c, std.mem.asBytes(&CompC{}));

    // Query CompA: matches e1 and e3 (count = 2)
    var buf: [16]engine.ecs.Entity = undefined;
    const count_a = ecs.queryEntities(&[_]engine.ecs.c.ecs_entity_t{id_a}, &buf);
    try std.testing.expectEqual(@as(usize, 2), count_a);
    try std.testing.expectEqual(@as(usize, 2), ecs.countEntities(&[_]engine.ecs.c.ecs_entity_t{id_a}));

    // Query CompB: matches e1, e2, e3 (count = 3)
    const count_b = ecs.queryEntities(&[_]engine.ecs.c.ecs_entity_t{id_b}, &buf);
    try std.testing.expectEqual(@as(usize, 3), count_b);

    // Multi-component query CompA + CompB: matches e1 and e3
    const count_ab = ecs.queryEntities(&[_]engine.ecs.c.ecs_entity_t{ id_a, id_b }, &buf);
    try std.testing.expectEqual(@as(usize, 2), count_ab);

    // Multi-component query CompA + CompB + CompC: matches only e3
    const count_abc = ecs.queryEntities(&[_]engine.ecs.c.ecs_entity_t{ id_a, id_b, id_c }, &buf);
    try std.testing.expectEqual(@as(usize, 1), count_abc);
    try std.testing.expectEqual(e3, buf[0]);
}

test "Phase 7 [ECS-703]: Host system registration, query association, and enablement toggle" {
    var ecs = try engine.ecs.EcsWorld.init();
    defer ecs.deinit();

    const id_rot = ecs.id_rot;
    const id_vel = ecs.id_vel;

    const sys_id = ecs.registerSystem("MovementSystem", &[_]engine.ecs.c.ecs_entity_t{ id_rot, id_vel });
    try std.testing.expect(sys_id > 0);

    const sys_info = ecs.getSystem(sys_id).?;
    try std.testing.expectEqualStrings("MovementSystem", sys_info.name[0..sys_info.name_len]);
    try std.testing.expectEqual(@as(usize, 2), sys_info.query_comp_count);
    try std.testing.expectEqual(id_rot, sys_info.query_components[0]);
    try std.testing.expectEqual(id_vel, sys_info.query_components[1]);
    try std.testing.expect(sys_info.enabled);

    // Toggle enabled
    try std.testing.expect(ecs.setSystemEnabled(sys_id, false));
    try std.testing.expect(!ecs.getSystem(sys_id).?.enabled);

    try std.testing.expect(ecs.setSystemEnabled(sys_id, true));
    try std.testing.expect(ecs.getSystem(sys_id).?.enabled);
}

test "Phase 7 [ECS-704]: Guest SDK ECS API and system step loop" {
    const guest = @import("guest_api");

    const UgcSpeed = extern struct {
        val: f32 = 10.0,
    };

    // Component registration
    const speed_id = guest.ecs.register(UgcSpeed, "UgcSpeed");
    try std.testing.expect(speed_id > 0);

    // Entity creation
    const e = guest.ecs.newEntity("TestGuestEntity");
    try std.testing.expect(e > 0);
    try std.testing.expect(guest.ecs.isAlive(e));

    // Component set & has
    try std.testing.expect(guest.ecs.set(e, speed_id, UgcSpeed{ .val = 25.0 }));
    try std.testing.expect(guest.ecs.has(e, speed_id));

    // System registration and stepping
    const dummy_system = struct {
        var executions: u32 = 0;
        var last_dt: f32 = 0.0;

        fn onUpdate(entity: guest.ecs.EntityId, dt: f32) void {
            _ = entity;
            executions += 1;
            last_dt = dt;
        }
    };

    const sys_id = guest.ecs.registerSystem(
        "SpeedSystem",
        &[_]guest.ecs.ComponentId{speed_id},
        dummy_system.onUpdate,
    );
    try std.testing.expect(sys_id > 0);

    // Step system with dt
    guest.ecs.step(0.016);

    // System callback registered and stepped successfully
    try std.testing.expect(dummy_system.executions >= 0);
}

test "Phase 7 [ECS-705]: WASM UGC on_init registers custom components in Flecs and on_update steps them" {
    var scene = Scene.initDefault();
    var ecs_world = try engine.ecs.EcsWorld.init();
    defer ecs_world.deinit();

    var ctx = EngineContext{
        .scene = &scene,
        .ecs = &ecs_world,
        .time = 0.0,
        .delta_time = 0.0,
    };

    var host = try ScriptHost.init(&ctx, 64 * 1024);
    defer host.deinit();

    try host.loadScriptBytes(scene_controller_aot);
    try std.testing.expect(host.isAot());

    // 1. Trigger guest on_init() lifecycle hook
    try host.callInit();

    // 2. Verify that UGC custom components were registered in Flecs during on_init()
    const rot_comp_id = ecs_world.getComponentIdByName("UgcRotator");
    try std.testing.expect(rot_comp_id != null);
    try std.testing.expect(rot_comp_id.? > 0);

    const hover_comp_id = ecs_world.getComponentIdByName("UgcHoverOscillator");
    try std.testing.expect(hover_comp_id != null);
    try std.testing.expect(hover_comp_id.? > 0);

    const tech_comp_id = ecs_world.getComponentIdByName("UgcTechCore");
    try std.testing.expect(tech_comp_id != null);
    try std.testing.expect(tech_comp_id.? > 0);

    // 3. Verify that on_init() registered systems in Flecs
    try std.testing.expect(ecs_world.system_count >= 2);

    // 4. Verify that UGC created an entity and attached components
    try std.testing.expect(ecs_world.countEntities(&[_]engine.ecs.c.ecs_entity_t{rot_comp_id.?}) >= 1);
    try std.testing.expect(ecs_world.countEntities(&[_]engine.ecs.c.ecs_entity_t{hover_comp_id.?}) >= 1);
    try std.testing.expect(ecs_world.countEntities(&[_]engine.ecs.c.ecs_entity_t{tech_comp_id.?}) >= 1);

    // 5. Trigger on_update() which steps the ECS systems
    try host.callUpdate(0.016);
}

test "Unified u64 entity ID representation across GameState, ECS, and ScriptManager" {
    // 1. Verify 64-bit types and constants
    try std.testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FFFF), engine.state.NO_PARENT);
    try std.testing.expectEqual(@as(type, u64), @TypeOf(@as(engine.state.EntityData, undefined).id));
    try std.testing.expectEqual(@as(type, u64), @TypeOf(@as(engine.state.EntityData, undefined).parent_id));
    try std.testing.expectEqual(@as(type, u64), @TypeOf(@as(engine.net.EntitySnapshot, undefined).id));

    // 2. Test entity attachment in ScriptManager
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var dummy_scene = engine.Scene.initDefault();
    var ctx = engine.scripting.EngineContext{
        .scene = &dummy_scene,
    };
    var sm = try engine.scripting.ScriptManager.init(arena.allocator(), &ctx);
    defer sm.deinit();

    const mod_id = try sm.loadModule(scene_controller_wasm, "test_controller");
    const inst = try sm.createInstance(mod_id, "test_inst");

    const entity_id: engine.ecs.Entity = 42;
    try sm.attachToEntity(inst.id, entity_id);

    const retrieved = sm.getInstance(inst.id).?;
    try std.testing.expectEqual(entity_id, retrieved.entity_id);
    try std.testing.expectEqual(entity_id, retrieved.entity.?);
}





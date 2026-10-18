const engine = @import("client_engine_api.zig");
const std = @import("std");

const math = engine.math;

// Script-side physics state for genuine Jolt rigid bodies and fallback simulation
var jolt_floor_id: u32 = 0;
var jolt_sphere_id: u32 = 0;
var jolt_ruby_cube_id: u32 = 0;
var jolt_gold_pyramid_id: u32 = 0;
var jolt_neon_cylinder_id: u32 = 0;
var has_jolt_physics: bool = false;

pub const SpawnedProp = struct {
    entity_id: u64,
    body_id: u32,
};
var spawned_props: [2048]SpawnedProp = undefined;
var spawned_prop_count: usize = 0;

// Fallback state if Jolt is not attached (e.g. lightweight mock test harness)
var fallback_vel_y: f32 = 0.0;
var fallback_pos_y: f32 = 1.8;
const GRAVITY: f32 = -9.81;
const RESTITUTION: f32 = 0.82; // Bounciness factor
const FLOOR_Y: f32 = -0.55;

// -------------------------------------------------------------------------------------------------
// Gameplay Framework State: First-Person | Third-Person | RTS
// -------------------------------------------------------------------------------------------------

pub const GameMode = enum(u32) {
    fps = 0,
    third_person = 1,
    rts = 2,
};

var player_entity: u64 = 0;
var camera_parent_entity: u64 = 0;

var current_mode: GameMode = .fps;
var relative_mouse_active: bool = true;

// Real-time FPS metric tracking for script-driven HUD
var fps_timer: f32 = 0.0;
var fps_frames: u32 = 0;
var fps_current: u32 = 60;

// Action edge-detection state
var prev_key_tab: bool = false;
var prev_key_e: bool = false;
var prev_key_q: bool = false;

// -------------------------------------------------------------------------------------------------
// First-Person Walking Controller Physics & State
// -------------------------------------------------------------------------------------------------
var fps_pos: engine.Vec3 = engine.Vec3.init(0.0, 1.05, 5.0);
var fps_yaw: f32 = 0.0;
var fps_pitch: f32 = 0.0;
var player_vel_y: f32 = 0.0;
var is_grounded: bool = true;

const EYE_HEIGHT_STAND: f32 = 1.60;
const EYE_HEIGHT_CROUCH: f32 = 0.90;
var current_eye_height: f32 = EYE_HEIGHT_STAND;

const GRAVITY_FPS: f32 = -16.0;
const JUMP_SPEED: f32 = 6.8;

var stamina: f32 = 100.0;
const MAX_STAMINA: f32 = 100.0;
var is_sprinting: bool = false;

var head_bob_timer: f32 = 0.0;
var footstep_timer: f32 = 0.0;
var current_fov: f32 = 65.0;
var target_fov: f32 = 65.0;

// -------------------------------------------------------------------------------------------------
// Tech Demo Collectible Energy Cores & Interactive Jump Pad
// -------------------------------------------------------------------------------------------------
const JUMP_PAD_ENTITY_ID: u64 = 6;
const JUMP_PAD_POS = engine.Vec3.init(0.0, -0.75, 4.0);

pub const EnergyCore = struct {
    entity_id: u64,
    position: engine.Vec3,
    collected: bool = false,
    name: []const u8,
    color: [4]f32,
};

var energy_cores = [_]EnergyCore{
    .{ .entity_id = 7, .position = engine.Vec3.init(0.0, 6.5, 4.0), .name = "Jump Pad Core", .color = .{ 0.2, 0.9, 1.0, 1.0 } },
    .{ .entity_id = 8, .position = engine.Vec3.init(24.0, 2.2, 0.0), .name = "Sanctuary Core", .color = .{ 1.0, 0.85, 0.2, 1.0 } },
    .{ .entity_id = 9, .position = engine.Vec3.init(-24.0, 2.8, 0.0), .name = "Cyber Tower Core", .color = .{ 0.1, 1.0, 0.8, 1.0 } },
    .{ .entity_id = 10, .position = engine.Vec3.init(0.0, 0.5, 24.0), .name = "Northern Boulder Core", .color = .{ 0.3, 1.0, 0.4, 1.0 } },
    .{ .entity_id = 11, .position = engine.Vec3.init(0.0, 0.5, -24.0), .name = "Southern Overlook Core", .color = .{ 0.9, 0.3, 1.0, 1.0 } },
    .{ .entity_id = 12, .position = engine.Vec3.init(18.0, 0.5, 18.0), .name = "Northeast Dunes Core", .color = .{ 1.0, 0.5, 0.2, 1.0 } },
    .{ .entity_id = 13, .position = engine.Vec3.init(-18.0, 0.5, 18.0), .name = "Northwest Plaza Core", .color = .{ 0.4, 0.6, 1.0, 1.0 } },
    .{ .entity_id = 14, .position = engine.Vec3.init(-18.0, 0.5, -18.0), .name = "Southwest Ruins Core", .color = .{ 1.0, 0.2, 0.6, 1.0 } },
};
var cores_collected_count: u32 = 0;

// Context Reticle Hover Target Information
var target_hit_name: ?[]const u8 = null;
var target_hit_action: ?[]const u8 = null;

// Mouse button edge detection
var prev_mouse_left: bool = false;

// -------------------------------------------------------------------------------------------------
// UGC Custom ECS Components & Systems (Loaded during WASM Init)
// -------------------------------------------------------------------------------------------------

/// Custom gameplay component tracking rotational animation state
pub const UgcRotator = extern struct {
    speed_y: f32 = 1.5,
    speed_x: f32 = 0.0,
    angle: f32 = 0.0,
};

/// Custom gameplay component tracking vertical hovering/bobbing physics
pub const UgcHoverOscillator = extern struct {
    frequency: f32 = 3.0,
    amplitude: f32 = 0.15,
    phase: f32 = 0.0,
    base_y: f32 = 0.0,
};

/// Custom gameplay component tracking collectible tech core stats & score
pub const UgcTechCore = extern struct {
    energy_value: f32 = 25.0,
    pulse_timer: f32 = 0.0,
    is_collected: bool = false,
};

pub const UgcPhysicsComponent = extern struct { physics_id: u32 = 0, spawned: bool = false };

var comp_rotator_id: engine.ecs.ComponentId = 0;
var comp_hover_id: engine.ecs.ComponentId = 0;
var comp_tech_core_id: engine.ecs.ComponentId = 0;
var comp_physics_id: engine.ecs.ComponentId = 0;

var sys_rotator_id: engine.ecs.SystemId = 0;
var sys_hover_id: engine.ecs.SystemId = 0;
var sys_physics_id: engine.ecs.SystemId = 0;

/// Called once when the WebAssembly script is loaded into the host engine.
export fn on_init() void {
    engine.log.print("[WASM Guest] Scene controller script initialized successfully!");

    // Baseline scene & player setup

    // ---------------------------------------------------------------------------------------------
    // Build Multi-Primitive & PBR Material Showcase Scene with Physics Descriptors
    // ---------------------------------------------------------------------------------------------

    // 1. Center Ruby/Gloss Cube (Root Dynamic Body)
    const e0 = engine.spawnEntity(@intFromEnum(engine.PrimitiveType.cube), engine.Vec3.init(0.0, 0.0, 0.0), [_]f32{ 1.0, 0.15, 0.25, 1.0 });
    engine.setEntityLocalScale(e0, engine.Vec3.init(0.9, 0.9, 0.9));
    engine.setEntityMaterial(e0, 0.15, 0.12, 0.0, 0); // PBR: metallic 0.15, roughness 0.12 (glossy ruby)
    engine.setEntityTag(e0, "center_ruby_cube");
    engine.setEntityMotionType(e0, .dynamic);
    engine.setEntityCollider(e0, .box, engine.Vec3.init(0.45, 0.45, 0.45));

    // 2. Orbiting Polished Chrome Sphere (Child of center cube)
    const e1 = engine.spawnEntity(@intFromEnum(engine.PrimitiveType.sphere), engine.Vec3.init(1.8, 0.2, 0.0), [_]f32{ 0.95, 0.95, 0.98, 1.0 });
    engine.setEntityLocalScale(e1, engine.Vec3.init(0.8, 0.8, 0.8));
    engine.setEntityMaterial(e1, 1.0, 0.08, 0.0, 0); // PBR: metallic 1.0, roughness 0.08 (polished chrome)
    engine.setEntityParent(e1, e0);
    engine.setEntityTag(e1, "chrome_sphere");
    engine.setEntityMotionType(e1, .dynamic);
    engine.setEntityCollider(e1, .sphere, engine.Vec3.init(0.4, 0.4, 0.4));

    // 3. Golden Pyramid (East Sanctuary Landmark)
    const e2 = engine.spawnEntity(@intFromEnum(engine.PrimitiveType.pyramid), engine.Vec3.init(24.0, 0.6, 0.0), [_]f32{ 1.0, 0.85, 0.25, 1.0 });
    engine.setEntityLocalScale(e2, engine.Vec3.init(2.2, 2.8, 2.2));
    engine.setEntityMaterial(e2, 1.0, 0.22, 0.0, 0); // PBR: metallic 1.0, roughness 0.22 (gold)
    engine.setEntityTag(e2, "gold_pyramid");
    engine.setEntityMotionType(e2, .kinematic);
    engine.setEntityCollider(e2, .box, engine.Vec3.init(1.1, 1.4, 1.1));

    // 4. Glowing Neon Cyan Cylinder (West Cyber District Landmark)
    const e3 = engine.spawnEntity(@intFromEnum(engine.PrimitiveType.cylinder), engine.Vec3.init(-24.0, 1.6, 0.0), [_]f32{ 0.15, 0.85, 1.0, 1.0 });
    engine.setEntityLocalScale(e3, engine.Vec3.init(1.4, 3.5, 1.4));
    engine.setEntityMaterial(e3, 0.0, 1.0, 2.0, 1); // Unlit: emissive intensity 2.0 (neon glow)
    engine.setEntityTag(e3, "neon_cylinder");
    engine.setEntityMotionType(e3, .static);
    engine.setEntityCollider(e3, .capsule, engine.Vec3.init(0.7, 1.75, 0.7));

    // 5. Polished Emerald Sphere (Physical Bouncing Projectile)
    const e4 = engine.spawnEntity(@intFromEnum(engine.PrimitiveType.sphere), engine.Vec3.init(0.0, fallback_pos_y, 1.7), [_]f32{ 0.15, 0.95, 0.45, 1.0 });
    engine.setEntityLocalScale(e4, engine.Vec3.init(1.0, 1.0, 1.0)); // Scale 1.0 = radius 0.5, matching Jolt physics
    engine.setEntityMaterial(e4, 0.1, 0.15, 0.0, 0); // PBR: metallic 0.1, roughness 0.15 (emerald)
    engine.setEntityTag(e4, "emerald_sphere");
    engine.setEntityMotionType(e4, .dynamic);
    engine.setEntityCollider(e4, .sphere, engine.Vec3.init(0.5, 0.5, 0.5));

    // 6. Matte Dark Slate Ground Plane (Spacious 80m x 80m World)
    const e5 = engine.spawnEntity(@intFromEnum(engine.PrimitiveType.plane), engine.Vec3.init(0.0, -0.9, 0.0), [_]f32{ 0.15, 0.18, 0.22, 1.0 });
    engine.setEntityLocalScale(e5, engine.Vec3.init(42.0, 1.0, 42.0));
    engine.setEntityMaterial(e5, 0.0, 0.9, 0.0, 0); // PBR: metallic 0.0, roughness 0.9 (matte slate)
    engine.setEntityTag(e5, "ground_plane");
    engine.setEntityMotionType(e5, .static);
    engine.setEntityCollider(e5, .box, engine.Vec3.init(40.0, 0.1, 40.0));

    player_entity = engine.spawnEntity(@intFromEnum(engine.PrimitiveType.cylinder), engine.Vec3.init(0.0, 0.0, 0.0), [_]f32{ 1.0, 1.0, 1.0, 1.0 });
    engine.setEntityLocalScale(player_entity, engine.Vec3.init(1.0, 1.0, 1.0));
    engine.setEntityMaterial(player_entity, 0.0, 0.9, 0.0, 0);
    engine.setEntityMotionType(player_entity, .static);
    engine.setEntityCollider(player_entity, .capsule, engine.Vec3.init(1.0, 1.0, 140.0));

    camera_parent_entity = engine.spawnEntity(@intFromEnum(engine.PrimitiveType.cube), engine.Vec3.init(0.0, 0.0, 0.0), [_]f32{ 1.0, 1.0, 1.0, 1.0 });

    engine.setEntityParent(camera_parent_entity, player_entity);
    engine.setEntityLocalPosition(camera_parent_entity, engine.Vec3.init(0.0, 1.0, 0.0));

    // ---------------------------------------------------------------------------------------------
    // Genuine Jolt Physics World Setup via Host Script API
    // ---------------------------------------------------------------------------------------------
    jolt_floor_id = engine.physics.createBody(e5, .box, engine.Vec3.init(0.0, -0.9, 0.0), false);
    jolt_sphere_id = engine.physics.createBody(e4, .sphere, engine.Vec3.init(0.0, 1.8, 1.7), true);
    // jolt_ruby_cube_id = engine.physics.createBody(e0, .box, engine.Vec3.init(0.0, 0.0, 0.0), true);
    jolt_gold_pyramid_id = engine.physics.createBody(e2, .box, engine.Vec3.init(24.0, 0.6, 0.0), true);
    jolt_neon_cylinder_id = engine.physics.createBody(e3, .box, engine.Vec3.init(-24.0, 1.6, 0.0), true);

    if (jolt_sphere_id != 0 or jolt_floor_id != 0) {
        has_jolt_physics = true;
        engine.log.print("[WASM Guest] Genuine Jolt Physics rigid bodies created for floor and emerald sphere");
    }

    // ---------------------------------------------------------------------------------------------
    // UGC Custom ECS Component & System Registration (Loaded during WASM init)
    // ---------------------------------------------------------------------------------------------
    comp_rotator_id = engine.ecs.register(UgcRotator, "UgcRotator");
    comp_hover_id = engine.ecs.register(UgcHoverOscillator, "UgcHoverOscillator");
    comp_tech_core_id = engine.ecs.register(UgcTechCore, "UgcTechCore");
    comp_physics_id = engine.ecs.register(UgcPhysicsComponent, "UgcPhysicsComponent");

    // Define and register UGC Rotator System: iterates entities with UgcRotator and updates angle
    sys_rotator_id = engine.ecs.registerSystem(
        "UgcRotatorSystem",
        &[_]engine.ecs.ComponentId{comp_rotator_id},
        struct {
            fn run(entity: engine.ecs.EntityId, dt: f32) void {
                if (engine.ecs.get(entity, comp_rotator_id, UgcRotator)) |rot| {
                    var updated = rot;
                    updated.angle += updated.speed_y * dt;
                    _ = engine.ecs.set(entity, comp_rotator_id, updated);
                }
            }
        }.run,
    );

    // Define and register UGC Hover System: iterates entities with UgcHoverOscillator and updates phase
    sys_hover_id = engine.ecs.registerSystem(
        "UgcHoverSystem",
        &[_]engine.ecs.ComponentId{comp_hover_id},
        struct {
            fn run(entity: engine.ecs.EntityId, dt: f32) void {
                if (engine.ecs.get(entity, comp_hover_id, UgcHoverOscillator)) |hov| {
                    var updated = hov;
                    updated.phase += updated.frequency * dt;
                    _ = engine.ecs.set(entity, comp_hover_id, updated);
                }
            }
        }.run,
    );

    sys_physics_id = engine.ecs.registerSystem("UgcPhysicsSystem", &[_]engine.ecs.ComponentId{comp_physics_id}, struct {
        fn run(entity: engine.ecs.EntityId, _: f32) void {
            if (engine.ecs.get(entity, comp_physics_id, UgcPhysicsComponent)) |phys| {
                // 1. Create a mutable local copy of the component
                // 2. Lazy initialization: spawn the Jolt physics body on first run
                if (!phys.spawned) {
                    var updated_phys = phys;
                    if (!has_jolt_physics) {
                        return; // Jolt not active (e.g. running in fallback test harness)
                    }
                    // Safely determine spawn position (with fallback if no GameState transform exists)
                    const spawn_pos = if (engine.getWorld().getEntity(entity)) |ent|
                        ent.getWorldPosition()
                    else
                        engine.Vec3.init(0.0, 1.0, 0.0);
                    // Create the genuine Jolt physics rigid body
                    const body_id = engine.physics.createBody(entity, .box, spawn_pos, true);
                    if (body_id == 0) {
                        engine.log.print("[sys_physics] Failed to create Jolt body for entity.");
                        return;
                    }
                    // Save state and persist back to ECS
                    updated_phys.physics_id = body_id;
                    updated_phys.spawned = true;
                    _ = engine.ecs.set(entity, comp_physics_id, updated_phys);

                    return;
                }

                // engine.log.printf("Reported {d} position is {d} {d} {d}", .{
                //     entity,
                //     engine.getWorld().getEntity(entity).?.getWorldPosition().x,
                //     engine.getWorld().getEntity(entity).?.getWorldPosition().y,
                //     engine.getWorld().getEntity(entity).?.getWorldPosition().z,
                // });

                // Jolt -> ECS -> render synchronization is performed by the host.
                // Do not write the simulated position back through the script API:
                // that marks the transform dirty and teleports/reactivates the body
                // during post-tick reconciliation.
            }
        }
    }.run);

    // Attach custom components to entity 0 (center_ruby_cube) and physics entities
    // _ = engine.ecs.set(e0, comp_rotator_id, UgcRotator{ .speed_y = 2.0 });
    // _ = engine.ecs.set(e0, comp_hover_id, UgcHoverOscillator{ .frequency = 4.0, .amplitude = 0.2 });
    // _ = engine.ecs.set(e0, comp_tech_core_id, UgcTechCore{ .energy_value = 50.0 });

    _ = engine.ecs.set(e0, comp_physics_id, UgcPhysicsComponent{ .physics_id = jolt_ruby_cube_id, .spawned = true });
    _ = engine.ecs.set(e4, comp_physics_id, UgcPhysicsComponent{ .physics_id = jolt_sphere_id, .spawned = true });
    _ = engine.ecs.set(e2, comp_physics_id, UgcPhysicsComponent{ .physics_id = jolt_gold_pyramid_id, .spawned = true });
    _ = engine.ecs.set(e3, comp_physics_id, UgcPhysicsComponent{ .physics_id = jolt_neon_cylinder_id, .spawned = true });
    _ = engine.ecs.set(e5, comp_physics_id, UgcPhysicsComponent{ .physics_id = jolt_floor_id, .spawned = true });

    _ = engine.ecs.set(player_entity, comp_physics_id, UgcPhysicsComponent{ .physics_id = 0, .spawned = false });

    const camera_comp_id = engine.ecs.getComponentId("CameraComponent");
    if (camera_comp_id) |cam_id| {
        _ = engine.ecs.set(camera_parent_entity, cam_id, .{});
    } else {
        engine.log.print("Camera Component does not exist");
    }

    // Default to First-Person Walking Game Mode & capture mouse
    current_mode = .fps;
    relative_mouse_active = true;
    _ = engine.window.setRelativeMouse(true);

    // Emit initialization event
    engine.events.emit(100, 0, [_]f32{ 0, 0, 0, 0 }, "scene_ready");
}

var gameplay_entities_spawned: bool = false;
var jump_pad_id: u64 = JUMP_PAD_ENTITY_ID;

fn spawnGameplayEntities() void {
    if (gameplay_entities_spawned) return;
    gameplay_entities_spawned = true;

    // 7. Gravitational Jump Pad Platform (Entity 6)
    jump_pad_id = engine.spawnEntity(@intFromEnum(engine.PrimitiveType.cylinder), JUMP_PAD_POS, [_]f32{ 0.15, 0.9, 1.0, 1.0 });
    engine.setEntityLocalScale(jump_pad_id, engine.Vec3.init(1.8, 0.15, 1.8));
    engine.setEntityMaterial(jump_pad_id, 0.0, 0.2, 2.5, 1); // Emissive cyan neon jump disc
    engine.setEntityTag(jump_pad_id, "jump_pad");
    engine.setEntityMotionType(jump_pad_id, .static);

    // 8. Collectible Energy Coins (Entities 7..14)
    for (&energy_cores) |*core| {
        core.entity_id = engine.spawnEntity(@intFromEnum(engine.PrimitiveType.cylinder), core.position, core.color);
        engine.setEntityLocalScale(core.entity_id, engine.Vec3.init(0.65, 0.18, 0.65));
        engine.setEntityMaterial(core.entity_id, 0.85, 0.15, 1.8, 0); // Polished metallic + emissive coin
        engine.setEntityTag(core.entity_id, "energy_coin");
        engine.setEntityMotionType(core.entity_id, .kinematic);
    }
}

/// Called every frame tick by the engine runtime.
export fn on_update(dt: f32) void {
    spawnGameplayEntities();

    // Step all registered UGC ECS systems
    engine.ecs.step(dt);
    // 1. Direct zero-overhead memory reads via World view
    const world = engine.getWorld();
    const t = world.getTime();

    // 2. Query player state with zero-overhead typed view & enqueue steering intent
    if (world.getPlayer(0)) |player| {
        const vel = player.getVelocity();
        if (vel.x > 0.01) {
            engine.applyImpulse(0, engine.Vec3.init(0.5 * dt, 0.0, 0.0));
        }
    }

    // 3. Format and log current engine time using a stack buffer (no dynamic heap allocation)

    // 4. Idle scene rotation and face color pulse (preserves automated test suite invariants)
    engine.scene.rotate(0.35 * dt, 0.70 * dt);
    // engine.scene.setCameraDistance(3.6 + 0.5 * engine.math.sin(t * 1.5));
    // const pulse = 0.5 + 0.5 * engine.math.sin(t * 3.0);
    // engine.scene.setFaceColor(0, pulse, 0.55, 1.0 - pulse);

    // 5. Dynamic Showcase Animation: Orbiting Chrome Sphere (Entity 1)
    // const orbit_radius: f32 = 1.8;
    // const orbit_speed: f32 = 1.2;
    // const orbit_x = engine.math.cos(t * orbit_speed) * orbit_radius;
    // const orbit_z = engine.math.sin(t * orbit_speed) * orbit_radius;
    // const orbit_y = 0.2 + 0.25 * engine.math.sin(t * 2.4);
    // engine.setEntityLocalPosition(1, engine.Vec3.init(orbit_x, orbit_y, orbit_z));

    // Rotate Gold Pyramid (Entity 2)
    engine.setEntityLocalRotation(2, engine.Vec3.init(0.0, t * 0.8, 0.0));

    // Pulse Neon Cylinder (Entity 3) emissive glow
    const glow_pulse = 1.5 + 1.2 * engine.math.sin(t * 3.0);
    engine.setEntityMaterial(3, 0.0, 1.0, glow_pulse, 1);

    // Pulse Jump Pad (Entity 6) emissive glow
    const jump_pad_pulse = 2.0 + 1.2 * engine.math.sin(t * 4.0);
    engine.setEntityMaterial(JUMP_PAD_ENTITY_ID, 0.0, 0.2, jump_pad_pulse, 1);

    // Animate Collectible Coins (Entities 7..10: Hovering bob and vertical spin)
    for (&energy_cores, 0..) |*core, idx| {
        if (!core.collected) {
            const bob = 0.10 * engine.math.sin(t * 3.5 + @as(f32, @floatFromInt(idx)) * 1.5);
            const cur_pos = engine.Vec3.init(core.position.x, core.position.y + 0.20 + bob, core.position.z);
            engine.setEntityLocalPosition(core.entity_id, cur_pos);
            engine.setEntityLocalRotation(core.entity_id, engine.Vec3.init(0.35, t * 2.8 + @as(f32, @floatFromInt(idx)), 0.0));
        } else {
            engine.setEntityLocalScale(core.entity_id, engine.Vec3.init(0.0, 0.0, 0.0));
        }
    }

    // 6. Physics Simulation: Genuine Jolt Physics Rigid Body Integration
    // if (has_jolt_physics and jolt_sphere_id != 0) {
    //     const phys_pos = engine.physics.getPosition(jolt_sphere_id);
    //     engine.setEntityLocalPosition(4, phys_pos);
    //     if (jolt_ruby_cube_id != 0) {
    //         engine.setEntityLocalPosition(0, engine.physics.getPosition(jolt_ruby_cube_id));
    //     }
    //     if (jolt_gold_pyramid_id != 0) {
    //         engine.setEntityLocalPosition(2, engine.physics.getPosition(jolt_gold_pyramid_id));
    //     }
    //     if (jolt_neon_cylinder_id != 0) {
    //         engine.setEntityLocalPosition(3, engine.physics.getPosition(jolt_neon_cylinder_id));
    //     }
    //     for (spawned_props[0..spawned_prop_count]) |prop| {
    //         engine.setEntityLocalPosition(prop.entity_id, engine.physics.getPosition(prop.body_id));
    //     }
    // }

    // ---------------------------------------------------------------------------------------------
    // Input Handling & Actions
    // ---------------------------------------------------------------------------------------------
    const scancode_tab: u32 = 43; // SDL_SCANCODE_TAB
    const scancode_e: u32 = 8; // SDL_SCANCODE_E
    const scancode_q: u32 = 20; // SDL_SCANCODE_Q
    const scancode_c: u32 = 6; // SDL_SCANCODE_C
    const scancode_lctrl: u32 = 224; // SDL_SCANCODE_LCTRL
    const scancode_lshift: u32 = 225; // SDL_SCANCODE_LSHIFT
    const scancode_space: u32 = 44; // SDL_SCANCODE_SPACE

    const key_tab = engine.input.isKeyDown(scancode_tab);
    const key_e = engine.input.isKeyDown(scancode_e) or engine.input.isActionPressed(.interact);
    const key_q = engine.input.isKeyDown(scancode_q);
    const key_crouch = engine.input.isKeyDown(scancode_c) or engine.input.isKeyDown(scancode_lctrl) or engine.input.isActionDown(.crouch);

    const key_e_pressed = key_e and !prev_key_e;
    // const key_q_pressed = key_q and !prev_key_q;
    prev_key_e = key_e;
    prev_key_q = key_q;

    if (key_tab and !prev_key_tab) {
        relative_mouse_active = !relative_mouse_active;
        _ = engine.window.setRelativeMouse(relative_mouse_active);
    }

    prev_key_tab = key_tab;

    const screen_w = engine.window.getScreenWidth();
    const screen_h = engine.window.getScreenHeight();
    const mouse_dx = engine.input.getMouseDx();
    const mouse_dy = engine.input.getMouseDy();
    const mouse_l_down = engine.input.isMouseDown(1) or engine.input.isActionDown(.primary_fire);
    const mouse_l_pressed = (mouse_l_down and !prev_mouse_left);

    // Compute Directional Heading
    const fwd_x = @sin(fps_yaw);
    const fwd_z = @cos(fps_yaw);
    const rgt_x = -@cos(fps_yaw);
    const rgt_z = @sin(fps_yaw);

    // Execute Mode-Specific Gameplay Logic & Cameras
    // First-person mouse look
    if (relative_mouse_active) {
        fps_yaw -= mouse_dx * 0.0022;
        fps_pitch -= mouse_dy * 0.0022;
        const max_pitch = 1.52; // ~87 deg
        fps_pitch = math.clamp(fps_pitch, -max_pitch, max_pitch);
    }

    // Crouch Transition
    if (key_crouch) {
        current_eye_height += (EYE_HEIGHT_CROUCH - current_eye_height) * 12.0 * dt;
    } else {
        current_eye_height += (EYE_HEIGHT_STAND - current_eye_height) * 12.0 * dt;
    }

    // Sprinting & Stamina Regeneration
    const wants_sprint = (engine.input.isActionDown(.sprint) or engine.input.isKeyDown(scancode_lshift)) and !key_crouch;
    const is_moving = engine.input.isActionDown(.move_forward) or engine.input.isActionDown(.move_backward) or engine.input.isActionDown(.move_left) or engine.input.isActionDown(.move_right);

    if (wants_sprint and is_moving and stamina > 2.0) {
        is_sprinting = true;
        stamina = @max(0.0, stamina - 25.0 * dt);
        target_fov = 74.0;
    } else {
        is_sprinting = false;
        stamina = @min(MAX_STAMINA, stamina + 20.0 * dt);
        target_fov = 65.0;
    }

    // Smooth FOV Breathing
    current_fov += (target_fov - current_fov) * 8.0 * dt;
    // engine.camera.setFov(current_fov);

    // Movement Speed (m/s)
    var move_speed: f32 = 5.2;
    if (key_crouch) {
        move_speed = 2.6;
    } else if (is_sprinting) {
        move_speed = 9.4;
    }

    var move_dir_x: f32 = 0.0;
    var move_dir_z: f32 = 0.0;
    if (engine.input.isActionDown(.move_forward)) {
        move_dir_x += fwd_x;
        move_dir_z += fwd_z;
    }
    if (engine.input.isActionDown(.move_backward)) {
        move_dir_x -= fwd_x;
        move_dir_z -= fwd_z;
    }
    if (engine.input.isActionDown(.move_right)) {
        move_dir_x += rgt_x;
        move_dir_z += rgt_z;
    }
    if (engine.input.isActionDown(.move_left)) {
        move_dir_x -= rgt_x;
        move_dir_z -= rgt_z;
    }

    const move_len = @sqrt(move_dir_x * move_dir_x + move_dir_z * move_dir_z);
    if (move_len > 0.001) {
        fps_pos.x += (move_dir_x / move_len) * move_speed * dt;
        fps_pos.z += (move_dir_z / move_len) * move_speed * dt;

        const ARENA_BOUND: f32 = 38.0;

        fps_pos.x = math.clamp(fps_pos.x, -ARENA_BOUND, ARENA_BOUND);
        fps_pos.z = math.clamp(fps_pos.z, -ARENA_BOUND, ARENA_BOUND);

        // Procedural Head Bobbing & Footsteps
        if (is_grounded) {
            const step_rate: f32 = if (is_sprinting) 13.5 else 8.5;
            head_bob_timer += dt * step_rate;
            footstep_timer += dt * step_rate;
            if (footstep_timer >= std.math.pi) {
                footstep_timer -= std.math.pi;
                const step_freq: f32 = if (is_sprinting) 140.0 else 115.0;
                engine.audio.playTone(step_freq, 0.035, 0.18);
            }
        }
    } else {
        head_bob_timer = 0.0;
    }

    // Vertical Humanoid Physics: Jumping against Gravity
    if (is_grounded and (engine.input.isActionPressed(.jump) or engine.input.isKeyDown(scancode_space))) {
        player_vel_y = JUMP_SPEED;
        is_grounded = false;
        engine.audio.playTone(520.0, 0.07, 0.35);
        engine.events.emit(202, 0, [_]f32{ 0.0, JUMP_SPEED, 0.0, 1.0 }, "player_jump");
    }

    // Gravitational Jump Pad at (0.0, -0.75, 4.0) launches player high
    const jump_pad_dx = fps_pos.x - JUMP_PAD_POS.x;
    const jump_pad_dz = fps_pos.z - JUMP_PAD_POS.z;
    const jump_pad_dist = @sqrt(jump_pad_dx * jump_pad_dx + jump_pad_dz * jump_pad_dz);
    if (jump_pad_dist < 1.4 and is_grounded) {
        player_vel_y = 20.0; // High launch to reach airborne core at 6.5m!
        is_grounded = false;
        engine.audio.playTone(720.0, 0.18, 0.7);
        engine.events.emit(205, 0, [_]f32{ 0, 20.0, 0, 0 }, "jumppad_launch");
        engine.particles.spawnBurst(JUMP_PAD_POS, 50, 5.0, [_]f32{ 0.15, 0.9, 1.0, 1.0 }, 0.3, 1.5);
        engine.log.print("[TECH DEMO] Gravitational Jump Pad launched player!");
    }

    if (!is_grounded) {
        player_vel_y += GRAVITY_FPS * dt;
        fps_pos.y += player_vel_y * dt;
        const floor_limit = FLOOR_Y + current_eye_height;
        if (fps_pos.y <= floor_limit) {
            fps_pos.y = floor_limit;
            if (player_vel_y < -3.0) {
                engine.audio.playImpact(0.35); // Landing impact
            }
            player_vel_y = 0.0;
            is_grounded = true;
        }
    } else {
        fps_pos.y = FLOOR_Y + current_eye_height;
    }

    engine.setEntityLocalPosition(player_entity, fps_pos);
    engine.setEntityLocalRotation(player_entity, engine.Vec3.init(0.0, fps_yaw, 0.0));
    engine.setEntityLocalRotation(camera_parent_entity, engine.Vec3.init(fps_pitch, 0.0, 0.0));

    // Head bob translation
    const bob_scale: f32 = if (is_sprinting) 0.045 else 0.025;
    const bob_y: f32 = if (is_grounded and move_len > 0.001) @sin(head_bob_timer) * bob_scale else 0.0;
    const cam_render_pos = engine.Vec3.init(0, bob_y, 0);

    engine.setEntityLocalPosition(camera_parent_entity, cam_render_pos);

    // engine.camera.setRotation(fps_yaw, fps_pitch);

    // Collectible Energy Cores Proximity Detection
    for (&energy_cores, 0..) |*core, idx| {
        if (!core.collected) {
            const cdx = fps_pos.x - core.position.x;
            const cdy = fps_pos.y - core.position.y;
            const cdz = fps_pos.z - core.position.z;
            const dist_to_core = @sqrt(cdx * cdx + cdy * cdy + cdz * cdz);
            if (dist_to_core < 1.8) {
                core.collected = true;
                cores_collected_count += 1;
                engine.setEntityLocalScale(core.entity_id, engine.Vec3.init(0.0, 0.0, 0.0));
                engine.audio.playChime(0.9);
                engine.particles.spawnBurst(core.position, 40, 4.0, core.color, 0.25, 1.2);
                engine.events.emit(300 + @as(u32, @intCast(idx)), 0, [_]f32{ core.position.x, core.position.y, core.position.z, 1.0 }, "core_collected");
                engine.log.print("[TECH DEMO] Energy Core secured!");
            }
        }
    }

    // Dash Surge ([E] key)
    if (key_e_pressed and stamina >= 20.0) {
        stamina -= 20.0;
        fps_pos.x += fwd_x * 4.5;
        fps_pos.z += fwd_z * 4.5;
        engine.audio.playTone(680.0, 0.08, 0.5);
        engine.events.emit(210, 0, [_]f32{ fwd_x * 4.5, 0.0, fwd_z * 4.5, 0.0 }, "dash_surge");
    }

    // Dynamic Physics Spawner ([Q] key)
    if (key_q) {
        const spawn_offset = engine.Vec3.init(fwd_x * 2.2, 0.8, fwd_z * 2.2);
        const spawn_pos = fps_pos.add(spawn_offset);

        if (spawned_prop_count < spawned_props.len) {
            const entity_id = engine.spawnEntity(@intFromEnum(engine.PrimitiveType.cube), spawn_pos, [_]f32{ 0.9, 0.55, 0.2, 1.0 });
            if (entity_id != engine.NO_PARENT) {
                // engine.setEntityLocalScale(entity_id, engine.Vec3.init(0.8, 0.8, 0.8));
                engine.setEntityMaterial(entity_id, 0.3, 0.4, 0.0, 0);
                engine.setEntityTag(entity_id, "physics_crate");
                spawned_prop_count += 1;

                const body_id = engine.physics.createBody(entity_id, .box, spawn_pos, true);
                if (body_id != 0) {
                    const result = engine.ecs.set(entity_id, comp_physics_id, .{ .physics_id = body_id, .spawned = true });
                    const is_active = engine.physics.isActive(body_id);

                    engine.log.printf("Body is {s}, {}", .{ if (is_active) "active" else "not active", result });
                } else {
                    engine.log.print("[TECH DEMO] Failed to create Jolt physics body for spawned crate!");
                }
            }
        }

        engine.log.print("[TECH DEMO] Spawned dynamic Jolt physics crate!");
    }

    const cx = screen_w * 0.5;
    const cy = screen_h * 0.5;

    // Kinetic Pulse Shooting on Left Mouse Click ([LMB])
    if (mouse_l_pressed) {
        engine.audio.playImpact(0.85);
        if (engine.camera.screenToRay(cx, cy, screen_w, screen_h)) |ray| {
            if (engine.physics.castRay(ray.origin, ray.direction.scale(60.0))) |hit| {
                engine.log.printf("Hit body: {d} @ {d} {d} {d}", .{ hit.body_id, hit.position.x, hit.position.y, hit.position.z });
                engine.log.printf("Jolt floor ID: {d}", .{jolt_floor_id});

                const camt = engine.ecs.queryCount(&[_]engine.ecs.ComponentId{comp_physics_id});
                const cbuffer = std.heap.wasm_allocator.alloc(u64, camt) catch {
                    engine.log.print("Ran out of memory!");
                    return;
                };
                defer std.heap.wasm_allocator.free(cbuffer);
                _ = engine.ecs.query(&[_]engine.ecs.ComponentId{comp_physics_id}, cbuffer);

                for (cbuffer) |value| {
                    if (engine.ecs.get(value, comp_physics_id, UgcPhysicsComponent)) |phys| {
                        if (phys.physics_id == hit.body_id) {
                            engine.log.printf("found match! body: {d}, entity: {d}", .{ phys.physics_id, value });
                            if (world.getEntity(value)) |ent| {
                                engine.log.print(ent.getTag());
                            }

                            engine.physics.applyImpulse(phys.physics_id, ray.direction.scale(10000.0));
                        }
                    }
                }

                // if (hit.body_id != jolt_floor_id and hit.body_id != 0) {
                //     engine.physics.applyImpulse(hit.body_id, engine.Vec3.init(
                //         ray.direction.x * 4000.0,
                //         ray.direction.y * 4000.0 + 1200.0,
                //         ray.direction.z * 4000.0,
                //     ));
                //     engine.audio.playTone(320.0, 0.08, 0.4);

                //     // engine.events.emit(201, hit.body_id, [_]f32{ hit.position.x, hit.position.y, hit.position.z, hit.fraction }, "physics_pulse");
                // }
            }
        }
    }

    prev_mouse_left = mouse_l_down;

    // ---------------------------------------------------------------------------------------------
    // Draw 2D HUD Overlays from Script via Host UI API
    // ---------------------------------------------------------------------------------------------
    fps_timer += dt;
    fps_frames += 1;
    if (fps_timer >= 0.5) {
        fps_current = @intFromFloat(@as(f32, @floatFromInt(fps_frames)) / fps_timer);
        fps_frames = 0;
        fps_timer = 0.0;
    }

    // Proportional UI Scaling & Responsive Layout
    // Base resolution: 1280x720. Scale dynamically with window dimensions.
    const ui_scale = std.math.clamp(@min(screen_w / 1280.0, screen_h / 720.0), 0.75, 1.30);
    const font_title = 14.0 * ui_scale;
    const font_small = 11.0 * ui_scale;

    // Diagnostics Telemetry (Right-Aligned)
    var fps_buf: [32]u8 = undefined;
    const fps_text = std.fmt.bufPrint(&fps_buf, "FPS: {d}; ENT: {d}", .{ fps_current, world.getEntityCount() }) catch "...";
    engine.ui.drawText(fps_text, screen_w - screen_w / 2.0 * ui_scale, 10.0 * ui_scale, font_title, .{ 0.3, 1.0, 0.4, 0.95 });

    // Status Bars (Vitality & Stamina) anchored to Bottom-Left
    const bar_w = std.math.clamp(180.0 * ui_scale, 130.0, 210.0);
    const bar_h = 13.0 * ui_scale;
    const bar_x = 16.0;

    engine.ui.drawText("VITALITY: 100 / 100", bar_x, screen_h - 72.0 * ui_scale, font_small, .{ 0.85, 0.95, 0.85, 0.9 });
    engine.ui.drawProgressBar(bar_x, screen_h - 58.0 * ui_scale, bar_w, bar_h, 1.0, .{ 0.2, 0.85, 0.35, 1.0 }, .{ 0.15, 0.2, 0.18, 0.8 });

    var stam_buf: [32]u8 = undefined;
    const stam_text = std.fmt.bufPrint(&stam_buf, "STAMINA: {d:.0}%", .{stamina}) catch "STAMINA";
    engine.ui.drawText(stam_text, bar_x, screen_h - 42.0 * ui_scale, font_small, .{ 0.7, 0.9, 1.0, 0.9 });
    const stam_frac = stamina / MAX_STAMINA;
    engine.ui.drawProgressBar(bar_x, screen_h - 28.0 * ui_scale, bar_w, bar_h, stam_frac, .{ 0.15, 0.7, 0.95, 1.0 }, .{ 0.15, 0.18, 0.22, 0.8 });
}

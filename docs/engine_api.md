# Engine API Documentation (`engine_api.zig`)

Comprehensive API reference and architectural guide for **WebAssembly Guest Scripting** and **Native Engine Host Interoperability** in the Zig 3D Game Engine.

---

## 📑 Table of Contents

- [1. Architectural Overview](#1-architectural-overview)
  - [Engine vs. Game Separation](#engine-vs-game-separation)
  - [Two Sides of `engine_api.zig`](#two-sides-of-engine_apizig)
  - [Shared Memory & Dual-Mapped Memory Model](#shared-memory--dual-mapped-memory-model)
  - [Authoritative Outbox Intent Queue](#authoritative-outbox-intent-queue)
- [2. C-ABI Data Layout & Core Types](#2-c-abi-data-layout--core-types)
  - [Math Primitives (`Vec3`, `Vec4`)](#math-primitives-vec3-vec4)
  - [Constants & Buffer Capacity](#constants--buffer-capacity)
  - [Bitmasks & Enumerations](#bitmasks--enumerations)
  - [Authoritative State Structures](#authoritative-state-structures)
- [3. Guest Zero-Overhead Read Views](#3-guest-zero-overhead-read-views)
  - [`World`](#world)
  - [`PlayerView`](#playerview)
  - [`EntityView`](#entityview)
  - [`SceneView`](#sceneview)
- [4. Guest Mutation API (Outbox Intents)](#4-guest-mutation-api-outbox-intents)
  - [Player & Entity Manipulation](#player--entity-manipulation)
  - [Scene Graph & Transform Hierarchy](#scene-graph--transform-hierarchy)
  - [Materials, Shading & Colors](#materials-shading--colors)
  - [Event Dispatching](#event-dispatching)
  - [Particle Emitter & Bursts](#particle-emitter--bursts)
- [5. Guest Subsystem Namespaces](#5-guest-subsystem-namespaces)
  - [`camera`](#camera)
  - [`input`](#input)
  - [`physics`](#physics)
  - [`character`](#character)
  - [`constraint`](#constraint)
  - [`particles`](#particles)
  - [`ui`](#ui)
  - [`audio`](#audio)
  - [`window`](#window)
  - [`net`](#net)
  - [`task`](#task)
  - [`ecs` (Dynamic Components & Systems)](#ecs-dynamic-components--systems)
  - [`scene`](#scene)
  - [`events`](#events)
  - [`time` & `math` & `log`](#time--math--log)
- [6. Host Engine Implementation (`src/engine/scripting/engine_api.zig`)](#6-host-engine-implementation-srcenginescriptingengine_apizig)
  - [`EngineContext`](#enginecontext)
  - [`postTickReconcile(dt)`](#posttickreconciledt)
  - [`ScriptManager` & Multi-Script Isolation](#scriptmanager--multi-script-isolation)
  - [`TaskScheduler` (Host Task Engine)](#taskscheduler-host-task-engine)
  - [Dynamic Flecs ECS Host Bridge](#dynamic-flecs-ecs-host-bridge)
  - [Native WAMR Symbol Registration](#native-wamr-symbol-registration)
- [7. Script Lifecycle & Usage Examples](#7-script-lifecycle--usage-examples)
  - [Script Entrypoints (`init`, `update`)](#script-entrypoints-init-update)
  - [Example: FPS Character Controller](#example-fps-character-controller)
  - [Example: Roblox-Style Humanoid Character Controller](#example-roblox-style-humanoid-character-controller)
  - [Example: RTS Unit Raycasting & UI HUD](#example-rts-unit-raycasting--ui-hud)
  - [Example: Multiplayer Networking & RemoteEvents](#example-multiplayer-networking--remoteevents)
  - [Example: Multi-Script UGC Execution & Task Scheduling](#example-multi-script-ugc-execution--task-scheduling)
  - [Example: UGC Dynamic Components and Systems](#example-ugc-dynamic-components-and-systems)

---

## 1. Architectural Overview

### Engine vs. Game Separation

The game engine enforces a **strict architectural boundary** between generic host infrastructure and gameplay logic:

| Component | Directory | Responsibility |
| :--- | :--- | :--- |
| **Engine Host** | `src/`, `src/engine/` | Generic graphics (WebGPU), physics (Jolt), ECS (Flecs), audio (SDL3), windowing, memory protection, and WASM runtime hosting. Contains **zero game rules or gameplay modes**. |
| **Guest Scripts** | `scripts/` | All gameplay mechanics, camera modes (FPS, TPS, RTS), player controls, unit behaviors, pathfinding, scoring, combat, and HUD. |

### Two Sides of `engine_api.zig`

There are two files named `engine_api.zig` that mirror each other:

1. **Guest SDK (`scripts/engine_api.zig`)**:
   - Compiled to `wasm32-freestanding`.
   - Imported by user scripts and modders (`const engine = @import("engine_api.zig");`).
   - Maps shared linear memory into ergonomic, zero-overhead read views (`World`, `EntityView`, `PlayerView`).
   - Declares `extern "engine"` host function imports for intent dispatching.

2. **Host Bridge (`src/engine/scripting/engine_api.zig`)**:
   - Compiled as native Zig into the host executable.
   - Binds WAMR/Wasm3 native symbols to engine subsystems (`PhysicsWorld`, `Scene`, `Camera`, `UiRenderer`, `AudioEngine`, `Flecs`).
   - Validates incoming parameters and enqueues intents into the `OutboxQueue`.

```
┌────────────────────────────────────────────────────────────────────────┐
│                        NATIVE ENGINE HOST                              │
│   src/engine/scripting/engine_api.zig                                  │
│   • Manages EngineContext (Jolt, Flecs, WGPU, SDL3, Window)           │
│   • Reconciles outbox post-tick & synchronizes GameState               │
└───────────────────▲───────────────────────────────────────┬────────────┘
                    │                                       │ Zero-Copy Shared Buffer
                    │ Host Function Calls / Outbox Intents  │ (512 KB Dual-Mapped)
                    │                                       │
┌───────────────────┴───────────────────────────────────────▼────────────┐
│                    WASM SCRIPT (GUEST SDK)                             │
│   scripts/engine_api.zig                                               │
│   • Reads: World.init(), getPlayer(), getEntity(), getInput()          │
│   • Mutates: applyImpulse(), spawnEntity(), setEntityLocalPosition()   │
└────────────────────────────────────────────────────────────────────────┘
```

### Shared Memory & Dual-Mapped Memory Model

- State is laid out in an authoritative `GameState` struct.
- The guest exports a 512 KB aligned buffer (`shared_memory_buffer: [524288]u8 align(4096)`).
- On platforms with MMU dual-mapping, the physical pages are mapped into both host address space and guest linear memory.
- **Direct Reads**: The guest reads `GameState` directly through typed pointers with **zero function call overhead** and **zero serialization penalty**.

### Authoritative Outbox Intent Queue

To prevent untrusted scripts from causing memory corruption or violating simulation determinism:
- The guest **never directly writes** to authoritative host simulation memory.
- State mutation functions (such as `applyImpulse` or `spawnEntity`) enqueue commands into an **Outbox Intent Queue**.
- At the end of the tick, the host's `postTickReconcile(dt)` processes the queue, validates transforms and physics parameters, applies changes to Flecs ECS and Jolt Physics, and updates the shared memory view for the next tick.

---

## 2. C-ABI Data Layout & Core Types

All types shared between host and guest are defined with `extern struct` or `enum(u32)` to guarantee exact memory alignment and C-ABI compatibility.

### Math Primitives (`Vec3`, `Vec4`)

```zig
pub const Vec3 = extern struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    z: f32 = 0.0,

    pub fn init(x: f32, y: f32, z: f32) Vec3;
    pub fn add(self: Vec3, other: Vec3) Vec3;
    pub fn sub(self: Vec3, other: Vec3) Vec3;
    pub fn scale(self: Vec3, s: f32) Vec3;
    pub fn mul(self: Vec3, other: Vec3) Vec3;
    pub fn lengthSq(self: Vec3) f32;
    pub fn length(self: Vec3) f32;
    pub fn distance(self: Vec3, other: Vec3) f32;
};

pub const Vec4 = extern struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    z: f32 = 0.0,
    w: f32 = 1.0,

    pub fn init(x: f32, y: f32, z: f32, w: f32) Vec4;
};
```

### Constants & Buffer Capacity

```zig
pub const MAX_PLAYERS: u32 = 32;          // Max concurrent player slots
pub const MAX_ENTITIES: u32 = 2048;       // Max active entities in world pool
pub const MAX_AXES: u32 = 8;              // Max analog controller/mouse axes
pub const MAX_SHARED_EVENTS: u32 = 16;    // Max events stored in the shared ring buffer
pub const NO_PARENT: u32 = 0xFFFF_FFFF;   // Sentinel ID indicating entity has no parent
```

### Bitmasks & Enumerations

#### ComponentMask
Archetype mask tracking active ECS components on an entity:
```zig
pub const ComponentMask = struct {
    pub const ACTIVE: u32     = 1 << 0;
    pub const TRANSFORM: u32  = 1 << 1;
    pub const RIGID_BODY: u32 = 1 << 2;
    pub const COLLIDER: u32   = 1 << 3;
    pub const RENDERABLE: u32 = 1 << 4;
    pub const SCRIPTED: u32   = 1 << 5;
};
```

#### ColliderType
```zig
pub const ColliderType = enum(u32) {
    none = 0,
    box = 1,
    sphere = 2,
    capsule = 3,
};
```

#### MotionType
Matches Jolt Physics motion types:
```zig
pub const MotionType = enum(u32) {
    dynamic = 0,   // Full simulation, affected by forces/gravity
    kinematic = 1, // Velocity-driven, unaffected by external forces
    static = 2,    // Fixed in world, infinite mass
};
```

#### PrimitiveType & ShadingModel
```zig
pub const PrimitiveType = enum(u32) {
    cube = 0,
    sphere = 1,
    pyramid = 2,
    cylinder = 3,
    plane = 4,
};

pub const ShadingModel = enum(u32) {
    pbr = 0,         // Cook-Torrance standard PBR
    unlit = 1,       // Emissive / unshaded
    blinn_phong = 2, // Classic specular highlight
};
```

#### ActionId & AxisId
Semantic input abstractions mapped from keyboard, mouse, and gamepads:
```zig
pub const ActionId = enum(u5) {
    move_forward = 0,
    move_backward = 1,
    move_left = 2,
    move_right = 3,
    jump = 4,
    sprint = 5,
    crouch = 6,
    interact = 7,
    primary_fire = 8,
    secondary_fire = 9,
    pause = 10,
    reload = 11,
    custom0 = 12,
    custom1 = 13,
    custom2 = 14,
    custom3 = 15,
};

pub const AxisId = enum(u3) {
    move_x = 0,
    move_y = 1,
    look_x = 2,
    look_y = 3,
    trigger_left = 4,
    trigger_right = 5,
    wheel = 6,
    custom0 = 7,
};
```

### Authoritative State Structures

#### `WorldHeader`
Metadata tracking simulation timing and entity counts:
```zig
pub const WorldHeader = extern struct {
    magic: u32 = 0x574F524C, // 'WORL'
    version: u32 = 2,
    tick: u64 = 0,
    time: f32 = 0.0,
    delta_time: f32 = 0.0,
    player_count: u32 = 0,
    max_players: u32 = MAX_PLAYERS,
    entity_count: u32 = 0,
    max_entities: u32 = MAX_ENTITIES,
};
```

#### `EntityData`
Complete 128-byte aligned representation of a world entity:
```zig
pub const EntityData = extern struct {
    id: u32 = 0,
    active: u32 = 0,
    parent_id: u32 = NO_PARENT,
    component_mask: u32 = ComponentMask.ACTIVE | ComponentMask.TRANSFORM,
    entity_type: u32 = 0,
    shading_model: u32 = 0,

    // World Transforms (Authoritative result after hierarchy resolve)
    position: Vec3 = .{},
    _pad1: f32 = 0,
    rotation: Vec3 = .{},
    _pad2: f32 = 0,
    scale: Vec3 = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
    _pad3: f32 = 0,

    // Local Hierarchy Transforms (Relative to parent_id)
    local_position: Vec3 = .{},
    _pad4: f32 = 0,
    local_rotation: Vec3 = .{},
    _pad5: f32 = 0,
    local_scale: Vec3 = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
    _pad6: f32 = 0,

    // Dynamics (Jolt Physics integration)
    velocity: Vec3 = .{},
    mass: f32 = 1.0,
    angular_velocity: Vec3 = .{},
    motion_type: MotionType = .dynamic,

    // Colliders
    collider_type: ColliderType = .none,
    collider_extents: Vec3 = .{ .x = 0.5, .y = 0.5, .z = 0.5 },

    // Visuals & Tagging
    color: [4]f32 = [_]f32{ 1.0, 1.0, 1.0, 1.0 },
    tag: [16]u8 = [_]u8{0} ** 16,
    layer: u32 = 0,
    metallic: f32 = 0.0,
    roughness: f32 = 0.5,
    emissive: f32 = 0.0,
    _pad7: [2]u32 = [_]u32{0} ** 2,
};
```

#### `GameState`
The root shared memory layout:
```zig
pub const GameState = extern struct {
    header: WorldHeader = .{},
    scene: SceneState = .{},
    input: InputStateShared = .{},
    events: EventQueueShared = .{},
    players: [MAX_PLAYERS]PlayerData = [_]PlayerData{.{}} ** MAX_PLAYERS,
    entities: [MAX_ENTITIES]EntityData = [_]EntityData{.{}} ** MAX_ENTITIES,
};
```

---

## 3. Guest Zero-Overhead Read Views

Guest scripts read engine state via thin, non-owning view wrappers that reference the shared memory buffer directly.

### `World`
Obtained via `engine.getWorld()` or `engine.World.init()`.

| Method | Return Type | Description |
| :--- | :--- | :--- |
| `getPlayer(id: u32)` | `?PlayerView` | Returns active player view by ID if active, else `null`. |
| `getEntity(id: u32)` | `?EntityView` | Returns active entity view by ID if active, else `null`. |
| `findEntityByTag(tag: []const u8)` | `?EntityView` | Scans entity pool and returns first active entity matching tag. |
| `getScene()` | `SceneView` | Accesses global scene state (cube colors, default rotations). |
| `getInput()` | `*const InputStateShared` | Direct pointer to input state (actions, axes, mouse deltas). |
| `getEvents()` | `[]const GameEvent` | Slice of all events dispatched during the current frame. |
| `getTick()` | `u64` | Current engine frame/tick count. |
| `getTime()` | `f32` | Elapsed engine time in seconds. |
| `getDeltaTime()` | `f32` | Frame delta time in seconds. |
| `getPlayerCount()` | `u32` | Number of currently active players. |
| `getEntityCount()` | `u32` | Number of currently active entities. |

### `PlayerView`
Wraps a pointer to an active `PlayerData`.

| Method | Return Type | Description |
| :--- | :--- | :--- |
| `getId()` | `u32` | Player identifier. |
| `isActive()` | `bool` | Whether the player slot is currently active. |
| `getPosition()` | `Vec3` | World position. |
| `getVelocity()` | `Vec3` | Linear velocity vector. |
| `getRotation()` | `Vec3` | Euler rotation angles. |
| `getHealth()` | `f32` | Current health points. |
| `getMaxHealth()` | `f32` | Maximum health points. |

### `EntityView`
Wraps a pointer to an active `EntityData`.

#### Identity & Hierarchy
- `getId() u32`: Entity index.
- `isActive() bool`: Active status flag.
- `getType() u32`: Entity archetype/type ID.
- `getParentId() u32`: Parent entity ID, or `NO_PARENT`.
- `hasParent() bool`: `true` if entity has an assigned parent.

#### Transforms
- `getPosition() Vec3` / `getWorldPosition() Vec3`: Authoritative world space position.
- `getRotation() Vec3` / `getWorldRotation() Vec3`: Authoritative world space Euler rotation.
- `getScale() Vec3` / `getWorldScale() Vec3`: Authoritative world space scale.
- `getLocalPosition() Vec3`: Position relative to parent.
- `getLocalRotation() Vec3`: Rotation relative to parent.
- `getLocalScale() Vec3`: Scale relative to parent.

#### Physics & Colliders
- `getVelocity() Vec3`: Linear velocity.
- `getAngularVelocity() Vec3`: Angular velocity.
- `getMass() f32`: Mass in kilograms.
- `getMotionType() MotionType`: `.dynamic`, `.kinematic`, or `.static`.
- `isDynamic() bool`: Checks if body is dynamic.
- `isKinematic() bool`: Checks if body is kinematic.
- `isStatic() bool`: Checks if body is static.
- `getColliderType() ColliderType`: `.none`, `.box`, `.sphere`, or `.capsule`.
- `getColliderExtents() Vec3`: Half-extents or radii of collider.

#### Visuals & Metadata
- `getColor() [4]f32`: RGBA color array `[r, g, b, a]`.
- `getMetallic() f32`: Metallic PBR factor `[0.0, 1.0]`.
- `getRoughness() f32`: Roughness PBR factor `[0.0, 1.0]`.
- `getEmissive() f32`: Emissive intensity multiplier.
- `getShadingModel() u32`: Shading model index (0 = PBR, 1 = Unlit, 2 = Blinn-Phong).
- `getTag() []const u8`: String tag slice (up to 16 bytes).
- `hasTag(tag: []const u8) bool`: Tag equality check.

#### Built-in Intent Shortcuts on `EntityView`
Convenience methods that enqueue Outbox intents directly on the viewed entity:
```zig
view.setLocalPosition(pos);
view.setLocalRotation(rot);
view.setLocalScale(scale);
view.setParent(parent_id);
view.applyImpulse(impulse);
view.setCollider(col_type, extents);
view.setMaterial(metallic, roughness, emissive, shading_model);
view.setColor(.{ 1.0, 0.0, 0.0, 1.0 });
view.setTag("enemy");
view.despawn();
```

### `SceneView`
Wraps `SceneState`.

- `getRotationX() f32`: Scene X rotation.
- `getRotationY() f32`: Scene Y rotation.
- `getCameraDistance() f32`: Camera orbital radius.
- `getFaceColor(face: u32) [4]f32`: RGBA color of a specific cube face (0 to 5).

---

## 4. Guest Mutation API (Outbox Intents)

Guest scripts mutate engine state by calling outbox intent dispatchers. These functions record commands that are dispatched to the host engine.

### Player & Entity Manipulation

```zig
// Apply a directional physics impulse vector to a player
pub fn applyImpulse(player_id: u32, impulse: Vec3) void;

// Apply a physics impulse vector to any entity
pub fn applyEntityImpulse(entity_id: u32, impulse: Vec3) void;

// Directly set a player's linear velocity vector
pub fn setPlayerVelocity(player_id: u32, vel: Vec3) void;

// Teleport player immediately to world coordinates
pub fn teleportPlayer(player_id: u32, pos: Vec3) void;

// Spawn a new entity of given type, world position, and RGBA color
pub fn spawnEntity(entity_type: u32, pos: Vec3, color: [4]f32) void;

// Despawn an entity by ID
pub fn despawnEntity(entity_id: u32) void;
```

### Scene Graph & Transform Hierarchy

```zig
// Set local position relative to parent
pub fn setEntityLocalPosition(entity_id: u32, pos: Vec3) void;

// Set local Euler rotation relative to parent
pub fn setEntityLocalRotation(entity_id: u32, rot: Vec3) void;

// Set local scale relative to parent
pub fn setEntityLocalScale(entity_id: u32, scale: Vec3) void;

// Attach child entity to a parent (or NO_PARENT to detach to root)
pub fn setEntityParent(child_id: u32, parent_id: u32) void;

// Configure Jolt collision shape and dimensions
pub fn setEntityCollider(entity_id: u32, col_type: ColliderType, extents: Vec3) void;

// Update entity motion type (.dynamic, .kinematic, .static)
pub fn setEntityMotionType(entity_id: u32, motion_type: MotionType) void;

// Set 16-byte identification tag on entity
pub fn setEntityTag(entity_id: u32, tag_str: []const u8) void;
```

### Materials, Shading & Colors

```zig
// Configure PBR material parameters and shading model
pub fn setEntityMaterial(entity_id: u32, metallic: f32, roughness: f32, emissive: f32, shading_model: u32) void;

// Convenience: Configure Cook-Torrance PBR
pub fn setEntityPbr(entity_id: u32, metallic: f32, roughness: f32) void;

// Convenience: Configure unlit emissive material
pub fn setEntityUnlit(entity_id: u32, emissive_intensity: f32) void;

// Set entity tint color
pub fn setEntityColor(entity_id: u32, color: [4]f32) void;
```

### Event Dispatching

```zig
// Emit a custom game event into the event bus
pub fn emitEvent(event_type: u32, source_id: u32, target_id: u32, data: [4]f32, tag_str: []const u8) void;
```

### Particle Emitter & Bursts

```zig
// Spawn a GPU particle burst at a world position
pub fn spawnParticleBurst(pos: Vec3, count: u32, speed: f32, color: [4]f32, size: f32, lifetime: f32) void;
```

---

## 5. Guest Subsystem Namespaces

The guest SDK organizes modular functionality under clean, ergonomic namespaces:

### `camera`
Manipulate and query the active engine camera or perform screen raycasts:

```zig
const cam = engine.camera;

// Set camera position in world space
cam.setPosition(engine.Vec3.init(0.0, 2.0, 5.0));

// Set camera rotation (yaw and pitch in radians)
cam.setRotation(yaw, pitch);

// Set camera field-of-view in degrees
cam.setFov(60.0);

// Query camera coordinates & angles
const pos = cam.getPosition();
const yaw = cam.getYaw();
const pitch = cam.getPitch();

// Unproject screen coordinates into a 3D ray (e.g. mouse cursor picking)
if (cam.screenToRay(mouse_x, mouse_y, screen_w, screen_h)) |ray| {
    // Intersect the ray with an arbitrary horizontal ground plane
    if (ray.intersectPlaneY(0.0)) |ground_hit| {
        // ground_hit is a Vec3 on the plane Y = 0.0
    }
}
```

### `input`
Query keyboard, mouse, and abstract action states:

```zig
const inp = engine.input;

// High-performance zero-copy action queries
if (inp.isActionDown(.move_forward)) { /* Held down */ }
if (inp.isActionPressed(.jump)) { /* Pressed this frame */ }

// Analog axes [-1.0, 1.0]
const move_x = inp.getAxis(.move_x);
const move_y = inp.getAxis(.move_y);

// Mouse state
const mx = inp.getMouseX();
const my = inp.getMouseY();
const dx = inp.getMouseDx();
const dy = inp.getMouseDy();

// Scancode/button low-level fallbacks
if (inp.isKeyDown(scancode)) { ... }
if (inp.isMouseDown(button_idx)) { ... }
```

### `physics`
Direct Jolt Physics rigid body creation, raycasting, shapecasting, and collision layer filtering:

```zig
const phys = engine.physics;

// Spawn a dynamic or static Jolt physics rigid body
const sphere_id = phys.createBody(.sphere, engine.Vec3.init(0, 5, 0), true);

// Apply an impulse vector to the body
phys.applyImpulse(sphere_id, engine.Vec3.init(0, 10, 0));

// Query live physics state
const pos = phys.getPosition(sphere_id);
const vel_y = phys.getVelocityY(sphere_id);
const active = phys.isActive(sphere_id);

// 1. Raycasting against Jolt physics scene
if (phys.castRay(origin, direction)) |hit| {
    // hit.body_id  -> u32
    // hit.position -> Vec3
    // hit.fraction -> f32 (0.0 to 1.0)
}

// 2. Collision Layers & Filtering (Roblox Collision Groups model)
// Layers: .default_static (0), .default_dynamic (1), .debris (2), .character (3), .water (4)
phys.setCollisionLayer(sphere_id, .debris);

// Configure collision mask matrix between layers
phys.setLayerCollidable(.debris, .character, false); // debris passes through characters

// 3. Shapecasting (Sphere & Box Sweeps)
// Sweeps a sphere of given radius from origin along dir (full vector length is sweep distance)
const mask = phys.ALL_LAYERS; // or phys.layerBit(.character) | phys.layerBit(.default_static)
if (phys.castSphere(0.5, origin, direction, mask)) |hit| {
    // hit.body_id  -> u32
    // hit.position -> Vec3 (exact contact point)
    // hit.normal   -> Vec3 (surface contact normal)
    // hit.fraction -> f32 (0.0 to 1.0)
}

// Sweeps an axis-aligned box with half-extents along direction
if (phys.castBox(engine.Vec3.init(0.5, 1.0, 0.5), origin, direction, mask)) |hit| {
    // Exact contact point and surface normal
}
```

### `character`
Jolt `CharacterVirtual` humanoid controller designed for responsive Roblox-grade character physics (slope sliding, stair stepping, and ground snapping):

```zig
const char = engine.character;

// Create a capsule humanoid character centered at pos (half_height=0.5m, radius=0.3m -> total height 1.6m)
const char_id = char.create(engine.Vec3.init(0.0, 2.0, 0.0), 0.5, 0.3);

// Query ground state (.on_ground, .sliding, .in_air)
const ground_state = char.getGroundState(char_id);
if (ground_state == .on_ground) {
    // Ground snapping and stair stepping are automatically handled by Jolt
}

// Set desired linear velocity.
// Note: Pass getVelocityY(id) for vertical velocity to preserve natural airborne gravity/falling
const current_vy = char.getVelocityY(char_id);
const jump_vy: f32 = if (inp.isActionPressed(.jump) and ground_state == .on_ground) 8.0 else current_vy;
char.setLinearVelocity(char_id, engine.Vec3.init(vx, jump_vy, vz));

// Query live character position
const char_pos = char.getPosition(char_id);

// Teleport character immediately
char.setPosition(char_id, engine.Vec3.init(0.0, 10.0, 0.0));

// Destroy character controller when entity despawns
char.destroy(char_id);
```

### `constraint`
Jolt physics constraints and joints connecting pairs of rigid bodies (anchors, swinging doors, elevators, welds, and ragdolls):

```zig
const constraint = engine.constraint;

// 1. Hinge Constraint (doors, wheels, rotating arms)
// body_a (anchor), body_b (swing arm), anchor pos, rotation axis, min limit (rad), max limit (rad)
const hinge_id = constraint.createHinge(
    anchor_id,
    door_id,
    engine.Vec3.init(0, 2, 0),
    engine.Vec3.init(0, 1, 0),
    -1.57, // -90 deg
    1.57   // +90 deg
);

// 2. Ball-and-Socket Joint (pendulums, ragdoll limbs, trailer hitches)
const ball_id = constraint.createBallSocket(pin_id, bob_id, anchor_pos);

// 3. Slider Constraint (pistons, sliding doors, elevators)
// body_a, body_b, slide axis, min travel limit (m), max travel limit (m)
const slider_id = constraint.createSlider(rail_id, elevator_id, engine.Vec3.init(0, 1, 0), 0.0, 10.0);

// 4. Weld Constraint (rigid multi-part assemblies matching Roblox WeldConstraint)
// Rigidly locks two dynamic or static bodies at their current relative transform
const weld_id = constraint.createWeld(base_body, child_body);

// Destroy any constraint
constraint.destroy(hinge_id);
```

### `particles`
GPU instanced quad particle emitter with procedural physics, life-color decay, and outbox reconciliation:

```zig
const particles = engine.particles;

// Spawn an instanced particle burst [pos, count, speed, RGBA, size, lifetime_sec]
particles.spawnBurst(
    hit_pos,
    40,                               // 40 particles
    6.0,                              // emission velocity magnitude
    .{ 1.0, 0.4, 0.1, 1.0 },          // fiery orange
    0.25,                             // particle quad size
    0.75                              // 0.75 second lifetime
);

// Shorthand available at root SDK level:
engine.spawnParticleBurst(impact_pos, 25, 4.0, .{ 0.2, 0.8, 1.0, 1.0 }, 0.2, 0.5);
```

### `ui`
Immediate-mode 2D HUD rendering:

```zig
const ui = engine.ui;

// Draw solid rectangle [x, y, width, height, RGBA]
ui.drawRect(10, 10, 200, 24, .{ 0.1, 0.1, 0.1, 0.8 });

// Draw rectangle border [x, y, width, height, thickness, RGBA]
ui.drawRectBorder(10, 10, 200, 24, 2.0, .{ 1.0, 1.0, 1.0, 1.0 });

// Draw centered crosshair [cx, cy, size, thickness, RGBA]
ui.drawCrosshair(screen_w / 2.0, screen_h / 2.0, 12.0, 2.0, .{ 1, 1, 1, 0.8 });

// Draw progress/health bar [x, y, w, h, frac (0..1), fg_RGBA, bg_RGBA]
ui.drawProgressBar(20, 40, 180, 16, current_hp / max_hp, .{ 0.2, 0.8, 0.2, 1.0 }, .{ 0.3, 0.1, 0.1, 0.8 });

// Draw RTS drag-selection marquee box [x1, y1, x2, y2, fill_RGBA, border_RGBA]
ui.drawSelectionBox(drag_x1, drag_y1, drag_x2, drag_y2, .{ 0.2, 0.6, 1.0, 0.2 }, .{ 0.2, 0.6, 1.0, 0.8 });

// Draw text string [text, x, y, font_size, RGBA]
ui.drawText("HEALTH", 25, 42, 12.0, .{ 1, 1, 1, 1 });
```

### `audio`
Real-time low-latency procedural audio synthesis:

```zig
const audio = engine.audio;

// Synthesize pure sine tone [frequency_hz, duration_sec, volume 0..1]
audio.playTone(440.0, 0.2, 0.5);

// Synthesize impact sound effect (e.g. footstep, landing, collision)
audio.playImpact(0.8);

// Synthesize pleasant chime (e.g. pickup, UI notification, quest completed)
audio.playChime(0.6);
```

### `window`
Platform window management:

```zig
const win = engine.window;

// Lock cursor and enable relative mouse delta mode (true for FPS/TPS, false for RTS/UI)
_ = win.setRelativeMouse(true);

// Get current window dimensions
const width = win.getScreenWidth();
const height = win.getScreenHeight();
```

### `net`
Multiplayer networking, RemoteEvents (Roblox-style RemoteEvent RPC messaging), connection state, latency, and client ID queries:

```zig
const net = engine.net;

// 1. RemoteEvents: Client -> Server RPC
// Sends an event named "RequestSpawn" with string or binary payload to the dedicated server
net.fireServer("RequestSpawn", "character_class=warrior");

// 2. RemoteEvents: Server -> Specific Client RPC
// Sends an event to client slot 3
net.fireClient(3, "UpdateInventory", "{gold:150,items:[2,4,7]}");

// 3. RemoteEvents: Server -> Broadcast All Clients RPC
// Dispatches an event to all currently connected clients
net.fireAllClients("ChatMessage", "[Server]: Round starting in 10 seconds!");

// 4. Polling Incoming RemoteEvents
// Reads next available event from the incoming queue into caller buffers without dynamic allocations
var name_buf: [32]u8 = undefined;
var data_buf: [256]u8 = undefined;

while (net.pollEvent(&name_buf, &data_buf)) |ev| {
    const event_name = name_buf[0..ev.name_len];
    const payload = data_buf[0..ev.data_len];
    const sender_id = ev.sender_id;

    if (std.mem.eql(u8, event_name, "ChatMessage")) {
        // Process chat payload from sender_id
    }
}

// 5. Connection State & Diagnostics
const is_connected = net.isConnected();     // bool: true if connection to server/client is established
const rtt_ms = net.getRtt();                 // f32: smoothed round-trip ping time in milliseconds
const my_client_id = net.getClientId();      // u32: local client slot assigned by server (0 to 31)
```

### `task`
Cooperative task scheduler modeled after Roblox's `task` library:

```zig
const task = engine.task;

// 1. Cooperative Timed Wait
// Yields/polls for 2.5 seconds. Returns 0.0 while waiting, and on the exact resumption frame
// returns the actual elapsed duration (e.g. 2.516s):
const elapsed = task.wait(2.5);
if (elapsed > 0.0) {
    // Exact frame after 2.5 seconds have passed!
    engine.audio.playChime(0.5);
}

// 2. Slot-Indexed Wait
// Supports multiple concurrent wait timers in the same script without state collision:
if (task.waitSlot(1, 10.0) > 0.0) {
    // 10-second recurring cooldown ready
}

// 3. Delayed Execution
// Schedules a callback function to run after 3.0 seconds:
fn onPowerupExpire() void {
    player_speed = 5.0;
}
const task_id = task.delay(3.0, onPowerupExpire);

// 4. Deferred Execution
// Defers callback to execute at the end of the current frame after all main simulation updates:
fn processEndOfFrame() void {
    // Runs after postTickReconcile
}
_ = task.@"defer"(processEndOfFrame);

// 5. Immediate Spawn
// Executes callback in cooperative task scheduler:
task.spawn(myCallback);

// 6. Cancellation
// Cancels a pending or delayed task before execution:
task.cancel(task_id);
```

### `ecs` (Dynamic Components & Systems)

Provides WebAssembly UGC guest scripts with the ability to define custom ECS components (`extern struct`), register them dynamically in the native Flecs ECS world, attach/read/mutate component data on entities, execute multi-component queries, and define/step game systems with delta time:

```zig
const ecs = engine.ecs;

// 1. Define custom UGC component data structures
pub const Health = extern struct {
    hp: f32 = 100.0,
    max_hp: f32 = 100.0,
};

pub const Rotator = extern struct {
    speed: f32 = 2.0,
    angle: f32 = 0.0,
};

// 2. Register components into Flecs (typically during init())
// Returns an authoritative 64-bit component entity ID
const health_id = ecs.register(Health, "Health");
const rotator_id = ecs.register(Rotator, "Rotator");

// Query built-in engine component IDs (Position, Rotation, Scale, Velocity, MeshRender, etc.)
const pos_id = ecs.getBuiltinComponent(.position);
const vel_id = ecs.getBuiltinComponent(.velocity);

// 3. Entity creation & component assignment
const entity = ecs.newEntity("GoblinScout");
_ = ecs.set(entity, health_id, Health{ .hp = 85.0, .max_hp = 100.0 });
_ = ecs.set(entity, rotator_id, Rotator{ .speed = 3.5 });

// Check & retrieve component data
if (ecs.has(entity, health_id)) {
    if (ecs.get(entity, health_id, Health)) |h| {
        // h.hp == 85.0
    }
}

// 4. Multi-Component Queries
var matching_entities: [64]ecs.EntityId = undefined;
const count = ecs.query(&[_]ecs.ComponentId{ rotator_id, pos_id }, &matching_entities);
for (matching_entities[0..count]) |e| {
    // Process entity with both Rotator and Position
}

// 5. Define and Register Systems
// Systems query matching entities and run a callback for each entity (or batch)
const rotator_sys = ecs.registerSystem(
    "RotatorSystem",
    &[_]ecs.ComponentId{ rotator_id },
    struct {
        fn onUpdate(e: ecs.EntityId, dt: f32) void {
            if (ecs.get(e, rotator_id, Rotator)) |rot| {
                var updated = rot;
                updated.angle += updated.speed * dt;
                _ = ecs.set(e, rotator_id, updated);
            }
        }
    }.onUpdate,
);

// 6. Step all registered systems in script update(dt)
ecs.step(dt);

// Toggle or run specific systems on demand
ecs.setSystemEnabled(rotator_sys, false);
ecs.runSystem(rotator_sys, dt);
```

### `scene`
Legacy and global scene properties:

```zig
const scn = engine.scene;

scn.rotate(delta_x, delta_y);
scn.setRotationX(rot_x);
scn.setRotationY(rot_y);
scn.setCameraDistance(dist);
scn.setFaceColor(face_index, r, g, b);
```

### `events`
Shared event stream:

```zig
// Read incoming events
for (engine.events.get()) |ev| {
    std.debug.print("Event {d} from {d} tag={s}\n", .{ ev.event_type, ev.source_id, ev.getTag() });
}

// Dispatches an event
engine.events.emit(EVENT_HIT, target_id, .{ damage, 0, 0, 0 }, "bullet_hit");
```

### `time` & `math` & `log`

```zig
// Time queries
const current_time = engine.time.get();
const dt = engine.time.getDelta();

// Math helpers
const s = engine.math.sin(1.57);
const c = engine.math.cos(0.0);
const sq = engine.math.sqrt(16.0);

// Host logging output
engine.log.print("Initialization successful!");
```

---

## 6. Host Engine Implementation (`src/engine/scripting/engine_api.zig`)

The host side coordinates native subsystems and bridges them to the WebAssembly execution environment.

### `EngineContext`
Holds native subsystem pointers during a script execution:

```zig
pub const EngineContext = struct {
    scene: *Scene,
    camera: ?*Camera = null,
    input: ?*const InputState = null,
    physics: ?*PhysicsWorld = null,
    audio: ?*AudioEngine = null,
    ui: ?*UiRenderer = null,
    window: ?*Window = null,
    ecs: ?*EcsWorld = null,
    particles: ?*ParticleSystem = null,
    remote_events: ?*RemoteEventManager = null,
    task_scheduler: ?*TaskScheduler = null,
    is_server: bool = false,
    client_id: u32 = 0,
    rtt_ms: f32 = 0.0,
    is_connected: bool = false,
    time: f32 = 0.0,
    delta_time: f32 = 0.0,

    // Raycast & shapecast caching
    last_ray_hit_body: u32 = 0,
    last_ray_hit_pos: [3]f32 = .{ 0.0, 0.0, 0.0 },
    last_ray_hit_fraction: f32 = 0.0,
    last_ray_hit_normal: [3]f32 = .{ 0.0, 0.0, 0.0 },
    last_ray_origin: [3]f32 = .{ 0.0, 0.0, 0.0 },
    last_ray_dir: [3]f32 = .{ 0.0, 0.0, 0.0 },

    // Intent queues and memory views
    outbox: OutboxQueue = .{},
    reconciliation_diag: ReconciliationDiagnostics = .{},
    host_state: ?*GameState = null,
    guest_state: ?*const GameState = null,

    // Diagnostics & testing state
    last_log: [256]u8 = [_]u8{0} ** 256,
    last_log_len: usize = 0,
    log_count: u32 = 0,

    // Reconciliation lifecycle
    pub fn postTickReconcile(self: *EngineContext, dt: f32) void;
};
```

### `postTickReconcile(dt)`
Runs after every script tick:

1. **Input Synchronization**: Updates `GameState.input` from native SDL3 input.
2. **Intent Reconciliation**: `outbox_mod.reconcilePostTick` iterates over queued intents, updates `GameState.entities`, and synchronizes Flecs ECS components and Jolt Physics bodies.
3. **Hierarchy Resolution**: Propagates parent transforms down to children entities.
4. **Scene Sync**: Updates visual render meshes in `Scene` from authoritative `GameState`.
5. **Task Scheduler Step**: Advances timers and runs deferred tasks queued during the tick.
6. **Outbox Clear**: Resets `OutboxQueue` to receive intents for the next tick.

### `ScriptManager` & Multi-Script Isolation
Replaces the single global `ScriptHost` with a multi-tenant script manager enabling hundreds of independent script instances:

- **Isolated Linear Memory**: Each `ScriptInstance` possesses its own `wasm_module_inst_t` and linear memory space. Mutations in one script cannot corrupt another script's memory.
- **Flecs Entity Attachment**: Independent script instances can be attached to Flecs entities via `ScriptComponent`:
  ```zig
  // Attaches instance to entity and registers component in Flecs
  try script_mgr.attachToEntity(instance_id, entity);
  
  // Steps all active entity-attached scripts in one tick
  script_mgr.stepEntityScripts(&ecs_world, dt);
  ```
- **Execution Watchdog & Timeouts**: A dedicated background `Watchdog` thread monitors script execution deadlines:
  - If a script exceeds its execution limit (`timeout_ns`), the watchdog invokes `wasm_runtime_terminate(module_inst)`, interrupting infinite loops without freezing the main engine thread.
  - Errored/timed-out scripts are safely disabled and recorded (`errored = true`, `error_msg`) while the engine and other scripts continue running smoothly.

### `TaskScheduler` (Host Task Engine)
Manages cooperative task queues and resumption timers:

- **Immediate Tasks (`spawn`)**: Runs task in the current execution cycle.
- **Deferred Tasks (`defer`)**: Queues tasks to run at the conclusion of the simulation tick after outbox reconciliation.
- **Delayed Tasks (`delay`)**: Decrements remaining seconds each tick and resumes task on the exact frame after duration elapses.
- **Wait Timers (`wait`)**: Implements slot-based countdown timers returning elapsed time on the exact frame when target duration is reached.
- **Task Cancellation (`cancel`)**: Cancels pending tasks by `TaskId`.

### Dynamic Flecs ECS Host Bridge
Bridges the native C99 Flecs ECS world to the WebAssembly sandbox:

- **Dynamic Component Registration**: Maps guest-specified names, sizes, and alignments directly to `ecs_component_init` in Flecs.
- **Authoritative Component Storage**: Stores component structs inside Flecs contiguous archetype tables, guaranteeing zero memory fragmentation and fast query evaluation.
- **Entity Resolution**: Seamlessly resolves both GameState entity IDs (0..2047) and pure Flecs 64-bit entity IDs.
- **Archetype Queries**: Evaluates single and multi-component queries across native and dynamic components using Flecs table iterators (`ecs_each_id`).
- **System Registration**: Tracks registered guest systems and coordinates execution across tick phases.

### Native WAMR Symbol Registration
Symbols are registered using WAMR's C API (`wasm_runtime_register_natives`). The full registered symbol table bridges guest WebAssembly calls to host engine subsystems:

| Subsystem | Symbol | Signature | Description |
| :--- | :--- | :--- | :--- |
| **Outbox & State** | `engine_apply_impulse` | `(ifff)` | Enqueue physics impulse vector on player or entity |
| | `engine_set_player_velocity` | `(ifff)` | Set player linear velocity |
| | `engine_teleport_player` | `(ifff)` | Immediate player teleportation |
| | `engine_spawn_entity` | `(ifffffff)` | Spawn entity with archetype, pos, and RGBA color |
| | `engine_despawn_entity` | `(i)` | Despawn entity and unparent children |
| | `engine_set_entity_local_pos` | `(ifff)` | Set local translation relative to parent |
| | `engine_set_entity_local_rot` | `(ifff)` | Set local Euler rotation relative to parent |
| | `engine_set_entity_local_scale` | `(ifff)` | Set local scale relative to parent |
| | `engine_set_entity_parent` | `(ii)` | Parent child entity with hierarchy cycle detection |
| | `engine_set_entity_collider` | `(iifff)` | Assign collider type and extents |
| | `engine_set_entity_tag` | `(iii)` | Set 16-byte entity name tag |
| | `engine_set_entity_motion_type` | `(ii)` | Set dynamic, kinematic, or static motion type |
| | `engine_set_entity_material` | `(ifffi)` | Set metallic, roughness, emissive, and shading model |
| | `engine_set_entity_color` | `(iffff)` | Set entity tint RGBA color |
| | `engine_emit_event` | `(iiiffffii)` | Dispatch game event into shared event queue |
| **Jolt Physics** | `engine_physics_create_body` | `(ifffi)i` | Spawn dynamic or static Jolt rigid body |
| | `engine_physics_apply_impulse` | `(ifff)` | Apply impulse vector to Jolt rigid body |
| | `engine_physics_get_pos_x/y/z` | `(i)f` | Read rigid body world position |
| | `engine_physics_get_vel_y` | `(i)f` | Read rigid body vertical velocity |
| | `engine_physics_is_active` | `(i)i` | Query rigid body simulation state |
| | `engine_physics_cast_ray` | `(ffffff)i` | Cast ray against Jolt NarrowPhase scene |
| | `engine_physics_get_ray_hit_*` | `()i`, `()f` | Read hit body ID, hit position, and fraction |
| **Shapecast & Layers** | `engine_physics_cast_sphere` | `(fffffffi)i` | Sweep sphere with collision group mask |
| | `engine_physics_cast_box` | `(fffffffffi)i` | Sweep box with collision group mask |
| | `engine_physics_get_hit_normal_*` | `()f` | Surface normal coordinates from shape hit |
| | `engine_physics_set_collision_layer` | `(ii)` | Assign body to collision layer |
| | `engine_physics_set_layer_collision` | `(iii)` | Toggle pairwise layer collision filtering |
| **Character Virtual** | `engine_character_create` | `(fffff)i` | Create capsule CharacterVirtual controller |
| | `engine_character_destroy` | `(i)` | Destroy CharacterVirtual controller |
| | `engine_character_set_linear_velocity` | `(ifff)` | Set velocity (integrating gravity airborne) |
| | `engine_character_set_position` | `(ifff)` | Teleport character controller |
| | `engine_character_get_ground_state` | `(i)i` | Query ground state (`on_ground`, `sliding`, `in_air`) |
| | `engine_character_get_pos_x/y/z` | `(i)f` | Read character position coordinates |
| | `engine_character_get_vel_y` | `(i)f` | Read character vertical linear velocity |
| **Constraints / Joints** | `engine_constraint_create_hinge` | `(iiffffffff)i` | Hinge joint with angular limits |
| | `engine_constraint_create_ball_socket`| `(iifff)i` | Ball-and-socket joint |
| | `engine_constraint_create_slider` | `(iifffff)i` | Slider joint with travel limits |
| | `engine_constraint_create_weld` | `(ii)i` | Rigid weld constraint |
| | `engine_constraint_destroy` | `(i)` | Destroy physics constraint |
| **Particles** | `engine_particle_spawn_burst` | `(fffifffffff)` | GPU instanced particle burst |
| **UI & Font Text** | `engine_ui_draw_rect` | `(ffffffff)` | Immediate 2D solid quad |
| | `engine_ui_draw_rect_border` | `(fffffffff)` | Immediate 2D rectangular border |
| | `engine_ui_draw_crosshair` | `(ffffffff)` | Centered crosshair HUD element |
| | `engine_ui_draw_progress_bar` | `(fffffffffffff)`| Progress bar with fill and background RGBA |
| | `engine_ui_draw_selection_box` | `(ffffffffffff)`| RTS drag-selection marquee box |
| | `engine_ui_draw_text` | `(iifffffff)` | MSDF / SDF glyph atlas text string |
| **Camera & Window** | `engine_camera_set_pos/rot/fov` | `(fff)`, `(ff)`, `(f)` | Camera transform and field of view |
| | `engine_camera_screen_to_ray` | `(ffff)i` | Unproject screen coordinates to 3D ray |
| | `engine_window_set_relative_mouse` | `(i)i` | Toggle pointer lock & relative mouse deltas |
| | `engine_window_get_screen_w/h` | `()f` | Viewport dimensions in logical pixels |
| **Audio** | `engine_audio_play_tone/impact/chime`| `(fff)`, `(f)` | Procedural audio synthesis |
| **Networking & RemoteEvents** | `engine_net_fire_server` | `(iiii)` | Client -> Server RemoteEvent RPC |
| | `engine_net_fire_client` | `(iiiii)` | Server -> Client RemoteEvent RPC |
| | `engine_net_fire_all_clients` | `(iiii)` | Server -> Broadcast All Clients RemoteEvent RPC |
| | `engine_net_poll_event` | `(iiiii)i` | Poll next queued RemoteEvent (encoded lengths) |
| | `engine_net_get_rtt` | `()f` | Smoothed round-trip ping time (ms) |
| | `engine_net_is_connected` | `()i` | Query connection established status (0 or 1) |
| | `engine_net_get_client_id` | `()i` | Query local client ID slot (0 to 31) |
| **Task Scheduler** | `engine_task_wait` | `(if)f` | Cooperative wait timer returning elapsed time on resume |
| | `engine_task_cancel` | `(i)i` | Cancel scheduled task by task ID |
| **Flecs ECS** | `engine_ecs_register_component` | `(iiii)I` | Register dynamic component name, size & alignment |
| | `engine_ecs_get_component_id` | `(ii)I` | Look up component ID by name string |
| | `engine_ecs_get_builtin_component` | `(i)I` | Query built-in Flecs component ID |
| | `engine_ecs_new_entity` | `(ii)I` | Create new Flecs entity with optional name |
| | `engine_ecs_delete_entity` | `(I)i` | Delete Flecs entity |
| | `engine_ecs_is_alive` | `(I)i` | Query if entity is alive |
| | `engine_ecs_set_component` | `(IIii)i` | Set/attach component struct bytes to entity |
| | `engine_ecs_get_component` | `(IIii)i` | Read component struct bytes from entity |
| | `engine_ecs_has_component` | `(II)i` | Query if entity has component |
| | `engine_ecs_remove_component` | `(II)i` | Remove component from entity |
| | `engine_ecs_query_entities` | `(iiii)i` | Query entities matching component slice |
| | `engine_ecs_query_count` | `(ii)i` | Count entities matching component slice |
| | `engine_ecs_register_system` | `(iiii)i` | Register system query with host engine |
| | `engine_ecs_set_system_enabled` | `(ii)i` | Toggle system enabled state |

```zig
pub fn registerEngineApis() wamr.WasmError!void {
    if (apis_registered) return;
    if (!c.wasm_runtime_register_natives("engine", &native_symbols, native_symbols.len)) {
        return wamr.WasmError.LinkFunctionFailed;
    }
    apis_registered = true;
}
```

---

## 7. Script Lifecycle & Usage Examples

### Script Entrypoints (`init`, `update`)

Every script module (`scripts/my_script.zig`) exports two functions called by the host:

```zig
const engine = @import("engine_api.zig");

pub export fn init() void {
    // Called once when script loads or scene resets
    engine.log.print("Script initialized!");
}

pub export fn update(dt: f32) void {
    // Called every engine frame with delta time
    _ = dt;
}
```

---

### Example: FPS Character Controller

```zig
const engine = @import("engine_api.zig");

var yaw: f32 = 0.0;
var pitch: f32 = 0.0;
var player_pos: engine.Vec3 = engine.Vec3.init(0.0, 1.8, 4.0);

pub export fn init() void {
    _ = engine.window.setRelativeMouse(true);
}

pub export fn update(dt: f32) void {
    const inp = engine.input;

    // Mouse look
    const mouse_sensitivity: f32 = 0.0025;
    yaw += inp.getMouseDx() * mouse_sensitivity;
    pitch -= inp.getMouseDy() * mouse_sensitivity;
    if (pitch > 1.5) pitch = 1.5;
    if (pitch < -1.5) pitch = -1.5;

    // Orientation vectors
    const forward_x = engine.math.sin(yaw);
    const forward_z = -engine.math.cos(yaw);
    const right_x = engine.math.cos(yaw);
    const right_z = engine.math.sin(yaw);

    // Movement
    var move_dir = engine.Vec3.init(0, 0, 0);
    if (inp.isActionDown(.move_forward)) {
        move_dir.x += forward_x;
        move_dir.z += forward_z;
    }
    if (inp.isActionDown(.move_backward)) {
        move_dir.x -= forward_x;
        move_dir.z -= forward_z;
    }
    if (inp.isActionDown(.move_right)) {
        move_dir.x += right_x;
        move_dir.z += right_z;
    }
    if (inp.isActionDown(.move_left)) {
        move_dir.x -= right_x;
        move_dir.z -= right_z;
    }

    const speed: f32 = if (inp.isActionDown(.sprint)) 9.0 else 5.0;
    player_pos = player_pos.add(move_dir.scale(speed * dt));

    // Update camera
    engine.camera.setPosition(player_pos);
    engine.camera.setRotation(yaw, pitch);

    // Crosshair HUD
    const sw = engine.window.getScreenWidth();
    const sh = engine.window.getScreenHeight();
    engine.ui.drawCrosshair(sw / 2.0, sh / 2.0, 10.0, 2.0, .{ 1.0, 1.0, 1.0, 0.9 });
}
```

---

### Example: Roblox-Style Humanoid Character Controller

Demonstrates `engine.character` (`CharacterVirtual`), ground state queries, jumping, GPU particles, and scriptable UI text overlays:

```zig
const engine = @import("engine_api.zig");

var char_id: u32 = 0;
var yaw: f32 = 0.0;
var pitch: f32 = 0.0;

pub export fn init() void {
    _ = engine.window.setRelativeMouse(true);
    // Create capsule character (half-height 0.5m, radius 0.3m -> total height 1.6m)
    char_id = engine.character.create(engine.Vec3.init(0.0, 2.0, 0.0), 0.5, 0.3);
}

pub export fn update(dt: f32) void {
    _ = dt;
    const inp = engine.input;
    const char = engine.character;

    // Mouse look
    yaw += inp.getMouseDx() * 0.0025;
    pitch -= inp.getMouseDy() * 0.0025;
    if (pitch > 1.5) pitch = 1.5;
    if (pitch < -1.5) pitch = -1.5;

    // Camera orientation
    const forward_x = engine.math.sin(yaw);
    const forward_z = -engine.math.cos(yaw);
    const right_x = engine.math.cos(yaw);
    const right_z = engine.math.sin(yaw);

    var move_dir = engine.Vec3.init(0, 0, 0);
    if (inp.isActionDown(.move_forward)) { move_dir.x += forward_x; move_dir.z += forward_z; }
    if (inp.isActionDown(.move_backward)) { move_dir.x -= forward_x; move_dir.z -= forward_z; }
    if (inp.isActionDown(.move_right)) { move_dir.x += right_x; move_dir.z += right_z; }
    if (inp.isActionDown(.move_left)) { move_dir.x -= right_x; move_dir.z -= right_z; }

    const ground_state = char.getGroundState(char_id);
    const is_grounded = (ground_state == .on_ground);

    const speed: f32 = if (inp.isActionDown(.sprint)) 10.0 else 6.0;
    const current_vy = char.getVelocityY(char_id);

    // Jump impulse when on ground
    var desired_vy = current_vy;
    if (inp.isActionPressed(.jump) and is_grounded) {
        desired_vy = 7.5;
        engine.audio.playImpact(0.5);
        // Spawn ground dust particles
        const pos = char.getPosition(char_id);
        engine.particles.spawnBurst(pos, 20, 3.0, .{ 0.8, 0.8, 0.7, 0.6 }, 0.15, 0.4);
    }

    char.setLinearVelocity(char_id, engine.Vec3.init(move_dir.x * speed, desired_vy, move_dir.z * speed));

    // Follow camera at eye level (0.6m above capsule center)
    const pos = char.getPosition(char_id);
    engine.camera.setPosition(engine.Vec3.init(pos.x, pos.y + 0.6, pos.z));
    engine.camera.setRotation(yaw, pitch);

    // HUD Text and Crosshair
    const sw = engine.window.getScreenWidth();
    const sh = engine.window.getScreenHeight();
    engine.ui.drawText(if (is_grounded) "STATE: GROUNDED" else "STATE: AIRBORNE", 20, 20, 14.0, .{ 1, 1, 1, 1 });
    engine.ui.drawCrosshair(sw / 2.0, sh / 2.0, 8.0, 1.5, .{ 1, 1, 1, 0.8 });
}
```

---

### Example: RTS Unit Raycasting & UI HUD

```zig
const engine = @import("engine_api.zig");

var target_pos: engine.Vec3 = engine.Vec3.init(0, 0, 0);
var selected_unit_id: ?u32 = null;

pub export fn init() void {
    _ = engine.window.setRelativeMouse(false);
}

pub export fn update(dt: f32) void {
    _ = dt;
    const inp = engine.input;
    const sw = engine.window.getScreenWidth();
    const sh = engine.window.getScreenHeight();

    // Ground picking on right mouse click
    if (inp.isActionPressed(.secondary_fire)) {
        if (engine.camera.screenToRay(inp.getMouseX(), inp.getMouseY(), sw, sh)) |ray| {
            if (ray.intersectPlaneY(0.0)) |hit| {
                target_pos = hit;
                engine.audio.playChime(0.5);

                if (selected_unit_id) |unit_id| {
                    engine.setEntityLocalPosition(unit_id, target_pos);
                }
            }
        }
    }

    // Draw HUD
    engine.ui.drawRect(10, 10, 240, 50, .{ 0.05, 0.05, 0.08, 0.85 });
    engine.ui.drawRectBorder(10, 10, 240, 50, 1.5, .{ 0.3, 0.5, 0.9, 1.0 });
    engine.ui.drawText("COMMAND CENTER", 20, 18, 14.0, .{ 1.0, 1.0, 1.0, 1.0 });
    engine.ui.drawProgressBar(20, 38, 220, 12, 0.75, .{ 0.2, 0.7, 1.0, 1.0 }, .{ 0.1, 0.2, 0.3, 1.0 });
}
```

---

### Example: Multiplayer Networking & RemoteEvents

Demonstrates client-server RemoteEvents, RPC dispatching, event polling, and live network latency / connection HUD:

```zig
const std = @import("std");
const engine = @import("engine_api.zig");

var player_gold: u32 = 100;
var status_msg: [64]u8 = [_]u8{0} ** 64;
var status_msg_len: usize = 0;

pub export fn init() void {
    engine.log.print("[NET SCRIPT] Initializing multiplayer client...");
    // Request initial player loadout from dedicated server
    engine.net.fireServer("RequestProfile", "user_id=104");
}

pub export fn update(dt: f32) void {
    _ = dt;
    const inp = engine.input;
    const net = engine.net;

    // 1. Process all incoming RemoteEvents from server
    var name_buf: [32]u8 = undefined;
    var data_buf: [256]u8 = undefined;

    while (net.pollEvent(&name_buf, &data_buf)) |ev| {
        const event_name = name_buf[0..ev.name_len];
        const payload = data_buf[0..ev.data_len];

        if (std.mem.eql(u8, event_name, "UpdateGold")) {
            // Server authoritatively credited or debited player gold
            if (std.fmt.parseInt(u32, payload, 10)) |val| {
                player_gold = val;
                engine.audio.playChime(0.7);
            } else |_| {}
        } else if (std.mem.eql(u8, event_name, "ServerNotice")) {
            const copy_len = @min(payload.len, status_msg.len);
            @memcpy(status_msg[0..copy_len], payload[0..copy_len]);
            status_msg_len = copy_len;
        }
    }

    // 2. Trigger Client -> Server RemoteEvent on interaction key (e.g. purchasing an item)
    if (inp.isActionPressed(.interact)) {
        net.fireServer("BuyItem", "item_id=potion_speed");
    }

    // 3. Network Diagnostics & HUD Overlay
    const sw = engine.window.getScreenWidth();
    const sh = engine.window.getScreenHeight();
    _ = sh;

    const rtt = net.getRtt();
    const is_connected = net.isConnected();
    const client_id = net.getClientId();

    var hud_buf: [64]u8 = undefined;
    const net_label = std.fmt.bufPrint(
        &hud_buf,
        "NET: {s} | ID: {d} | PING: {d:.1} ms",
        .{ if (is_connected) "ONLINE" else "CONNECTING", client_id, rtt },
    ) catch "NET STATS";

    engine.ui.drawRect(sw - 310, 10, 300, 32, .{ 0.05, 0.05, 0.08, 0.85 });
    engine.ui.drawRectBorder(sw - 310, 10, 300, 32, 1.5, .{ 0.2, 0.7, 0.3, 1.0 });
    engine.ui.drawText(net_label, sw - 300, 20, 12.0, .{ 1.0, 1.0, 1.0, 1.0 });

    if (status_msg_len > 0) {
        engine.ui.drawText(status_msg[0..status_msg_len], 20, 80, 14.0, .{ 1.0, 0.9, 0.2, 1.0 });
    }
}
```

---

### Example: Multi-Script UGC Execution & Task Scheduling

Demonstrates multi-instance Wasm script execution, attaching independent script instances to Flecs entities, watchdog isolation, and cooperative task scheduling (`task.wait`, `task.spawn`, `task.defer`):

#### 1. Host Runtime (`src/main.zig` or Game Server)
```zig
const std = @import("std");
const engine = @import("engine");

pub fn setupEntitiesWithScripts(
    script_mgr: *engine.scripting.ScriptManager,
    ecs: *engine.ecs.EcsWorld,
    wasm_bytes: []const u8,
) !void {
    // 1. Load compiled WebAssembly module once into memory
    const mod_id = try script_mgr.loadModule(wasm_bytes, "rotating_turret");

    // 2. Instantiate and attach distinct script instances to 50 Flecs entities
    for (0..50) |i| {
        const entity = ecs.spawnMeshEntity(
            .{ .x = @floatFromInt(i * 2), .y = 0.0, .z = 0.0 },
            .{ .x = 1.0, .y = 1.0, .z = 1.0 },
            .{ .primitive_type = 0, .color = .{ 0.2, 0.8, 0.4, 1.0 } },
        );

        // Creates an isolated WAMR instance with its own sandboxed linear memory
        const inst = try script_mgr.createInstance(mod_id, "turret_script");
        inst.timeout_ns = 20_000_000; // 20ms watchdog limit

        // Attaches instance to Flecs entity via ScriptComponent
        try script_mgr.attachToEntity(inst.id, entity);
        try script_mgr.callInit(inst);
    }
}

pub fn gameLoop(script_mgr: *engine.scripting.ScriptManager, ecs: *engine.ecs.EcsWorld, dt: f32) void {
    // Step all 50 entity scripts concurrently with watchdog protection
    script_mgr.stepEntityScripts(ecs, dt);
}
```

#### 2. Guest Gameplay Script (`scripts/turret_controller.zig`)
```zig
const engine = @import("engine_api.zig");
const task = engine.task;

var fire_cooldown: f32 = 0.0;
var total_shots: u32 = 0;

pub export fn init() void {
    engine.log.print("[TURRET] Script loaded and initialized.");
    
    // Spawn a one-time welcome task deferred to the end of the first frame
    _ = task.@"defer"(struct {
        fn onReady() void {
            engine.log.print("[TURRET] Ready for target acquisition.");
        }
    }.onReady);
}

pub export fn update(dt: f32) void {
    _ = dt;

    // 1. Cooperative Periodic Wait: Fire every 1.5 seconds
    const elapsed = task.wait(1.5);
    if (elapsed > 0.0) {
        // Resumes on the exact frame after 1.5 seconds have passed
        total_shots += 1;
        engine.audio.playImpact(0.4);

        // Spawn a burst of visual sparks at the barrel position
        engine.spawnParticleBurst(
            engine.Vec3.init(0.0, 1.0, 0.0),
            15,
            3.0,
            .{ 1.0, 0.7, 0.1, 1.0 },
            0.15,
            0.4,
        );

        // Schedule delayed cooldown sound 0.5s after firing
        _ = task.delay(0.5, struct {
            fn onCooldown() void {
                engine.audio.playChime(0.2);
            }
        }.onCooldown);
    }
}
```

---

### Example: UGC Dynamic Components and Systems

Demonstrates defining custom ECS components, registering them into Flecs during WASM `init()`, registering multi-component systems, creating entities, and stepping system updates every tick:

```zig
const engine = @import("engine_api.zig");
const ecs = engine.ecs;

// 1. Define custom gameplay component data structures
pub const RotatorComponent = extern struct {
    speed_y: f32 = 1.5,
    speed_x: f32 = 0.0,
    angle: f32 = 0.0,
};

pub const HoverOscillatorComponent = extern struct {
    frequency: f32 = 3.0,
    amplitude: f32 = 0.15,
    phase: f32 = 0.0,
    base_y: f32 = 0.0,
};

pub const TechCoreStats = extern struct {
    energy: f32 = 100.0,
    max_energy: f32 = 100.0,
    overcharge: bool = false,
};

// Component IDs assigned by native Flecs at registration
var comp_rotator: ecs.ComponentId = 0;
var comp_hover: ecs.ComponentId = 0;
var comp_core: ecs.ComponentId = 0;

// System IDs assigned by host
var sys_rotator: ecs.SystemId = 0;
var sys_hover: ecs.SystemId = 0;

pub export fn init() void {
    engine.log.print("[UGC ECS] Initializing custom gameplay components & systems...");

    // 2. Register dynamic components into Flecs ECS during script initialization
    comp_rotator = ecs.register(RotatorComponent, "RotatorComponent");
    comp_hover = ecs.register(HoverOscillatorComponent, "HoverOscillatorComponent");
    comp_core = ecs.register(TechCoreStats, "TechCoreStats");

    // 3. Define and register custom systems with archetype query filters
    // RotatorSystem: Iterates all entities having RotatorComponent
    sys_rotator = ecs.registerSystem(
        "RotatorSystem",
        &[_]ecs.ComponentId{ comp_rotator },
        struct {
            fn onUpdate(entity: ecs.EntityId, dt: f32) void {
                if (ecs.get(entity, comp_rotator, RotatorComponent)) |rot| {
                    var updated = rot;
                    updated.angle += updated.speed_y * dt;
                    _ = ecs.set(entity, comp_rotator, updated);
                }
            }
        }.onUpdate,
    );

    // HoverSystem: Iterates all entities having HoverOscillatorComponent
    sys_hover = ecs.registerSystem(
        "HoverSystem",
        &[_]ecs.ComponentId{ comp_hover },
        struct {
            fn onUpdate(entity: ecs.EntityId, dt: f32) void {
                if (ecs.get(entity, comp_hover, HoverOscillatorComponent)) |hov| {
                    var updated = hov;
                    updated.phase += updated.frequency * dt;
                    _ = ecs.set(entity, comp_hover, updated);
                }
            }
        }.onUpdate,
    );

    // 4. Create entities and attach components during initialization
    for (0..10) |i| {
        const entity = ecs.newEntity("HoverTurret");
        _ = ecs.set(entity, comp_rotator, RotatorComponent{ .speed_y = 1.0 + @as(f32, @floatFromInt(i)) * 0.5 });
        _ = ecs.set(entity, comp_hover, HoverOscillatorComponent{ .frequency = 2.5, .amplitude = 0.2, .base_y = 2.0 });
        _ = ecs.set(entity, comp_core, TechCoreStats{ .energy = 75.0 });
    }
}

pub export fn update(dt: f32) void {
    // 5. Advance all registered UGC ECS systems for the frame
    ecs.step(dt);
}
```




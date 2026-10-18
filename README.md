# Zig 0.16+ WGPU & SDL3 Game Engine Architecture with Flecs ECS, Jolt Physics & WebAssembly Scripting

# !! INSPECT agents.md !!

This repository contains a modern 3D game engine and renderer implemented in **Zig 0.16.0** using:
- **wgpu-native** (via `wgpu_native_zig`) for WebGPU modern 3D rendering with Cook-Torrance PBR shading and 2D texture samplers.
- **Flecs** for high-performance, industry-standard archetype-based Entity Component System (ECS).
- **Jolt Physics** (via `joltc`) for multi-threaded, robust 3D rigid body simulation, collision layers, and dynamics.
- **SDL3** for platform windowing, input events, and low-latency audio stream synthesis.
- **Wasm3** for high-performance, secure WebAssembly sandboxing of user scripts and mods with dual-mapped MMU memory isolation.

---

## 🏛️ Engine Architecture & Directory Structure

```
├── build.zig                  # Build graph configuring SDL3, WGPU, Wasm3, Flecs, Jolt, and WASM compilation
├── build.zig.zon              # Zig package definitions
├── external/
│   ├── flecs/                 # High-performance C99 Entity Component System
│   ├── jolt/                  # Multi-threaded Jolt Physics C wrapper library (joltc)
│   ├── wgpu_native_zig/       # WGPU native bindings updated for Zig 0.16.0
│   └── wasm3/                 # Ultra-fast, lightweight WebAssembly interpreter
├── scripts/
│   ├── engine_api.zig         # Guest Zig SDK imported by modders & user scripts
│   └── scene_controller.zig   # Example user-made script interacting with the 3D scene
├── test/
│   └── wasm_scene_test.zig    # Unit & integration test suite verifying Wasm, Flecs, Jolt, and Audio
└── src/
    ├── main.zig               # Engine loop integrating Window, Renderer, Flecs, Jolt, Audio & Wasm
    ├── sdl3.zig               # Generated SDL3 Zig bindings
    └── engine/
        ├── engine.zig         # Root engine module exporting all subsystems
        ├── math.zig           # 3D Math library (Vec3, Mat4, LookAt, Perspective for WebGPU NDC)
        ├── platform/
        │   └── window.zig     # SDL3 window creation & native WGPU surface integration
        ├── input/
        │   └── input.zig      # Input manager (keyboard state, mouse deltas, window events)
        ├── ecs/
        │   └── flecs.zig      # Idiomatic Zig wrapper for Flecs ECS (Position, Velocity, Mesh, Body)
        ├── physics/
        │   └── jolt.zig       # Jolt Physics integration (JobSystem, collision shapes, rigid bodies)
        ├── audio/
        │   └── audio.zig      # SDL3 real-time audio synthesis (waveform generation, impacts, chimes)
        ├── renderer/
        │   ├── scene.zig      # 3D Scene representation, mesh vertices, indices, and transforms
        │   ├── primitives.zig # Procedural 3D vertex geometries (cubes, spheres, cylinders, pyramids)
        │   ├── material.zig   # PBR Cook-Torrance & Unlit materials
        │   └── renderer.zig   # Core WGPU renderer (pipelines, depth-stencil, diffuse texture, UBOs)
        ├── shaders/
        │   └── scene.wgsl     # WGSL PBR + diffuse texture sampler shader
        └── scripting/
            ├── wasm3_bindings.zig # Idiomatic Zig wrapper for Wasm3 runtime C API
            ├── engine_api.zig     # Engine host APIs exposed to guest scripts
            ├── outbox.zig         # Action queue / mutation intent reconciliation
            └── script_host.zig    # Script lifecycle runner (init, update, memory isolation)
```

---

## ⚙️ WebAssembly Runtime Decision: Wasm3

When hosting user-generated content (mods, custom entity behaviors, scene controllers) in a native game engine, the choice of WASM runtime determines security, startup latency, binary footprint, and cross-platform maintainability.

### Runtime Comparison

| Feature / Criteria | **Wasm3 (Selected)** | **Wasmtime / Wasmer** | **WAMR** | **Pure-Zig Interpreters (e.g. zware)** |
| :--- | :--- | :--- | :--- | :--- |
| **Startup / Compile Latency** | **Instant (Zero JIT delay)** | High (multi-second JIT pause per script) | Low (interpreter) to Moderate (JIT) | Instant |
| **Memory Footprint** | **~64 KB** | Heavy (tens of megabytes per instance) | ~100 KB – 1 MB | Small |
| **Host Sandboxing & Safety** | **Strict linear memory isolation** | Full sandboxing | Strict sandboxing | In-development |
| **Zig Build Integration** | **Native ANSI C (zero external tools)** | Requires Rust / Cargo / prebuilt C-APIs | Complex C build configuration | Pure Zig |
| **Determinism** | **100% deterministic bytecode execution** | Varies by JIT optimizations | Varies | Deterministic |
| **Ecosystem Maturity** | **Battle-tested in embedded & games** | Enterprise server-side | Embedded / IoT focus | Alpha stage, breaking Zig changes |

### Architectural Rationale
1. **Zero-Stutter Runtime Script Loading**: Games require instant hot-reloading and fast asset spawning without frames dropping due to background JIT compilation. Wasm3's meta-machine interpreter executes immediately upon parse.
2. **Seamless Zig 0.16 C Interop**: Because Wasm3 is written in pure ANSI C without dependencies, it compiles directly inside `build.zig` via Zig's built-in Clang toolchain on Windows, Linux, and macOS without external build tools.
3. **Rigorous Security Boundaries**: Untrusted user scripts cannot access filesystem or network sockets; they are restricted to safe, bounds-checked linear memory and explicit host engine APIs.

---

## 🔒 Shared Memory Architecture & UGC Security

Hosting User-Generated Content (UGC) scripts requires high throughput and strict memory safety. Passing data payloads via tick parameters or invoking host functions per read incurs heavy context-switching overhead. At the same time, Wasm linear memory has no native write-protection instructions.

This engine implements an authoritative 3-tier architecture:

```
┌────────────────────────────────────────────────────────────────────────┐
│                          AUTHORITATIVE ZIG HOST                        │
│  [Host GameState] (RW: PROT_READ | PROT_WRITE / PAGE_READWRITE)       │
└───────────────────▲───────────────────────────────────────┬────────────┘
                    │                                       │ Aliased Physical Pages
                    │ Validates & Reconciles                │ Zero-overhead reads
                    │ Post-Tick                             │
┌───────────────────┴───────────────────────────────────────▼────────────┐
│                       OUTBOX / ACTION QUEUE                            │
│  Guest Intents: applyImpulse, teleport, spawn, rotate, setCubeColor    │
└───────────────────▲────────────────────────────────────────────────────┘
                    │ Enqueues intents
┌───────────────────┴────────────────────────────────────────────────────┐
│                         WASM GUEST SDK / MOD                           │
│  [Guest View] (RO: PROT_READ / PAGE_READONLY)                          │
│  world.getPlayer(id).getPosition(), world.getEntity(id).getColor()...  │
│  *Any write attempt triggers a hardware page fault -> Wasm trap*       │
└────────────────────────────────────────────────────────────────────────┘
```

### 1. Dual Virtual Memory Mapping (Aliased Physical Pages)
- Authoritative game state is backed by shared memory (`DualMappedMemory`).
- The shared physical memory pages are mapped simultaneously:
  - **Host Mapping**: Read-Write (`PROT_READ | PROT_WRITE` / `PAGE_READWRITE`). The authoritative host mutates state directly.
  - **Guest Mapping**: Read-Only (`PROT_READ` / `PAGE_READONLY`). Any write attempt by guest code triggers a hardware MMU page fault that converts into a Wasm trap via Vectored Exception Handling (`STATUS_ACCESS_VIOLATION` interception).
- Because both mappings share the exact same physical pages in RAM, state updates on the host are instantaneously visible to the guest without `memcpy` or serialization overhead.

### 2. Guest SDK Wrapper over Shared Memory
- The guest SDK (`scripts/engine_api.zig`) provides high-level typed views:
  - `world.getPlayer(id).getPosition()`
  - `world.getPlayer(id).getVelocity()`
  - `world.getEntity(id).getPosition()`
  - `world.getScene().getRotationX()`
- Reads perform direct, in-place memory dereferences without crossing the WebAssembly host boundary, eliminating context-switching penalties.

### 3. Outbox / Command Queue for State Changes
- Because the shared memory is physically non-writable to the guest, mutations are handled through an action queue (`OutboxQueue`).
- The guest enqueues intents:
  - `engine.applyImpulse(entity_id, impulse)`
  - `engine.setPlayerVelocity(player_id, vel)`
  - `engine.teleportPlayer(player_id, pos)`
  - `engine.spawnEntity(type, pos, color)`
  - `engine.rotateScene(dx, dy)`
  - `engine.setCubeColor(face, r, g, b)`
- During **post-tick reconciliation**, the Zig host:
  1. Validates all pending intents (bounds checks, finite floats, velocity and impulse magnitude caps).
  2. Discards invalid/malicious intents.
  3. Commits validated mutations to authoritative state.
  4. Integrates authoritative physics simulation steps.

## 🧪 Automated Testing & Verification

The test suite in `test/wasm_scene_test.zig` verifies that a WebAssembly module compiled from Zig (`scripts/scene_controller.zig`) interacts with the 3D scene across multiple frames:

```bash
# Run the WebAssembly engine integration tests
zig build test
```

### What the test verifies:
1. Compiles `scripts/scene_controller.zig` into `wasm32-freestanding` WebAssembly.
2. Initializes `ScriptHost` and instantiates the script inside the Wasm3 runtime.
3. Invokes `on_init()`, asserting that:
   - Initial rotations (`rotation_x = 0.25`, `rotation_y = 0.50`) and camera distance (`4.0`) are applied to `engine.Scene`.
   - Distinctive vibrant face colors are applied to the 3D cube mesh.
   - Script debug log messages are captured by the host `EngineContext`.
4. Simulates multi-frame updates (`on_update`), asserting that:
   - Incremental rotation matrices update each frame.
   - Sine-wave camera breathing oscillation functions as expected.
   - Front face vertex colors are dynamically modulated over time.

---

## 🚀 Building & Running

Ensure you have Zig 0.16.0 installed:

```bash
# Run unit and WebAssembly integration tests
zig build test

# Build and run the renderer with the active WASM script
zig build run

# Or build the release binary directly
zig build -Doptimize=ReleaseFast
./zig-out/bin/wgpu_sdl_renderer.exe
```

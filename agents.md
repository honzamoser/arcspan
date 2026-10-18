# Developer & AI Agent Guidelines

This document provides operational rules, architectural principles, and workflow instructions for AI agents and human contributors working on this codebase.

---

## 🚨 Cardinal Rule: Strict Engine vs. Game Separation

> **CRITICAL DIRECTIVE**:
> **NONE of the game code, gameplay mechanics, or game-specific logic should ever be included in the game engine itself.**
>
> All game code, player controllers, entity behaviors, gameplay modes, rules, and logic **MUST reside strictly in `scripts/`**.

### Division of Responsibilities

| Subsystem | Location | What Goes Here | What NEVER Goes Here |
| :--- | :--- | :--- | :--- |
| **Game Engine** | `src/`, `src/engine/` | Generic, reusable infrastructure:<br>• WebGPU graphics & PBR rendering<br>• Jolt physics simulation & collision<br>• Built-in Zig ECS archetype & component management<br>• SDL3 windowing, input events & audio<br>• WebAssembly runtime host & outbox queue<br>• Linear algebra & math utilities | ❌ Game rules & win/loss logic<br>❌ Game modes (FPS, TPS, RTS, etc.)<br>❌ Specific character/unit stats & controllers<br>❌ Weapon mechanics, quests, inventories<br>❌ Game-specific scene layouts or assets |
| **Gameplay Scripts** | `scripts/` | All game-specific logic:<br>• Gameplay modes & camera controllers<br>• Player movement, input mapping & physics impulses<br>• Unit behaviors, waypoints, pathing & RTS state<br>• Health, damage, combat & scoring<br>• UI overlays & gameplay HUD logic | ❌ Low-level GPU driver calls<br>❌ OS window management<br>❌ Direct native threading or raw hardware I/O |

### What to do when a game feature requires new engine functionality:
1. **Never hardcode the game feature into `src/`**.
2. Instead, expose a **generic, domain-agnostic capability** in the engine host (`src/engine/scripting/engine_api.zig`).
3. Mirror that API into the guest SDK (`scripts/engine_api.zig`).
4. Implement the actual gameplay behavior in the script (`scripts/scene_controller.zig` or a dedicated script module).

---

## 🏗️ Architecture & Project Structure

The project is a high-performance 3D game engine and WebAssembly scripting environment implemented in **Zig 0.16.0**.

```
├── build.zig                  # Build graph (SDL3, WGPU, WAMR/Wasm3, Jolt, WASM)
├── build.zig.zon              # Zig package dependencies
├── external/                  # Vendored native dependencies
│   ├── jolt/                  # Multi-threaded Jolt Physics C wrapper (joltc)
│   ├── wamr/                  # WebAssembly Micro Runtime (WAMR with AOT & interpreter)
│   ├── wasm3/                 # Fallback lightweight WebAssembly interpreter
│   └── wgpu_native_zig/       # WebGPU native bindings for Zig 0.16.0
├── scripts/                   # 🎮 GAMEPLAY LAYER (WebAssembly Guest Code)
│   ├── engine_api.zig         # Guest Zig SDK (interop bindings, math, outbox intents)
│   ├── scene_controller.zig   # Active gameplay controller & scene logic
│   └── scene_controller.wasm  # Compiled WebAssembly binary
├── src/                       # ⚙️ ENGINE LAYER (Native Host Runtime)
│   ├── main.zig               # Engine initialization, main loop & script execution
│   ├── sdl3.zig               # SDL3 Zig interface
│   └── engine/
│       ├── engine.zig         # Root engine module exporting subsystems
│       ├── audio/             # SDL3 real-time audio synthesis
│       ├── camera/            # Generic view/projection camera types
│       ├── ecs/               # Built-in Zig Entity Component System (ecs.zig)
│       ├── input/             # Platform input state & mouse deltas
│       ├── math.zig           # 3D Math (Vec3, Mat4, LookAt, WebGPU perspective)
│       ├── memory/            # Shared memory & dual-mapped memory protection
│       ├── physics/           # Jolt physics world & body lifecycle
│       ├── platform/          # SDL3 window & WGPU surface binding
│       ├── renderer/          # WGPU PBR renderer, shaders, materials, 2D UI
│       └── scripting/         # WAMR/Wasm3 runtime, engine API host bindings, outbox
└── test/
    └── wasm_scene_test.zig    # Integration tests verifying engine-script interop
```

---

## 🎮 Scripting & UGC Model

1. **Compilation Target**: Scripts are written in Zig and compiled to `wasm32-freestanding` (with optional AOT compilation to `.aot` via `wamrc`).
2. **Memory Safety & Sandbox**:
   - Guest scripts run sandboxed within isolated linear memory.
   - Authoritative state is read with zero overhead through shared typed views.
   - State mutations are communicated back to the engine through an authoritative **Outbox Intent Queue** (e.g. `applyImpulse`, `teleport`, `spawn`, `rotate`, `setCubeColor`).
3. **Script Lifecycle**:
   - `pub export fn init() void`: Called once when the script or scene loads.
   - `pub export fn update(dt: f32) void`: Called every engine frame with delta time.

---

## 🛠️ Build, Test, and Run Commands

Always ensure code builds cleanly with Zig 0.16.0:

| Action | Command |
| :--- | :--- |
| **Run Engine Application** | `zig build run` |
| **Build Everything** | `zig build` |
| **Build WebAssembly Scripts & AOT** | `zig build scripts` *(or `zig build wasm` / `zig build aot`)* |
| **Run Test Suite** | `zig build test` |
| **Run with Custom Script** | `zig build run -Dscript=scripts/my_script.zig` |

---

## 📝 Rules for Modifying Code

1. **Keep Engine Core Clean**: If a task asks for gameplay, character controls, combat, AI, or scene logic, always make changes inside `scripts/`.
2. **Maintain C-ABI Compatibility**: Any data structures passed between engine and scripts (`scripts/engine_api.zig` and `src/engine/scripting/engine_api.zig`) must remain `extern struct` with matching alignments and layouts.
3. **Respect Zig 0.16 Conventions**: Use idiomatic Zig 0.16 syntax. Avoid outdated 0.11-0.13 idioms.
4. **Preserve Documentation**: Retain existing doc comments and structural comments when editing files.
5. **Verify Changes**: Whenever modifying scripts or engine code, run `zig build` or `zig build test` to ensure there are no compilation errors.

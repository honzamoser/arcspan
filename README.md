# Arcspan

This repository contains a modern 3D game engine and renderer implemented in **Zig 0.16.0** using:
- **wgpu-native** (via `wgpu_native_zig`) for WebGPU modern 3D rendering with Cook-Torrance PBR shading and 2D texture samplers.
- **Jolt Physics** (via `joltc`) for multi-threaded, robust 3D rigid body simulation, collision layers, and dynamics.
- **SDL3** for platform windowing, input events, and low-latency audio stream synthesis.
- **WAMR** for high-performance, secure WebAssembly sandboxing of user scripts and AOT building.

---

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
# To build the wamr libraries (wamrc is already included in lfs. If not, download it form the official wamr repository or build it using zig build setup-wamrc)
zig build setup-wamr

# To compile user code to .wasm and .aot files
zig build wasm

# Builds the engine
zig build

# Build and run
zig build run

```

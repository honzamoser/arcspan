# Arcspan

This repository contains a modern 3D game engine and renderer implemented in **Zig** using:
- **wgpu-native** (via `wgpu_native_zig`) for WebGPU modern 3D rendering with Cook-Torrance PBR shading and 2D texture samplers.
- **Jolt Physics** (via `joltc`) for multi-threaded, robust 3D rigid body simulation, collision layers, and dynamics.
- **SDL3** for platform windowing, input events, and low-latency audio stream synthesis.
- **WAMR** for high-performance, secure WebAssembly sandboxing of user scripts and AOT building.

---

## Build support

### Windows

- MSVC and windows-specific libraries are included in the repo

### Linux

- Build support using GNU, but libraries are missing. Need to be done

### Mac

- Same as Linux

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

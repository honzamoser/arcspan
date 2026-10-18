# Developer & AI Agent Guidelines

This document describes the architecture, build workflow, and contribution rules for this Zig game engine.

## Cardinal rule: separate engine and game code

Game-specific behavior belongs in `scripts/`. The native engine in `src/` must remain generic and reusable.

| Subsystem | Location | Responsibilities |
| :--- | :--- | :--- |
| Engine | `src/`, `src/engine/` | WebGPU rendering, SDL3 platform services, Jolt integration, ECS, input, audio, networking, math, memory, and the WebAssembly host |
| Gameplay | `scripts/` | Game modes, player and unit behavior, movement, combat, scoring, scene rules, HUD logic, and other game-specific behavior |

Do not put game rules, game modes, character statistics, weapon mechanics, or game-specific scene logic in `src/`.

When gameplay needs a new engine capability:

1. Add a generic host API in `src/engine/scripting/engine_api.zig`.
2. Mirror the ABI-facing API in the guest-side script SDK.
3. Implement the actual behavior in `scripts/`.

## Current architecture

This project targets Zig **0.16.0** and uses:

- SDL3 for windowing, input, and audio
- WebGPU through the local `external/wgpu_native_zig` package
- Jolt Physics through the C wrapper in `external/jolt`
- WAMR for WebAssembly interpretation and AOT execution
- A built-in Zig ECS in `src/engine/ecs`
- WebAssembly guest scripts compiled from Zig

The repository layout is:

```text
├── build.zig                  # Build graph and custom setup steps
├── build.zig.zon              # Zig package dependencies
├── .gitmodules                # External Git submodule declarations
├── external/
│   ├── jolt/                  # Packaged joltc.h, joltc.lib, and joltc.dll
│   ├── wamr/                  # WAMR source submodule
│   └── wgpu_native_zig/       # Local WebGPU Zig bindings
├── scripts/                   # WebAssembly gameplay code
├── src/                       # Native engine and host runtime
└── test/                      # Engine/script integration tests
```

`zig-pkg/`, `.zig-cache/`, `zig-out/`, WAMR CMake build directories, WAMR
installed libraries, and generated `.aot` files are local build artifacts and
must not be committed.

## Scripting and ABI

Scripts target `wasm32-freestanding`. The normal script pipeline is:

```text
Zig script -> scene_controller.wasm -> wamrc -> scene_controller.aot
```

The engine embeds the generated WASM/AOT artifacts during the build and can
also use the installed runtime files. The script lifecycle exports include:

```zig
pub export fn init() void
pub export fn update(dt: f32) void
```

Guest scripts run in WAMR-managed linear memory. State changes are sent to the
host through the engine API and intent/outbox mechanisms.

Any data shared across the host/guest boundary must use explicit ABI-compatible
types. Shared structures must remain `extern struct` values with matching
field order, sizes, and alignment on both sides.

## Dependencies and submodules

Initialize submodules after cloning:

```powershell
git clone --recurse-submodules <repository-url>
```

For an existing clone:

```powershell
git submodule update --init --recursive
```

WAMR is pinned as the `external/wamr` submodule. Its generated outputs are
ignored. The Windows build expects these locally:

```text
external/wamr/bin/wamrc.exe
external/wamr/lib/iwasm.lib
```

They can be generated with the setup steps below, or supplied from a
compatible prebuilt release. Do not commit generated binaries to the WAMR
submodule.

Jolt is currently consumed as packaged native artifacts in `external/jolt`;
the engine wraps its C API from Zig. Do not replace this with game-specific
physics logic in the engine.

## Build and test

The build defaults to `x86_64-windows-msvc` on Windows. On other hosts it
defaults to the host-native target. An explicit target remains available:

```powershell
zig build
zig build run
zig build test
zig build scripts
zig build wasm
zig build aot
zig build run -Dscript=scripts/my_script.zig
```

Cross-target builds use:

```powershell
zig build -Dtarget=x86_64-windows-msvc
zig build -Dtarget=x86_64-linux-gnu
```

The current packaged Jolt and WAMR libraries are Windows/MSVC artifacts.
Linux builds therefore require Linux-compatible Jolt and WAMR libraries and
additional platform-specific build configuration; selecting a Linux target
alone is not sufficient.

On Windows, a fresh checkout can build the WAMR runtime and AOT compiler:

```powershell
zig build setup-wamr
zig build setup-wamrc
zig build
```

`setup-wamrc` builds LLVM and is substantially slower than a normal build.
It requires Python, CMake, and the Visual Studio 2022 C++ toolchain.

When modifying native code, run the smallest relevant validation command,
followed by `zig build` or `zig build test` when the change affects the engine
or host/guest boundary.

## Modification rules

1. Keep gameplay code in `scripts/`; keep reusable infrastructure in `src/`.
2. Preserve host/guest C ABI compatibility.
3. Use Zig 0.16.0 syntax and APIs.
4. Reuse existing helpers and patterns before adding new abstractions.
5. Keep errors explicit; do not hide failures behind broad catches or silent fallbacks.
6. Preserve useful documentation and update directly related documentation when behavior changes.
7. Do not commit caches, generated binaries, compiler outputs, or local IDE files.
8. Update relevant files after making changes.

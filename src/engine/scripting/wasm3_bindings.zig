const std = @import("std");

pub const c = @cImport({
    @cInclude("wasm3.h");
});

pub const WasmError = error{
    EnvironmentInitFailed,
    RuntimeInitFailed,
    ParseModuleFailed,
    LoadModuleFailed,
    FunctionNotFound,
    LinkFunctionFailed,
    CallFailed,
    MemoryAccessOutOfBounds,
};

pub const WasmFunction = struct {
    raw: c.IM3Function,

    pub fn call0(self: WasmFunction) WasmError!void {
        const res = c.m3_CallV(self.raw);
        if (res != null) {
            std.log.err("Wasm function call error: {s}", .{res});
            return WasmError.CallFailed;
        }
    }

    pub fn call0RetU32(self: WasmFunction) WasmError!u32 {
        const res = c.m3_Call(self.raw, 0, null);
        if (res != null) {
            std.log.err("Wasm function call error: {s}", .{res});
            return WasmError.CallFailed;
        }
        var ret_val: u32 = 0;
        var ret_ptrs = [_]?*const anyopaque{@ptrCast(&ret_val)};
        const res_ret = c.m3_GetResults(self.raw, 1, @ptrCast(&ret_ptrs));
        if (res_ret != null) {
            std.log.err("Wasm get results error: {s}", .{res_ret});
            return WasmError.CallFailed;
        }
        return ret_val;
    }

    pub fn call1F32(self: WasmFunction, arg: f32) WasmError!void {
        const res = c.m3_CallV(self.raw, arg);
        if (res != null) {
            std.log.err("Wasm function call error: {s}", .{res});
            return WasmError.CallFailed;
        }
    }
};

pub fn getModuleLinearMemory(module: *WasmModule) ?[]u8 {
    var size: usize = 0;
    const mem_ptr = c.m3_GetMemory(module.raw, &size, 0);
    if (mem_ptr == null) return null;
    return mem_ptr[0..size];
}

pub const WasmModule = struct {
    raw: c.IM3Module,
    is_loaded: bool = false,

    pub fn linkFunction(
        self: *WasmModule,
        module_name: [:0]const u8,
        func_name: [:0]const u8,
        signature: [:0]const u8,
        handler: c.M3RawCall,
    ) WasmError!void {
        const res = c.m3_LinkRawFunction(self.raw, module_name.ptr, func_name.ptr, signature.ptr, handler);
        if (res != null) {
            // If the script doesn't import this particular host function, Wasm3 returns functionLookupFailed.
            // This is completely expected for unused APIs in mod scripts.
            if (res == c.m3Err_functionLookupFailed or std.mem.eql(u8, std.mem.span(res), "function lookup failed")) {
                return;
            }
            std.log.err("Failed to link '{s}::{s}' ({s}): {s}", .{ module_name, func_name, signature, res });
            return WasmError.LinkFunctionFailed;
        }
    }

    pub fn deinitUnloaded(self: *WasmModule) void {
        if (!self.is_loaded and self.raw != null) {
            c.m3_FreeModule(self.raw);
            self.raw = null;
        }
    }
};

pub const WasmRuntime = struct {
    raw: c.IM3Runtime,

    pub fn init(env: *WasmEnvironment, stack_size: u32, userdata: ?*anyopaque) WasmError!WasmRuntime {
        const rt = c.m3_NewRuntime(env.raw, stack_size, userdata) orelse return WasmError.RuntimeInitFailed;
        return .{ .raw = rt };
    }

    pub fn deinit(self: *WasmRuntime) void {
        if (self.raw != null) {
            c.m3_FreeRuntime(self.raw);
            self.raw = null;
        }
    }

    pub fn loadModule(self: *WasmRuntime, module: *WasmModule) WasmError!void {
        const res = c.m3_LoadModule(self.raw, module.raw);
        if (res != null) {
            std.log.err("Wasm m3_LoadModule failed: {s}", .{res});
            return WasmError.LoadModuleFailed;
        }
        module.is_loaded = true;
    }

    pub fn findFunction(self: *WasmRuntime, name: [:0]const u8) WasmError!WasmFunction {
        var func: c.IM3Function = null;
        const res = c.m3_FindFunction(&func, self.raw, name.ptr);
        if (res != null or func == null) {
            return WasmError.FunctionNotFound;
        }
        return .{ .raw = func };
    }

    pub fn getUserData(self: *WasmRuntime) ?*anyopaque {
        return c.m3_GetUserData(self.raw);
    }
};

pub const WasmEnvironment = struct {
    raw: c.IM3Environment,

    pub fn init() WasmError!WasmEnvironment {
        const env = c.m3_NewEnvironment() orelse return WasmError.EnvironmentInitFailed;
        return .{ .raw = env };
    }

    pub fn deinit(self: *WasmEnvironment) void {
        if (self.raw != null) {
            c.m3_FreeEnvironment(self.raw);
            self.raw = null;
        }
    }

    pub fn parseModule(self: *WasmEnvironment, wasm_bytes: []const u8) WasmError!WasmModule {
        var module: c.IM3Module = null;
        const res = c.m3_ParseModule(self.raw, &module, wasm_bytes.ptr, @intCast(wasm_bytes.len));
        if (res != null or module == null) {
            std.log.err("Wasm m3_ParseModule failed: {s}", .{res});
            return WasmError.ParseModuleFailed;
        }
        return .{ .raw = module, .is_loaded = false };
    }
};

/// Safely inspects guest linear memory with bounds checking against buffer overruns
pub fn getGuestMemorySlice(mem: ?*anyopaque, offset: u32, len: u32) ?[]const u8 {
    const memory = mem orelse return null;
    const mem_size = c.m3_GetMemorySizeAt(memory);
    if (@as(u64, offset) + @as(u64, len) > mem_size) {
        return null;
    }
    const base: [*]const u8 = @ptrCast(memory);
    return base[offset .. offset + len];
}

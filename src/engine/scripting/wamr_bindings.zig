const std = @import("std");

pub const c = @cImport({
    @cDefine("WASM_RUNTIME_API_EXTERN", "");
    @cInclude("wasm_export.h");
});

pub const PackageType = enum(u32) {
    bytecode = c.Wasm_Module_Bytecode,
    aot = c.Wasm_Module_AoT,
    unknown = c.Package_Type_Unknown,
};

pub const WasmError = error{
    EnvironmentInitFailed,
    RuntimeInitFailed,
    ParseModuleFailed,
    LoadModuleFailed,
    InstantiateModuleFailed,
    CreateExecEnvFailed,
    FunctionNotFound,
    LinkFunctionFailed,
    CallFailed,
    MemoryAccessOutOfBounds,
};

pub const WasmFunction = struct {
    raw: c.wasm_function_inst_t,
    exec_env: c.wasm_exec_env_t,
    module_inst: c.wasm_module_inst_t,

    pub fn call0(self: WasmFunction) WasmError!void {
        if (!c.wasm_runtime_call_wasm(self.exec_env, self.raw, 0, null)) {
            const err_msg = c.wasm_runtime_get_exception(self.module_inst);
            std.log.err("WAMR function call0 error: {s}", .{err_msg});
            return WasmError.CallFailed;
        }
    }

    pub fn call0RetU32(self: WasmFunction) WasmError!u32 {
        var argv: [1]u32 = [_]u32{0};
        if (!c.wasm_runtime_call_wasm(self.exec_env, self.raw, 0, &argv)) {
            const err_msg = c.wasm_runtime_get_exception(self.module_inst);
            std.log.err("WAMR function call0RetU32 error: {s}", .{err_msg});
            return WasmError.CallFailed;
        }
        return argv[0];
    }

    pub fn call1F32(self: WasmFunction, arg: f32) WasmError!void {
        var argv: [1]u32 = [_]u32{@as(u32, @bitCast(arg))};
        if (!c.wasm_runtime_call_wasm(self.exec_env, self.raw, 1, &argv)) {
            const err_msg = c.wasm_runtime_get_exception(self.module_inst);
            std.log.err("WAMR function call1F32 error: {s}", .{err_msg});
            return WasmError.CallFailed;
        }
    }
};

pub fn getModuleLinearMemory(module_inst: c.wasm_module_inst_t) ?[]u8 {
    const mem_inst = c.wasm_runtime_get_memory(module_inst, 0) orelse return null;
    const pages = c.wasm_memory_get_cur_page_count(mem_inst);
    if (pages == 0) return null;
    const bytes_per_page = c.wasm_memory_get_bytes_per_page(mem_inst);
    const page_size = if (bytes_per_page > 0) bytes_per_page else 65536;
    const total_size: usize = @intCast(pages * page_size);
    const base_ptr = c.wasm_memory_get_base_address(mem_inst) orelse return null;
    const ptr: [*]u8 = @ptrCast(base_ptr);
    return ptr[0..total_size];
}

pub fn getGuestMemorySlice(module_inst: c.wasm_module_inst_t, offset: u32, len: u32) ?[]const u8 {
    if (!c.wasm_runtime_validate_app_addr(module_inst, offset, len)) {
        return null;
    }
    const native_ptr = c.wasm_runtime_addr_app_to_native(module_inst, offset) orelse return null;
    const ptr: [*]const u8 = @ptrCast(native_ptr);
    return ptr[0..len];
}

pub fn getGuestMemorySliceMut(module_inst: c.wasm_module_inst_t, offset: u32, len: u32) ?[]u8 {
    if (!c.wasm_runtime_validate_app_addr(module_inst, offset, len)) {
        return null;
    }
    const native_ptr = c.wasm_runtime_addr_app_to_native(module_inst, offset) orelse return null;
    const ptr: [*]u8 = @ptrCast(native_ptr);
    return ptr[0..len];
}


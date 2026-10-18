const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl3");
const wgpu = @import("wgpu");

extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.c) ?*anyopaque;

pub const Window = struct {
    handle: *sdl.SDL_Window,
    width: u32,
    height: u32,

    pub fn init(title: [:0]const u8, width: u32, height: u32) !Window {
        if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_EVENTS)) {
            std.log.err("Failed to initialize SDL: {s}", .{sdl.SDL_GetError()});
            return error.SDLInitFailed;
        }

        const flags: sdl.SDL_WindowFlags = sdl.SDL_WINDOW_RESIZABLE | sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        const window = sdl.SDL_CreateWindow(
            title.ptr,
            @intCast(width),
            @intCast(height),
            flags,
        ) orelse {
            std.log.err("Failed to create SDL window: {s}", .{sdl.SDL_GetError()});
            return error.WindowCreationFailed;
        };

        var actual_w: c_int = 0;
        var actual_h: c_int = 0;
        _ = sdl.SDL_GetWindowSizeInPixels(window, &actual_w, &actual_h);

        return Window{
            .handle = window,
            .width = @intCast(@max(1, actual_w)),
            .height = @intCast(@max(1, actual_h)),
        };
    }

    pub fn deinit(self: *Window) void {
        sdl.SDL_DestroyWindow(self.handle);
        sdl.SDL_Quit();
    }

    pub fn updateSize(self: *Window) void {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = sdl.SDL_GetWindowSizeInPixels(self.handle, &w, &h);
        self.width = @intCast(@max(1, w));
        self.height = @intCast(@max(1, h));
    }

    pub fn setRelativeMouseMode(self: *Window, enabled: bool) bool {
        return sdl.SDL_SetWindowRelativeMouseMode(self.handle, enabled);
    }

    pub fn getRelativeMouseMode(self: *Window) bool {
        return sdl.SDL_GetWindowRelativeMouseMode(self.handle);
    }

    /// Creates a WGPU Surface compatible with this SDL window on Windows, Linux, and macOS.
    pub fn createWgpuSurface(self: *const Window, instance: *wgpu.Instance) !*wgpu.Surface {
        const props = sdl.SDL_GetWindowProperties(self.handle);
        if (props == 0) {
            std.log.err("Failed to get SDL window properties: {s}", .{sdl.SDL_GetError()});
            return error.WindowPropertiesFailed;
        }

        switch (builtin.os.tag) {
            .windows => {
                const hwnd = sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null);
                if (hwnd == null) {
                    std.log.err("Failed to get HWND from SDL window", .{});
                    return error.NoNativeWindow;
                }
                const hinstance_prop = sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_WIN32_INSTANCE_POINTER, null);
                const hinstance: *anyopaque = hinstance_prop orelse GetModuleHandleW(null).?;

                const surface_desc = wgpu.surfaceDescriptorFromWindowsHWND(.{
                    .label = "SDL3 Windows Surface",
                    .hwnd = hwnd.?,
                    .hinstance = hinstance,
                });
                return instance.createSurface(&surface_desc) orelse error.SurfaceCreationFailed;
            },
            .linux => {
                // Try Wayland first
                if (sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null)) |wl_surface| {
                    const wl_display = sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null);
                    if (wl_display != null) {
                        const surface_desc = wgpu.surfaceDescriptorFromWaylandSurface(.{
                            .label = "SDL3 Wayland Surface",
                            .display = wl_display.?,
                            .surface = wl_surface,
                        });
                        return instance.createSurface(&surface_desc) orelse error.SurfaceCreationFailed;
                    }
                }
                // Fallback to X11
                const x11_window_num = sdl.SDL_GetNumberProperty(props, sdl.SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);
                const x11_display = sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_X11_DISPLAY_POINTER, null);
                if (x11_window_num != 0 and x11_display != null) {
                    const surface_desc = wgpu.surfaceDescriptorFromXlibWindow(.{
                        .label = "SDL3 X11 Surface",
                        .display = x11_display.?,
                        .window = @intCast(x11_window_num),
                    });
                    return instance.createSurface(&surface_desc) orelse error.SurfaceCreationFailed;
                }
                return error.NoSupportedLinuxDisplayServer;
            },
            .macos => {
                // On macOS, Cocoa window with CAMetalLayer
                const nswindow = sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null);
                if (nswindow == null) {
                    return error.NoNativeWindow;
                }
                const metal_view = sdl.SDL_Metal_CreateView(self.handle);
                if (metal_view == null) {
                    return error.MetalViewFailed;
                }
                const metal_layer = sdl.SDL_Metal_GetLayer(metal_view);
                if (metal_layer == null) {
                    return error.MetalLayerFailed;
                }
                const surface_desc = wgpu.surfaceDescriptorFromMetalLayer(.{
                    .label = "SDL3 macOS Metal Surface",
                    .layer = metal_layer.?,
                });
                return instance.createSurface(&surface_desc) orelse error.SurfaceCreationFailed;
            },
            else => return error.UnsupportedPlatform,
        }
    }
};

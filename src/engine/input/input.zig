const std = @import("std");
const sdl = @import("sdl3");
const game_state = @import("../state/game_state.zig");
pub const ActionId = game_state.ActionId;
pub const AxisId = game_state.AxisId;
pub const InputStateShared = game_state.InputStateShared;

pub const InputState = struct {
    // Keyboard key states
    keys_down: [512]bool = [_]bool{false} ** 512,
    keys_pressed: [512]bool = [_]bool{false} ** 512,
    keys_released: [512]bool = [_]bool{false} ** 512,

    // Mouse state
    mouse_x: f32 = 0.0,
    mouse_y: f32 = 0.0,
    mouse_dx: f32 = 0.0,
    mouse_dy: f32 = 0.0,
    mouse_wheel: f32 = 0.0,
    mouse_buttons: [8]bool = [_]bool{false} ** 8,
    mouse_buttons_pressed: [8]bool = [_]bool{false} ** 8,

    // Window events
    should_quit: bool = false,
    resized: bool = false,
    new_width: u32 = 0,
    new_height: u32 = 0,

    pub fn init() InputState {
        return .{};
    }

    pub fn resetFrameDeltas(self: *InputState) void {
        self.mouse_dx = 0.0;
        self.mouse_dy = 0.0;
        self.mouse_wheel = 0.0;
        self.resized = false;
        @memset(&self.keys_pressed, false);
        @memset(&self.keys_released, false);
        @memset(&self.mouse_buttons_pressed, false);
    }

    pub fn pollEvents(self: *InputState) void {
        self.resetFrameDeltas();

        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event)) {
            switch (event.type) {
                sdl.SDL_EVENT_QUIT => {
                    self.should_quit = true;
                },
                sdl.SDL_EVENT_KEY_DOWN => {
                    const scancode = event.key.scancode;
                    if (scancode < 512) {
                        if (!self.keys_down[scancode]) {
                            self.keys_pressed[scancode] = true;
                        }
                        self.keys_down[scancode] = true;
                    }
                    if (scancode == sdl.SDL_SCANCODE_ESCAPE) {
                        self.should_quit = true;
                    }
                },
                sdl.SDL_EVENT_KEY_UP => {
                    const scancode = event.key.scancode;
                    if (scancode < 512) {
                        self.keys_down[scancode] = false;
                        self.keys_released[scancode] = true;
                    }
                },
                sdl.SDL_EVENT_MOUSE_MOTION => {
                    self.mouse_x = event.motion.x;
                    self.mouse_y = event.motion.y;
                    self.mouse_dx += event.motion.xrel;
                    self.mouse_dy += event.motion.yrel;
                },
                sdl.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    const btn = event.button.button;
                    if (btn < 8) {
                        if (!self.mouse_buttons[btn]) {
                            self.mouse_buttons_pressed[btn] = true;
                        }
                        self.mouse_buttons[btn] = true;
                    }
                },
                sdl.SDL_EVENT_MOUSE_BUTTON_UP => {
                    const btn = event.button.button;
                    if (btn < 8) {
                        self.mouse_buttons[btn] = false;
                    }
                },
                sdl.SDL_EVENT_MOUSE_WHEEL => {
                    self.mouse_wheel += event.wheel.y;
                },
                sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => {
                    self.resized = true;
                    self.new_width = @intCast(@max(1, event.window.data1));
                    self.new_height = @intCast(@max(1, event.window.data2));
                },
                else => {},
            }
        }
    }

    pub fn isKeyDown(self: *const InputState, scancode: sdl.SDL_Scancode) bool {
        if (scancode < 512) return self.keys_down[scancode];
        return false;
    }

    pub fn isKeyPressed(self: *const InputState, scancode: sdl.SDL_Scancode) bool {
        if (scancode < 512) return self.keys_pressed[scancode];
        return false;
    }

    pub fn isMouseButtonDown(self: *const InputState, button: u32) bool {
        if (button < 8) return self.mouse_buttons[button];
        return false;
    }

    pub fn isMouseButtonPressed(self: *const InputState, button: u32) bool {
        if (button < 8) return self.mouse_buttons_pressed[button];
        return false;
    }

    // ---------------------------------------------------------------------------------------------
    // Semantic Action & Axis Mapping
    // ---------------------------------------------------------------------------------------------

    pub fn isActionDown(self: *const InputState, action: ActionId) bool {
        return switch (action) {
            .move_forward => self.isKeyDown(sdl.SDL_SCANCODE_W) or self.isKeyDown(sdl.SDL_SCANCODE_UP),
            .move_backward => self.isKeyDown(sdl.SDL_SCANCODE_S) or self.isKeyDown(sdl.SDL_SCANCODE_DOWN),
            .move_left => self.isKeyDown(sdl.SDL_SCANCODE_A) or self.isKeyDown(sdl.SDL_SCANCODE_LEFT),
            .move_right => self.isKeyDown(sdl.SDL_SCANCODE_D) or self.isKeyDown(sdl.SDL_SCANCODE_RIGHT),
            .jump => self.isKeyDown(sdl.SDL_SCANCODE_SPACE),
            .sprint => self.isKeyDown(sdl.SDL_SCANCODE_LSHIFT),
            .crouch => self.isKeyDown(sdl.SDL_SCANCODE_LCTRL) or self.isKeyDown(sdl.SDL_SCANCODE_C),
            .interact => self.isKeyDown(sdl.SDL_SCANCODE_E),
            .primary_fire => self.mouse_buttons[sdl.SDL_BUTTON_LEFT] or self.isKeyDown(sdl.SDL_SCANCODE_RETURN),
            .secondary_fire => self.mouse_buttons[sdl.SDL_BUTTON_RIGHT],
            .pause => self.isKeyDown(sdl.SDL_SCANCODE_ESCAPE) or self.isKeyDown(sdl.SDL_SCANCODE_P),
            .reload => self.isKeyDown(sdl.SDL_SCANCODE_R),
            .custom0, .custom1, .custom2, .custom3 => false,
        };
    }

    pub fn isActionPressed(self: *const InputState, action: ActionId) bool {
        return switch (action) {
            .move_forward => self.isKeyPressed(sdl.SDL_SCANCODE_W) or self.isKeyPressed(sdl.SDL_SCANCODE_UP),
            .move_backward => self.isKeyPressed(sdl.SDL_SCANCODE_S) or self.isKeyPressed(sdl.SDL_SCANCODE_DOWN),
            .move_left => self.isKeyPressed(sdl.SDL_SCANCODE_A) or self.isKeyPressed(sdl.SDL_SCANCODE_LEFT),
            .move_right => self.isKeyPressed(sdl.SDL_SCANCODE_D) or self.isKeyPressed(sdl.SDL_SCANCODE_RIGHT),
            .jump => self.isKeyPressed(sdl.SDL_SCANCODE_SPACE),
            .sprint => self.isKeyPressed(sdl.SDL_SCANCODE_LSHIFT),
            .crouch => self.isKeyPressed(sdl.SDL_SCANCODE_LCTRL) or self.isKeyPressed(sdl.SDL_SCANCODE_C),
            .interact => self.isKeyPressed(sdl.SDL_SCANCODE_E),
            .primary_fire => self.mouse_buttons_pressed[sdl.SDL_BUTTON_LEFT] or self.isKeyPressed(sdl.SDL_SCANCODE_RETURN),
            .secondary_fire => self.mouse_buttons_pressed[sdl.SDL_BUTTON_RIGHT],
            .pause => self.isKeyPressed(sdl.SDL_SCANCODE_ESCAPE) or self.isKeyPressed(sdl.SDL_SCANCODE_P),
            .reload => self.isKeyPressed(sdl.SDL_SCANCODE_R),
            .custom0, .custom1, .custom2, .custom3 => false,
        };
    }

    pub fn getAxis(self: *const InputState, axis: AxisId) f32 {
        return switch (axis) {
            .move_x => blk: {
                var val: f32 = 0.0;
                if (self.isActionDown(.move_right)) val += 1.0;
                if (self.isActionDown(.move_left)) val -= 1.0;
                break :blk val;
            },
            .move_y => blk: {
                var val: f32 = 0.0;
                if (self.isActionDown(.move_forward)) val += 1.0;
                if (self.isActionDown(.move_backward)) val -= 1.0;
                break :blk val;
            },
            .look_x => self.mouse_dx,
            .look_y => self.mouse_dy,
            .wheel => self.mouse_wheel,
            .trigger_left => if (self.isActionDown(.secondary_fire)) 1.0 else 0.0,
            .trigger_right => if (self.isActionDown(.primary_fire)) 1.0 else 0.0,
            .custom0 => 0.0,
        };
    }

    /// Synchronizes input state into the shared memory block accessed zero-copy by guest scripts
    pub fn updateSharedState(self: *const InputState, shared: *InputStateShared) void {
        var down_mask: u32 = 0;
        var pressed_mask: u32 = 0;

        inline for (std.meta.fields(ActionId)) |field| {
            const action: ActionId = @enumFromInt(field.value);
            const bit = @as(u32, 1) << field.value;
            if (self.isActionDown(action)) {
                down_mask |= bit;
            }
            if (self.isActionPressed(action)) {
                pressed_mask |= bit;
            }
        }

        shared.actions_down = down_mask;
        shared.actions_pressed = pressed_mask;

        inline for (std.meta.fields(AxisId)) |field| {
            const axis: AxisId = @enumFromInt(field.value);
            shared.axes[field.value] = self.getAxis(axis);
        }

        shared.mouse_x = self.mouse_x;
        shared.mouse_y = self.mouse_y;
        shared.mouse_dx = self.mouse_dx;
        shared.mouse_dy = self.mouse_dy;
        shared.mouse_wheel = self.mouse_wheel;
    }
};

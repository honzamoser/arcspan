const std = @import("std");
const math = @import("../math.zig");
const input_mod = @import("../input/input.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Ray = math.Ray;
const InputState = input_mod.InputState;

pub const CameraMode = enum {
    free,
    first_person,
    third_person,
    rts,
};

pub const Camera = struct {
    position: Vec3 = Vec3.init(0.0, 1.6, 4.0),
    yaw: f32 = 0.0, // Radians around Y axis
    pitch: f32 = 0.0, // Radians (elevation)
    fov_deg: f32 = 55.0,
    aspect: f32 = 1.5,
    near: f32 = 0.1,
    far: f32 = 150.0,

    pub fn initDefault() Camera {
        return .{};
    }

    pub fn getForward(self: Camera) Vec3 {
        const cos_p = @cos(self.pitch);
        const sin_p = @sin(self.pitch);
        const cos_y = @cos(self.yaw);
        const sin_y = @sin(self.yaw);
        return Vec3.init(cos_p * sin_y, sin_p, cos_p * cos_y).normalize();
    }

    pub fn getRight(self: Camera) Vec3 {
        const cos_y = @cos(self.yaw);
        const sin_y = @sin(self.yaw);
        return Vec3.init(cos_y, 0.0, -sin_y).normalize();
    }

    pub fn getUp(self: Camera) Vec3 {
        return self.getRight().cross(self.getForward()).normalize();
    }

    pub fn getViewMatrix(self: Camera) Mat4 {
        const target = self.position.add(self.getForward());
        return Mat4.lookAt(self.position, target, Vec3.init(0.0, 1.0, 0.0));
    }

    pub fn getProjMatrix(self: Camera) Mat4 {
        const fov_rad = std.math.degreesToRadians(self.fov_deg);
        return Mat4.perspective(fov_rad, self.aspect, self.near, self.far);
    }

    pub fn getViewProjMatrix(self: Camera) Mat4 {
        return self.getProjMatrix().mul(self.getViewMatrix());
    }

    /// Converts a 2D screen coordinate (e.g. mouse cursor) into a 3D ray in world space.
    pub fn screenToRay(self: Camera, screen_x: f32, screen_y: f32, viewport_w: f32, viewport_h: f32) ?Ray {
        if (viewport_w <= 0.0 or viewport_h <= 0.0) return null;

        // Convert to WebGPU Normalized Device Coordinates: X in [-1, 1], Y in [-1, 1] (top is +1)
        const ndc_x = (2.0 * screen_x / viewport_w) - 1.0;
        const ndc_y = 1.0 - (2.0 * screen_y / viewport_h);

        const vp = self.getViewProjMatrix();
        const inv_vp = vp.inverse() orelse return null;

        const near_pt4 = inv_vp.transformVec4(.{ ndc_x, ndc_y, 0.0, 1.0 });
        const far_pt4 = inv_vp.transformVec4(.{ ndc_x, ndc_y, 1.0, 1.0 });

        if (@abs(near_pt4[3]) < 1e-7 or @abs(far_pt4[3]) < 1e-7) return null;

        const near_world = Vec3.init(near_pt4[0] / near_pt4[3], near_pt4[1] / near_pt4[3], near_pt4[2] / near_pt4[3]);
        const far_world = Vec3.init(far_pt4[0] / far_pt4[3], far_pt4[1] / far_pt4[3], far_pt4[2] / far_pt4[3]);

        const dir = far_world.sub(near_world).normalize();
        return Ray.init(near_world, dir);
    }

    /// Projects a 3D world space coordinate into 2D screen coordinates (pixels).
    /// Returns null if the point is behind the near plane or viewport is invalid.
    pub fn worldToScreen(self: Camera, world_pos: Vec3, viewport_w: f32, viewport_h: f32) ?struct { x: f32, y: f32 } {
        if (viewport_w <= 0.0 or viewport_h <= 0.0) return null;
        const vp = self.getViewProjMatrix();
        const pos4 = vp.transformVec4(.{ world_pos.x, world_pos.y, world_pos.z, 1.0 });
        if (pos4[3] <= 0.0) return null;
        const ndc_x = pos4[0] / pos4[3];
        const ndc_y = pos4[1] / pos4[3];
        const sx = (ndc_x + 1.0) * 0.5 * viewport_w;
        const sy = (1.0 - ndc_y) * 0.5 * viewport_h;
        return .{ .x = sx, .y = sy };
    }
};

/// First-Person Camera Controller:
/// Handles mouse look with pitch clamping (-89° to +89°) and camera-oriented WASD movement vectors.
pub const FpsCameraController = struct {
    camera: Camera = .{},
    walk_speed: f32 = 6.0,
    sprint_speed: f32 = 11.0,
    mouse_sensitivity: f32 = 0.0025,
    eye_height: f32 = 1.6,

    pub fn init(eye_height: f32) FpsCameraController {
        var c = FpsCameraController{};
        c.eye_height = eye_height;
        c.camera.position.y = eye_height;
        return c;
    }

    pub fn update(self: *FpsCameraController, input: *const InputState, dt: f32) void {
        // Mouse look
        const dx = input.mouse_dx * self.mouse_sensitivity;
        const dy = input.mouse_dy * self.mouse_sensitivity;
        self.camera.yaw += dx;
        self.camera.pitch -= dy;

        // Clamp pitch to avoid gimbal lock / flipping upside down (-89 deg to +89 deg)
        const max_pitch = std.math.degreesToRadians(89.0);
        self.camera.pitch = std.math.clamp(self.camera.pitch, -max_pitch, max_pitch);

        // Movement
        const speed = if (input.isActionDown(.sprint)) self.sprint_speed else self.walk_speed;
        const fwd_flat = Vec3.init(@sin(self.camera.yaw), 0.0, @cos(self.camera.yaw)).normalize();
        const right_flat = Vec3.init(@cos(self.camera.yaw), 0.0, -@sin(self.camera.yaw)).normalize();

        var move_dir = Vec3.zero;
        if (input.isActionDown(.move_forward)) move_dir = move_dir.add(fwd_flat);
        if (input.isActionDown(.move_backward)) move_dir = move_dir.sub(fwd_flat);
        if (input.isActionDown(.move_right)) move_dir = move_dir.add(right_flat);
        if (input.isActionDown(.move_left)) move_dir = move_dir.sub(right_flat);

        if (move_dir.length() > 0.001) {
            self.camera.position = self.camera.position.add(move_dir.normalize().scale(speed * dt));
        }
    }
};

/// Third-Person Orbit & Spring-Arm Camera Controller:
/// Follows a target point with orbit angles (yaw, pitch) and adjustable distance.
pub const ThirdPersonController = struct {
    camera: Camera = .{},
    target_pos: Vec3 = Vec3.zero,
    target_offset: Vec3 = Vec3.init(0.0, 1.2, 0.0),
    distance: f32 = 4.0,
    min_distance: f32 = 1.0,
    max_distance: f32 = 12.0,
    orbit_yaw: f32 = 0.0,
    orbit_pitch: f32 = 0.35, // Radians elevation
    mouse_sensitivity: f32 = 0.003,
    zoom_sensitivity: f32 = 0.8,

    pub fn init() ThirdPersonController {
        return .{};
    }

    pub fn update(self: *ThirdPersonController, input: *const InputState, dt: f32) void {
        _ = dt;
        // Mouse drag or look
        if (input.mouse_buttons[1] or input.isActionDown(.secondary_fire) or @abs(input.mouse_dx) > 0.01) {
            self.orbit_yaw += input.mouse_dx * self.mouse_sensitivity;
            self.orbit_pitch -= input.mouse_dy * self.mouse_sensitivity;
            const min_pitch = std.math.degreesToRadians(-10.0);
            const max_pitch = std.math.degreesToRadians(80.0);
            self.orbit_pitch = std.math.clamp(self.orbit_pitch, min_pitch, max_pitch);
        }

        // Mouse wheel zoom
        if (@abs(input.mouse_wheel) > 0.001) {
            self.distance -= input.mouse_wheel * self.zoom_sensitivity;
            self.distance = std.math.clamp(self.distance, self.min_distance, self.max_distance);
        }

        // Compute camera position relative to target
        const pivot = self.target_pos.add(self.target_offset);
        const cos_p = @cos(self.orbit_pitch);
        const sin_p = @sin(self.orbit_pitch);
        const cos_y = @cos(self.orbit_yaw);
        const sin_y = @sin(self.orbit_yaw);

        // Position camera behind the target
        const offset = Vec3.init(
            self.distance * cos_p * sin_y,
            self.distance * sin_p,
            self.distance * cos_p * cos_y,
        );

        self.camera.position = pivot.add(offset);
        // Look directly at the target pivot
        const look_dir = pivot.sub(self.camera.position).normalize();
        self.camera.yaw = std.math.atan2(look_dir.x, look_dir.z);
        self.camera.pitch = std.math.asin(look_dir.y);
    }
};

/// RTS Overhead Camera Controller:
/// Pans along the horizontal ground plane (XZ), tilts down at a configurable angle, and zooms.
pub const RtsCameraController = struct {
    camera: Camera = .{},
    focus_point: Vec3 = Vec3.init(0.0, 0.0, 0.0), // Ground focus position
    distance: f32 = 12.0,
    min_distance: f32 = 4.0,
    max_distance: f32 = 30.0,
    tilt_rad: f32 = std.math.degreesToRadians(55.0), // 55 degree downward tilt
    pan_speed: f32 = 14.0,
    zoom_speed: f32 = 1.8,

    pub fn init() RtsCameraController {
        var rts = RtsCameraController{};
        rts.recalculateCamera();
        return rts;
    }

    pub fn recalculateCamera(self: *RtsCameraController) void {
        const height = self.distance * @sin(self.tilt_rad);
        const back_dist = self.distance * @cos(self.tilt_rad);
        self.camera.position = Vec3.init(
            self.focus_point.x,
            self.focus_point.y + height,
            self.focus_point.z + back_dist,
        );
        const look_dir = self.focus_point.sub(self.camera.position).normalize();
        self.camera.yaw = std.math.atan2(look_dir.x, look_dir.z);
        self.camera.pitch = std.math.asin(look_dir.y);
    }

    pub fn update(self: *RtsCameraController, input: *const InputState, dt: f32) void {
        const speed = self.pan_speed * (self.distance / 12.0); // Scale pan speed with zoom
        var pan = Vec3.zero;

        if (input.isActionDown(.move_forward)) pan.z -= 1.0;
        if (input.isActionDown(.move_backward)) pan.z += 1.0;
        if (input.isActionDown(.move_left)) pan.x -= 1.0;
        if (input.isActionDown(.move_right)) pan.x += 1.0;

        // Middle mouse drag pan
        if (input.mouse_buttons[2]) {
            pan.x -= input.mouse_dx * 0.05;
            pan.z -= input.mouse_dy * 0.05;
        }

        if (pan.length() > 0.001) {
            self.focus_point = self.focus_point.add(pan.normalize().scale(speed * dt));
        }

        // Zoom via mouse wheel
        if (@abs(input.mouse_wheel) > 0.001) {
            self.distance -= input.mouse_wheel * self.zoom_speed;
            self.distance = std.math.clamp(self.distance, self.min_distance, self.max_distance);
        }

        self.recalculateCamera();
    }
};

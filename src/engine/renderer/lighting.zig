//! Dynamic Multi-Lighting & Cascaded Shadow Maps (CSM) Subsystem
//! Implements TASK-401 for Roblox-grade visual fidelity (Future-Is-Bright).
//! Complies with AGENTS.md: generic engine infrastructure in src/engine/renderer/.

const std = @import("std");
const wgpu = @import("wgpu");
const math = @import("../math.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Camera = @import("../camera/camera.zig").Camera;

pub const MAX_POINT_LIGHTS: usize = 16;
pub const MAX_SPOT_LIGHTS: usize = 8;
pub const NUM_CASCADES: usize = 3;

pub const PointLight = extern struct {
    position: [3]f32 = .{ 0.0, 0.0, 0.0 },
    radius: f32 = 10.0,
    color: [3]f32 = .{ 1.0, 1.0, 1.0 },
    intensity: f32 = 1.0,
};

pub const SpotLight = extern struct {
    position: [3]f32 = .{ 0.0, 0.0, 0.0 },
    inner_cone_cos: f32 = 0.95, // ~18 degrees
    direction: [3]f32 = .{ 0.0, -1.0, 0.0 },
    outer_cone_cos: f32 = 0.85, // ~31 degrees
    color: [3]f32 = .{ 1.0, 1.0, 1.0 },
    intensity: f32 = 1.0,
};

pub const DirectionalLight = extern struct {
    direction: [3]f32 = .{ -0.55, -0.82, -0.35 },
    intensity: f32 = 2.5,
    color: [3]f32 = .{ 1.0, 0.96, 0.88 },
    _pad: f32 = 0.0,
};

pub const LightingUniforms = extern struct {
    model: [4][4]f32,
    view_proj: [4][4]f32,
    camera_pos: [3]f32,
    time: f32,
    dir_light: DirectionalLight,
    cascade_splits: [4]f32, // x: split0, y: split1, z: split2, w: shadow_bias
    cascade_view_proj: [NUM_CASCADES][4][4]f32,
    ambient_color: [3]f32,
    ambient_intensity: f32,
    light_counts: [4]u32, // x: point count, y: spot count, z: shadows enabled (1 or 0), w: cascade count
    point_lights: [MAX_POINT_LIGHTS]PointLight,
    spot_lights: [MAX_SPOT_LIGHTS]SpotLight,
};

pub const DEFAULT_CASCADE_SPLITS = [4]f32{ 8.0, 25.0, 75.0, 0.0015 };

/// Calculates tightly bounded bounding-sphere CSM projection matrices for each cascade slice.
/// Uses spherical bounding volumes so the shadow maps remain stable without crawl/shimmer under camera rotation.
pub fn computeCascadeMatrices(camera: Camera, light_dir_in: Vec3, aspect: f32, splits: [4]f32) [NUM_CASCADES]Mat4 {
    var cascade_matrices: [NUM_CASCADES]Mat4 = undefined;

    const norm_dir = light_dir_in.normalize();
    const cam_fwd = camera.getForward().normalize();

    // Camera up and right
    const world_up = Vec3.init(0.0, 1.0, 0.0);
    var cam_right = world_up.cross(cam_fwd);
    if (cam_right.length() < 0.001) {
        cam_right = Vec3.init(1.0, 0.0, 0.0).cross(cam_fwd);
    }
    cam_right = cam_right.normalize();
    const cam_up = cam_fwd.cross(cam_right).normalize();

    const fov_rad = std.math.degreesToRadians(camera.fov_deg);
    const tan_half_fov = @tan(fov_rad * 0.5);

    var prev_split: f32 = camera.near;

    for (0..NUM_CASCADES) |i| {
        const split_far = splits[i];
        const split_near = prev_split;
        prev_split = split_far;

        // Frustum half dimensions at near and far split distances
        const near_h = split_near * tan_half_fov;
        const near_w = near_h * aspect;
        const far_h = split_far * tan_half_fov;
        const far_w = far_h * aspect;

        const near_center = camera.position.add(cam_fwd.scale(split_near));
        const far_center = camera.position.add(cam_fwd.scale(split_far));

        // 8 world space corners of the frustum split
        const corners = [_]Vec3{
            near_center.add(cam_up.scale(near_h)).add(cam_right.scale(near_w)),
            near_center.add(cam_up.scale(near_h)).sub(cam_right.scale(near_w)),
            near_center.sub(cam_up.scale(near_h)).add(cam_right.scale(near_w)),
            near_center.sub(cam_up.scale(near_h)).sub(cam_right.scale(near_w)),
            far_center.add(cam_up.scale(far_h)).add(cam_right.scale(far_w)),
            far_center.add(cam_up.scale(far_h)).sub(cam_right.scale(far_w)),
            far_center.sub(cam_up.scale(far_h)).add(cam_right.scale(far_w)),
            far_center.sub(cam_up.scale(far_h)).sub(cam_right.scale(far_w)),
        };

        // Center of the frustum split volume
        var center = Vec3.zero;
        for (corners) |c| {
            center = center.add(c);
        }
        center = center.scale(1.0 / 8.0);

        // Radius of bounding sphere enclosing all 8 corners
        var radius: f32 = 0.0;
        for (corners) |c| {
            const dist = c.sub(center).length();
            if (dist > radius) radius = dist;
        }
        // Round radius to 16-unit quantisation to stabilize texels
        radius = @ceil(radius * 16.0) / 16.0;

        // Light orientation: look along light_dir
        var light_up = Vec3.init(0.0, 1.0, 0.0);
        if (@abs(norm_dir.dot(light_up)) > 0.99) {
            light_up = Vec3.init(0.0, 0.0, 1.0);
        }

        const eye = center.sub(norm_dir.scale(radius * 2.0));
        const light_view = Mat4.lookAt(eye, center, light_up);
        const light_proj = Mat4.orthographic(-radius, radius, -radius, radius, 0.0, radius * 4.0);

        cascade_matrices[i] = light_proj.mul(light_view);
    }

    return cascade_matrices;
}

/// GPU Cascaded Shadow Map resource holding 3-split depth texture array & comparison sampler.
pub const ShadowMap = struct {
    pub const RESOLUTION: u32 = 2048;

    device: *wgpu.Device,
    texture: *wgpu.Texture,
    layer_views: [NUM_CASCADES]*wgpu.TextureView,
    array_view: *wgpu.TextureView,
    sampler: *wgpu.Sampler,

    pub fn init(device: *wgpu.Device) !ShadowMap {
        const tex = device.createTexture(&.{
            .label = wgpu.StringView.fromSlice("CSM Shadow Texture Array"),
            .usage = wgpu.TextureUsages.render_attachment | wgpu.TextureUsages.texture_binding,
            .dimension = .@"2d",
            .size = .{
                .width = RESOLUTION,
                .height = RESOLUTION,
                .depth_or_array_layers = @intCast(NUM_CASCADES),
            },
            .format = .depth24_plus,
            .mip_level_count = 1,
            .sample_count = 1,
        }) orelse return error.ShadowTextureFailed;

        var layer_views: [NUM_CASCADES]*wgpu.TextureView = undefined;
        for (0..NUM_CASCADES) |i| {
            layer_views[i] = tex.createView(&.{
                .label = wgpu.StringView.fromSlice("CSM Layer View"),
                .format = .depth24_plus,
                .dimension = .@"2d",
                .base_mip_level = 0,
                .mip_level_count = 1,
                .base_array_layer = @intCast(i),
                .array_layer_count = 1,
                .aspect = .depth_only,
            }) orelse return error.ShadowLayerViewFailed;
        }

        const array_view = tex.createView(&.{
            .label = wgpu.StringView.fromSlice("CSM Array View"),
            .format = .depth24_plus,
            .dimension = .@"2d_array",
            .base_mip_level = 0,
            .mip_level_count = 1,
            .base_array_layer = 0,
            .array_layer_count = @intCast(NUM_CASCADES),
            .aspect = .depth_only,
        }) orelse return error.ShadowArrayViewFailed;

        const sampler = device.createSampler(&.{
            .label = wgpu.StringView.fromSlice("CSM Comparison Sampler"),
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
            .compare = .less_equal,
        }) orelse return error.ShadowSamplerFailed;

        return ShadowMap{
            .device = device,
            .texture = tex,
            .layer_views = layer_views,
            .array_view = array_view,
            .sampler = sampler,
        };
    }

    pub fn deinit(self: *ShadowMap) void {
        self.sampler.release();
        self.array_view.release();
        for (self.layer_views) |view| {
            view.release();
        }
        self.texture.destroy();
        self.texture.release();
    }
};

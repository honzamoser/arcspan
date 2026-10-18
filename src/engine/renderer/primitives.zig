const std = @import("std");
const math = @import("../math.zig");
const Vec3 = math.Vec3;

pub const Vertex = extern struct {
    position: [3]f32,
    normal: [3]f32 = [_]f32{ 0.0, 1.0, 0.0 },
    color: [3]f32 = [_]f32{ 1.0, 1.0, 1.0 },
    uv: [2]f32 = [_]f32{ 0.0, 0.0 },
    material_params: [4]f32 = [_]f32{ 0.0, 0.5, 0.0, 0.0 }, // [metallic, roughness, emissive, shading_model]
    _pad: f32 = 0.0,
};

pub const PrimitiveType = enum(u32) {
    cube = 0,
    sphere = 1,
    pyramid = 2,
    cylinder = 3,
    plane = 4,
};

pub const PrimitiveMesh = struct {
    vertices: []const Vertex,
    indices: []const u16,
};

pub fn rotateVectorEuler(v: [3]f32, rot: [3]f32) [3]f32 {
    var p = v;
    if (rot[0] != 0.0) {
        const cx = @cos(rot[0]);
        const sx = @sin(rot[0]);
        const y = p[1] * cx - p[2] * sx;
        const z = p[1] * sx + p[2] * cx;
        p[1] = y;
        p[2] = z;
    }
    if (rot[1] != 0.0) {
        const cy = @cos(rot[1]);
        const sy = @sin(rot[1]);
        const x = p[0] * cy + p[2] * sy;
        const z = -p[0] * sy + p[2] * cy;
        p[0] = x;
        p[2] = z;
    }
    if (rot[2] != 0.0) {
        const cz = @cos(rot[2]);
        const sz = @sin(rot[2]);
        const x = p[0] * cz - p[1] * sz;
        const y = p[0] * sz + p[1] * cz;
        p[0] = x;
        p[1] = y;
    }
    return p;
}

// -------------------------------------------------------------------------------------------------
// Static Template Geometry
// -------------------------------------------------------------------------------------------------

// 1. CUBE (24 vertices, 36 indices with full surface normals)
pub const cube_vertices = [_]Vertex{
    // Front face (normal: 0, 0, 1)
    .{ .position = .{ -0.5, -0.5,  0.5 }, .normal = .{  0.0,  0.0,  1.0 }, .color = .{ 0.95, 0.25, 0.25 }, .uv = .{ 0.0, 0.0 } },
    .{ .position = .{  0.5, -0.5,  0.5 }, .normal = .{  0.0,  0.0,  1.0 }, .color = .{ 0.95, 0.40, 0.25 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{  0.5,  0.5,  0.5 }, .normal = .{  0.0,  0.0,  1.0 }, .color = .{ 0.95, 0.60, 0.25 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{ -0.5,  0.5,  0.5 }, .normal = .{  0.0,  0.0,  1.0 }, .color = .{ 0.95, 0.25, 0.40 }, .uv = .{ 0.0, 1.0 } },

    // Back face (normal: 0, 0, -1)
    .{ .position = .{ -0.5, -0.5, -0.5 }, .normal = .{  0.0,  0.0, -1.0 }, .color = .{ 0.20, 0.50, 0.95 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{ -0.5,  0.5, -0.5 }, .normal = .{  0.0,  0.0, -1.0 }, .color = .{ 0.20, 0.70, 0.95 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{  0.5,  0.5, -0.5 }, .normal = .{  0.0,  0.0, -1.0 }, .color = .{ 0.20, 0.90, 0.95 }, .uv = .{ 0.0, 1.0 } },
    .{ .position = .{  0.5, -0.5, -0.5 }, .normal = .{  0.0,  0.0, -1.0 }, .color = .{ 0.30, 0.40, 0.95 }, .uv = .{ 0.0, 0.0 } },

    // Top face (normal: 0, 1, 0)
    .{ .position = .{ -0.5,  0.5, -0.5 }, .normal = .{  0.0,  1.0,  0.0 }, .color = .{ 0.25, 0.95, 0.40 }, .uv = .{ 0.0, 1.0 } },
    .{ .position = .{ -0.5,  0.5,  0.5 }, .normal = .{  0.0,  1.0,  0.0 }, .color = .{ 0.35, 0.95, 0.50 }, .uv = .{ 0.0, 0.0 } },
    .{ .position = .{  0.5,  0.5,  0.5 }, .normal = .{  0.0,  1.0,  0.0 }, .color = .{ 0.50, 0.95, 0.30 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{  0.5,  0.5, -0.5 }, .normal = .{  0.0,  1.0,  0.0 }, .color = .{ 0.20, 0.95, 0.25 }, .uv = .{ 1.0, 1.0 } },

    // Bottom face (normal: 0, -1, 0)
    .{ .position = .{ -0.5, -0.5, -0.5 }, .normal = .{  0.0, -1.0,  0.0 }, .color = .{ 0.95, 0.90, 0.20 }, .uv = .{ 0.0, 0.0 } },
    .{ .position = .{  0.5, -0.5, -0.5 }, .normal = .{  0.0, -1.0,  0.0 }, .color = .{ 0.95, 0.80, 0.20 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{  0.5, -0.5,  0.5 }, .normal = .{  0.0, -1.0,  0.0 }, .color = .{ 0.95, 0.70, 0.20 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{ -0.5, -0.5,  0.5 }, .normal = .{  0.0, -1.0,  0.0 }, .color = .{ 0.95, 0.85, 0.30 }, .uv = .{ 0.0, 1.0 } },

    // Right face (normal: 1, 0, 0)
    .{ .position = .{  0.5, -0.5, -0.5 }, .normal = .{  1.0,  0.0,  0.0 }, .color = .{ 0.85, 0.25, 0.90 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{  0.5,  0.5, -0.5 }, .normal = .{  1.0,  0.0,  0.0 }, .color = .{ 0.75, 0.20, 0.85 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{  0.5,  0.5,  0.5 }, .normal = .{  1.0,  0.0,  0.0 }, .color = .{ 0.90, 0.30, 0.95 }, .uv = .{ 0.0, 1.0 } },
    .{ .position = .{  0.5, -0.5,  0.5 }, .normal = .{  1.0,  0.0,  0.0 }, .color = .{ 0.70, 0.15, 0.80 }, .uv = .{ 0.0, 0.0 } },

    // Left face (normal: -1, 0, 0)
    .{ .position = .{ -0.5, -0.5, -0.5 }, .normal = .{ -1.0,  0.0,  0.0 }, .color = .{ 0.20, 0.85, 0.80 }, .uv = .{ 0.0, 0.0 } },
    .{ .position = .{ -0.5, -0.5,  0.5 }, .normal = .{ -1.0,  0.0,  0.0 }, .color = .{ 0.15, 0.75, 0.70 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{ -0.5,  0.5,  0.5 }, .normal = .{ -1.0,  0.0,  0.0 }, .color = .{ 0.25, 0.95, 0.90 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{ -0.5,  0.5, -0.5 }, .normal = .{ -1.0,  0.0,  0.0 }, .color = .{ 0.30, 0.80, 0.75 }, .uv = .{ 0.0, 1.0 } },
};

pub const cube_indices = [_]u16{
    0,  1,  2,  2,  3,  0,
    4,  5,  6,  6,  7,  4,
    8,  9,  10, 10, 11, 8,
    12, 13, 14, 14, 15, 12,
    16, 17, 18, 18, 19, 16,
    20, 21, 22, 22, 23, 20,
};

// 2. PYRAMID (16 vertices: 4 sides + 1 base, 18 indices)
pub const pyramid_vertices = [_]Vertex{
    // Front triangle (normal approx: 0, 0.6, 0.8)
    .{ .position = .{  0.0,  0.6,  0.0 }, .normal = .{  0.0, 0.6,  0.8 }, .color = .{ 0.95, 0.40, 0.20 }, .uv = .{ 0.5, 1.0 } },
    .{ .position = .{ -0.5, -0.4,  0.5 }, .normal = .{  0.0, 0.6,  0.8 }, .color = .{ 0.90, 0.35, 0.15 }, .uv = .{ 0.0, 0.0 } },
    .{ .position = .{  0.5, -0.4,  0.5 }, .normal = .{  0.0, 0.6,  0.8 }, .color = .{ 0.95, 0.45, 0.25 }, .uv = .{ 1.0, 0.0 } },
    // Right triangle (normal approx: 0.8, 0.6, 0)
    .{ .position = .{  0.0,  0.6,  0.0 }, .normal = .{  0.8, 0.6,  0.0 }, .color = .{ 0.90, 0.60, 0.20 }, .uv = .{ 0.5, 1.0 } },
    .{ .position = .{  0.5, -0.4,  0.5 }, .normal = .{  0.8, 0.6,  0.0 }, .color = .{ 0.85, 0.55, 0.15 }, .uv = .{ 0.0, 0.0 } },
    .{ .position = .{  0.5, -0.4, -0.5 }, .normal = .{  0.8, 0.6,  0.0 }, .color = .{ 0.95, 0.65, 0.25 }, .uv = .{ 1.0, 0.0 } },
    // Back triangle (normal approx: 0, 0.6, -0.8)
    .{ .position = .{  0.0,  0.6,  0.0 }, .normal = .{  0.0, 0.6, -0.8 }, .color = .{ 0.80, 0.30, 0.10 }, .uv = .{ 0.5, 1.0 } },
    .{ .position = .{  0.5, -0.4, -0.5 }, .normal = .{  0.0, 0.6, -0.8 }, .color = .{ 0.75, 0.25, 0.10 }, .uv = .{ 0.0, 0.0 } },
    .{ .position = .{ -0.5, -0.4, -0.5 }, .normal = .{  0.0, 0.6, -0.8 }, .color = .{ 0.85, 0.35, 0.15 }, .uv = .{ 1.0, 0.0 } },
    // Left triangle (normal approx: -0.8, 0.6, 0)
    .{ .position = .{  0.0,  0.6,  0.0 }, .normal = .{ -0.8, 0.6,  0.0 }, .color = .{ 0.85, 0.45, 0.15 }, .uv = .{ 0.5, 1.0 } },
    .{ .position = .{ -0.5, -0.4, -0.5 }, .normal = .{ -0.8, 0.6,  0.0 }, .color = .{ 0.80, 0.40, 0.10 }, .uv = .{ 0.0, 0.0 } },
    .{ .position = .{ -0.5, -0.4,  0.5 }, .normal = .{ -0.8, 0.6,  0.0 }, .color = .{ 0.90, 0.50, 0.20 }, .uv = .{ 1.0, 0.0 } },
    // Base quad (normal: 0, -1, 0)
    .{ .position = .{ -0.5, -0.4, -0.5 }, .normal = .{  0.0, -1.0, 0.0 }, .color = .{ 0.60, 0.25, 0.10 }, .uv = .{ 0.0, 0.0 } },
    .{ .position = .{  0.5, -0.4, -0.5 }, .normal = .{  0.0, -1.0, 0.0 }, .color = .{ 0.60, 0.25, 0.10 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{  0.5, -0.4,  0.5 }, .normal = .{  0.0, -1.0, 0.0 }, .color = .{ 0.60, 0.25, 0.10 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{ -0.5, -0.4,  0.5 }, .normal = .{  0.0, -1.0, 0.0 }, .color = .{ 0.60, 0.25, 0.10 }, .uv = .{ 0.0, 1.0 } },
};

pub const pyramid_indices = [_]u16{
    0, 1, 2,       // Front
    3, 4, 5,       // Right
    6, 7, 8,       // Back
    9, 10, 11,     // Left
    12, 13, 14, 14, 15, 12, // Base
};

// 3. PLANE / QUAD (4 vertices, 6 indices with upward normal)
pub const plane_vertices = [_]Vertex{
    .{ .position = .{ -0.5, 0.0, -0.5 }, .normal = .{ 0.0, 1.0, 0.0 }, .color = .{ 0.4, 0.4, 0.45 }, .uv = .{ 0.0, 0.0 } },
    .{ .position = .{  0.5, 0.0, -0.5 }, .normal = .{ 0.0, 1.0, 0.0 }, .color = .{ 0.45, 0.45, 0.5 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{  0.5, 0.0,  0.5 }, .normal = .{ 0.0, 1.0, 0.0 }, .color = .{ 0.5, 0.5, 0.55 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{ -0.5, 0.0,  0.5 }, .normal = .{ 0.0, 1.0, 0.0 }, .color = .{ 0.45, 0.45, 0.5 }, .uv = .{ 0.0, 1.0 } },
};

pub const plane_indices = [_]u16{
    0, 2, 1,
    0, 3, 2,
};

// 4. SPHERE (UV Sphere generator with surface normals)
pub const SPHERE_RINGS: usize = 12;
pub const SPHERE_SECTORS: usize = 16;
pub const SPHERE_VERTEX_COUNT: usize = (SPHERE_RINGS + 1) * (SPHERE_SECTORS + 1);
pub const SPHERE_INDEX_COUNT: usize = SPHERE_RINGS * SPHERE_SECTORS * 6;

pub fn generateSphereTemplate() struct { vertices: [SPHERE_VERTEX_COUNT]Vertex, indices: [SPHERE_INDEX_COUNT]u16 } {
    var vertices: [SPHERE_VERTEX_COUNT]Vertex = undefined;
    var indices: [SPHERE_INDEX_COUNT]u16 = undefined;

    const R = SPHERE_RINGS;
    const S = SPHERE_SECTORS;
    var v_idx: usize = 0;

    for (0..R + 1) |r| {
        const theta = @as(f32, @floatFromInt(r)) * std.math.pi / @as(f32, @floatFromInt(R));
        const sin_t = @sin(theta);
        const cos_t = @cos(theta);

        for (0..S + 1) |s| {
            const phi = @as(f32, @floatFromInt(s)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(S));
            const nx = sin_t * @cos(phi);
            const ny = cos_t;
            const nz = sin_t * @sin(phi);

            vertices[v_idx] = .{
                .position = .{ 0.5 * nx, 0.5 * ny, 0.5 * nz },
                .normal = .{ nx, ny, nz },
                .color = .{ 1.0, 1.0, 1.0 },
                .uv = .{ @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(S)), @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(R)) },
            };
            v_idx += 1;
        }
    }

    var i_idx: usize = 0;
    for (0..R) |r| {
        for (0..S) |s| {
            const cur = @as(u16, @intCast(r * (S + 1) + s));
            const next = cur + @as(u16, @intCast(S + 1));

            indices[i_idx + 0] = cur;
            indices[i_idx + 1] = cur + 1;
            indices[i_idx + 2] = next;

            indices[i_idx + 3] = cur + 1;
            indices[i_idx + 4] = next + 1;
            indices[i_idx + 5] = next;
            i_idx += 6;
        }
    }

    return .{ .vertices = vertices, .indices = indices };
}

// 5. CYLINDER (16 segments with side and cap normals)
pub const CYLINDER_SEGMENTS: usize = 16;
pub const CYLINDER_VERTEX_COUNT: usize = (CYLINDER_SEGMENTS + 1) * 4 + 2;
pub const CYLINDER_INDEX_COUNT: usize = CYLINDER_SEGMENTS * 12;

pub fn generateCylinderTemplate() struct { vertices: [CYLINDER_VERTEX_COUNT]Vertex, indices: [CYLINDER_INDEX_COUNT]u16 } {
    var vertices: [CYLINDER_VERTEX_COUNT]Vertex = undefined;
    var indices: [CYLINDER_INDEX_COUNT]u16 = undefined;

    const S = CYLINDER_SEGMENTS;
    const h = 0.5;
    const r_val = 0.4;
    var v_idx: usize = 0;

    // Side vertices with outward horizontal normals
    for (0..S + 1) |i| {
        const phi = @as(f32, @floatFromInt(i)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(S));
        const cos_p = @cos(phi);
        const sin_p = @sin(phi);

        vertices[v_idx] = .{
            .position = .{ r_val * cos_p, h, r_val * sin_p },
            .normal = .{ cos_p, 0.0, sin_p },
            .color = .{ 1.0, 1.0, 1.0 },
            .uv = .{ @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(S)), 1.0 },
        };
        vertices[v_idx + 1] = .{
            .position = .{ r_val * cos_p, -h, r_val * sin_p },
            .normal = .{ cos_p, 0.0, sin_p },
            .color = .{ 1.0, 1.0, 1.0 },
            .uv = .{ @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(S)), 0.0 },
        };
        v_idx += 2;
    }

    var i_idx: usize = 0;
    // Side quads
    for (0..S) |i| {
        const cur = @as(u16, @intCast(i * 2));
        indices[i_idx + 0] = cur;
        indices[i_idx + 1] = cur + 2;
        indices[i_idx + 2] = cur + 1;

        indices[i_idx + 3] = cur + 2;
        indices[i_idx + 4] = cur + 3;
        indices[i_idx + 5] = cur + 1;
        i_idx += 6;
    }

    // Top cap center
    const top_center_idx = @as(u16, @intCast(v_idx));
    vertices[v_idx] = .{ .position = .{ 0, h, 0 }, .normal = .{ 0, 1, 0 }, .color = .{ 1, 1, 1 }, .uv = .{ 0.5, 0.5 } };
    v_idx += 1;

    // Top cap ring
    const top_ring_start = @as(u16, @intCast(v_idx));
    for (0..S + 1) |i| {
        const phi = @as(f32, @floatFromInt(i)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(S));
        vertices[v_idx] = .{
            .position = .{ r_val * @cos(phi), h, r_val * @sin(phi) },
            .normal = .{ 0, 1, 0 },
            .color = .{ 1, 1, 1 },
            .uv = .{ 0.5 + 0.5 * @cos(phi), 0.5 + 0.5 * @sin(phi) },
        };
        v_idx += 1;
    }
    for (0..S) |i| {
        indices[i_idx + 0] = top_center_idx;
        indices[i_idx + 1] = top_ring_start + @as(u16, @intCast(i + 1));
        indices[i_idx + 2] = top_ring_start + @as(u16, @intCast(i));
        i_idx += 3;
    }

    // Bottom cap center
    const bot_center_idx = @as(u16, @intCast(v_idx));
    vertices[v_idx] = .{ .position = .{ 0, -h, 0 }, .normal = .{ 0, -1, 0 }, .color = .{ 1, 1, 1 }, .uv = .{ 0.5, 0.5 } };
    v_idx += 1;

    // Bottom cap ring
    const bot_ring_start = @as(u16, @intCast(v_idx));
    for (0..S + 1) |i| {
        const phi = @as(f32, @floatFromInt(i)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(S));
        vertices[v_idx] = .{
            .position = .{ r_val * @cos(phi), -h, r_val * @sin(phi) },
            .normal = .{ 0, -1, 0 },
            .color = .{ 1, 1, 1 },
            .uv = .{ 0.5 + 0.5 * @cos(phi), 0.5 + 0.5 * @sin(phi) },
        };
        v_idx += 1;
    }
    for (0..S) |i| {
        indices[i_idx + 0] = bot_center_idx;
        indices[i_idx + 1] = bot_ring_start + @as(u16, @intCast(i));
        indices[i_idx + 2] = bot_ring_start + @as(u16, @intCast(i + 1));
        i_idx += 3;
    }

    return .{ .vertices = vertices, .indices = indices };
}

pub const sphere_template = generateSphereTemplate();
pub const cylinder_template = generateCylinderTemplate();

pub fn getPrimitiveMesh(p_type: PrimitiveType) PrimitiveMesh {
    return switch (p_type) {
        .cube => .{ .vertices = &cube_vertices, .indices = &cube_indices },
        .pyramid => .{ .vertices = &pyramid_vertices, .indices = &pyramid_indices },
        .plane => .{ .vertices = &plane_vertices, .indices = &plane_indices },
        .sphere => .{ .vertices = &sphere_template.vertices, .indices = &sphere_template.indices },
        .cylinder => .{ .vertices = &cylinder_template.vertices, .indices = &cylinder_template.indices },
    };
}

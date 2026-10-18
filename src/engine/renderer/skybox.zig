//! Environment Skybox & Image-Based Lighting (IBL) Subsystem
//! Implements TASK-402 for realistic cubemap reflections and atmospheric background.
//! Complies with AGENTS.md: generic engine infrastructure in src/engine/renderer/.

const std = @import("std");
const wgpu = @import("wgpu");
const math = @import("../math.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

pub const SkyboxUniforms = extern struct {
    view: [4][4]f32,
    proj: [4][4]f32,
};

pub const CUBE_VERTICES = [_][3]f32{
    // -Z (Front)
    .{ -1.0,  1.0, -1.0 },
    .{ -1.0, -1.0, -1.0 },
    .{  1.0, -1.0, -1.0 },
    .{  1.0, -1.0, -1.0 },
    .{  1.0,  1.0, -1.0 },
    .{ -1.0,  1.0, -1.0 },

    // -X (Left)
    .{ -1.0, -1.0,  1.0 },
    .{ -1.0, -1.0, -1.0 },
    .{ -1.0,  1.0, -1.0 },
    .{ -1.0,  1.0, -1.0 },
    .{ -1.0,  1.0,  1.0 },
    .{ -1.0, -1.0,  1.0 },

    // +X (Right)
    .{  1.0, -1.0, -1.0 },
    .{  1.0, -1.0,  1.0 },
    .{  1.0,  1.0,  1.0 },
    .{  1.0,  1.0,  1.0 },
    .{  1.0,  1.0, -1.0 },
    .{  1.0, -1.0, -1.0 },

    // +Z (Back)
    .{ -1.0, -1.0,  1.0 },
    .{ -1.0,  1.0,  1.0 },
    .{  1.0,  1.0,  1.0 },
    .{  1.0,  1.0,  1.0 },
    .{  1.0, -1.0,  1.0 },
    .{ -1.0, -1.0,  1.0 },

    // +Y (Top)
    .{ -1.0,  1.0, -1.0 },
    .{  1.0,  1.0, -1.0 },
    .{  1.0,  1.0,  1.0 },
    .{  1.0,  1.0,  1.0 },
    .{ -1.0,  1.0,  1.0 },
    .{ -1.0,  1.0, -1.0 },

    // -Y (Bottom)
    .{ -1.0, -1.0, -1.0 },
    .{ -1.0, -1.0,  1.0 },
    .{  1.0, -1.0, -1.0 },
    .{  1.0, -1.0, -1.0 },
    .{ -1.0, -1.0,  1.0 },
    .{  1.0, -1.0,  1.0 },
};

/// Generates a procedural 6-face physical atmosphere cubemap with Rayleigh/Mie gradient and solar corona.
/// Faces ordered according to WebGPU cubemap spec: +X, -X, +Y, -Y, +Z, -Z.
pub fn generateProceduralSkybox(allocator: std.mem.Allocator, size: u32, sun_dir_in: Vec3) ![]u8 {
    const total_bytes = @as(usize, size) * size * 6 * 4;
    const pixels = try allocator.alloc(u8, total_bytes);
    errdefer allocator.free(pixels);

    const sun_dir = sun_dir_in.normalize();

    const fsize: f32 = @floatFromInt(size);

    for (0..6) |face| {
        const face_offset = face * size * size * 4;
        for (0..size) |y| {
            for (0..size) |x| {
                const fx = @as(f32, @floatFromInt(x));
                const fy = @as(f32, @floatFromInt(y));
                const u = (2.0 * (fx + 0.5) / fsize) - 1.0;
                const v = (2.0 * (fy + 0.5) / fsize) - 1.0;

                var dir: Vec3 = undefined;
                switch (face) {
                    0 => dir = Vec3.init(1.0, -v, -u),  // +X
                    1 => dir = Vec3.init(-1.0, -v, u),  // -X
                    2 => dir = Vec3.init(u, 1.0, v),   // +Y
                    3 => dir = Vec3.init(u, -1.0, -v),  // -Y
                    4 => dir = Vec3.init(u, -v, 1.0),   // +Z
                    5 => dir = Vec3.init(-u, -v, -1.0), // -Z
                    else => unreachable,
                }
                dir = dir.normalize();

                // Height atmosphere blend
                var sky_r: f32 = 0.0;
                var sky_g: f32 = 0.0;
                var sky_b: f32 = 0.0;

                if (dir.y >= 0.0) {
                    // Above horizon: blend from warm horizon to deep blue zenith
                    const t = @min(1.0, dir.y);
                    const t_exp = std.math.pow(f32, t, 0.45);
                    const horizon = [3]f32{ 0.70, 0.82, 0.94 };
                    const zenith = [3]f32{ 0.12, 0.35, 0.82 };
                    sky_r = std.math.lerp(horizon[0], zenith[0], t_exp);
                    sky_g = std.math.lerp(horizon[1], zenith[1], t_exp);
                    sky_b = std.math.lerp(horizon[2], zenith[2], t_exp);
                } else {
                    // Below horizon: blend from warm horizon to dark ground
                    const t = @min(1.0, -dir.y);
                    const horizon = [3]f32{ 0.70, 0.82, 0.94 };
                    const ground = [3]f32{ 0.10, 0.11, 0.14 };
                    sky_r = std.math.lerp(horizon[0], ground[0], t);
                    sky_g = std.math.lerp(horizon[1], ground[1], t);
                    sky_b = std.math.lerp(horizon[2], ground[2], t);
                }

                // Solar highlight and corona
                const sun_dot = @max(0.0, dir.dot(sun_dir));
                if (sun_dot > 0.0) {
                    const corona = std.math.pow(f32, sun_dot, 64.0) * 0.8;
                    sky_r += corona * 1.0;
                    sky_g += corona * 0.95;
                    sky_b += corona * 0.75;

                    if (sun_dot > 0.998) {
                        // Sharp solar disc
                        sky_r += 4.0;
                        sky_g += 3.8;
                        sky_b += 3.2;
                    }
                }

                const px_idx = face_offset + (y * size + x) * 4;
                pixels[px_idx + 0] = @intFromFloat(@min(255.0, sky_r * 255.0));
                pixels[px_idx + 1] = @intFromFloat(@min(255.0, sky_g * 255.0));
                pixels[px_idx + 2] = @intFromFloat(@min(255.0, sky_b * 255.0));
                pixels[px_idx + 3] = 255;
            }
        }
    }

    return pixels;
}

pub const Skybox = struct {
    pub const CUBEMAP_SIZE: u32 = 256;

    device: *wgpu.Device,
    queue: *wgpu.Queue,

    texture: *wgpu.Texture,
    cube_view: *wgpu.TextureView,
    sampler: *wgpu.Sampler,

    render_pipeline: *wgpu.RenderPipeline,
    pipeline_layout: *wgpu.PipelineLayout,
    bind_group_layout: *wgpu.BindGroupLayout,
    bind_group: *wgpu.BindGroup,

    uniform_buffer: *wgpu.Buffer,
    vertex_buffer: *wgpu.Buffer,

    pub fn init(device: *wgpu.Device, queue: *wgpu.Queue, target_format: wgpu.TextureFormat, depth_format: wgpu.TextureFormat) !Skybox {
        const shader_source = @embedFile("../shaders/skybox.wgsl");
        const shader_desc = wgpu.shaderModuleWGSLDescriptor(.{
            .label = "Skybox Shader",
            .code = shader_source,
        });
        const shader_module = device.createShaderModule(&shader_desc) orelse return error.ShaderCompilationFailed;
        defer shader_module.release();

        // 1. Procedural cubemap texture creation & upload
        const pixels = try generateProceduralSkybox(std.heap.page_allocator, CUBEMAP_SIZE, Vec3.init(0.55, 0.82, 0.35));
        defer std.heap.page_allocator.free(pixels);

        const tex = device.createTexture(&.{
            .label = wgpu.StringView.fromSlice("Skybox Cubemap Texture"),
            .usage = wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_dst,
            .dimension = .@"2d",
            .size = .{
                .width = CUBEMAP_SIZE,
                .height = CUBEMAP_SIZE,
                .depth_or_array_layers = 6,
            },
            .format = .rgba8_unorm,
            .mip_level_count = 1,
            .sample_count = 1,
        }) orelse return error.SkyboxTextureFailed;

        // Upload all 6 faces
        for (0..6) |face| {
            const face_bytes = pixels[face * CUBEMAP_SIZE * CUBEMAP_SIZE * 4 .. (face + 1) * CUBEMAP_SIZE * CUBEMAP_SIZE * 4];
            const copy_dst = wgpu.TexelCopyTextureInfo{
                .texture = tex,
                .mip_level = 0,
                .origin = .{ .x = 0, .y = 0, .z = @intCast(face) },
                .aspect = .all,
            };
            const copy_buf = wgpu.TexelCopyBufferLayout{
                .offset = 0,
                .bytes_per_row = CUBEMAP_SIZE * 4,
                .rows_per_image = CUBEMAP_SIZE,
            };
            const copy_size = wgpu.Extent3D{
                .width = CUBEMAP_SIZE,
                .height = CUBEMAP_SIZE,
                .depth_or_array_layers = 1,
            };
            queue.writeTexture(&copy_dst, face_bytes.ptr, face_bytes.len, &copy_buf, &copy_size);
        }

        const cube_view = tex.createView(&.{
            .label = wgpu.StringView.fromSlice("Skybox Cubemap View"),
            .format = .rgba8_unorm,
            .dimension = .cube,
            .base_mip_level = 0,
            .mip_level_count = 1,
            .base_array_layer = 0,
            .array_layer_count = 6,
            .aspect = .all,
        }) orelse return error.SkyboxCubeViewFailed;

        const sampler = device.createSampler(&.{
            .label = wgpu.StringView.fromSlice("Skybox Sampler"),
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
        }) orelse return error.SkyboxSamplerFailed;

        // 2. Uniform buffer
        const uniform_buf = device.createBuffer(&.{
            .label = wgpu.StringView.fromSlice("Skybox Uniform Buffer"),
            .usage = wgpu.BufferUsages.uniform | wgpu.BufferUsages.copy_dst,
            .size = @sizeOf(SkyboxUniforms),
            .mapped_at_creation = @intFromBool(false),
        }) orelse return error.SkyboxUniformBufferFailed;

        // 3. Vertex buffer
        const vertex_buf = device.createBuffer(&.{
            .label = wgpu.StringView.fromSlice("Skybox Vertex Buffer"),
            .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
            .size = @sizeOf([36][3]f32),
            .mapped_at_creation = @intFromBool(false),
        }) orelse return error.SkyboxVertexBufferFailed;
        queue.writeBuffer(vertex_buf, 0, &CUBE_VERTICES, @sizeOf([36][3]f32));

        // 4. Bind group layout
        const bgl_entries = [_]wgpu.BindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = wgpu.ShaderStages.vertex,
                .buffer = .{
                    .@"type" = .uniform,
                    .has_dynamic_offset = @intFromBool(false),
                    .min_binding_size = @sizeOf(SkyboxUniforms),
                },
            },
            .{
                .binding = 1,
                .visibility = wgpu.ShaderStages.fragment,
                .texture = .{
                    .sample_type = .float,
                    .view_dimension = .cube,
                    .multisampled = @intFromBool(false),
                },
            },
            .{
                .binding = 2,
                .visibility = wgpu.ShaderStages.fragment,
                .sampler = .{
                    .@"type" = .filtering,
                },
            },
        };
        const bgl = device.createBindGroupLayout(&.{
            .label = wgpu.StringView.fromSlice("Skybox Bind Group Layout"),
            .entry_count = bgl_entries.len,
            .entries = &bgl_entries,
        }) orelse return error.BindGroupLayoutFailed;

        const bg_entries = [_]wgpu.BindGroupEntry{
            .{
                .binding = 0,
                .buffer = uniform_buf,
                .offset = 0,
                .size = @sizeOf(SkyboxUniforms),
            },
            .{
                .binding = 1,
                .texture_view = cube_view,
            },
            .{
                .binding = 2,
                .sampler = sampler,
            },
        };
        const bg = device.createBindGroup(&.{
            .label = wgpu.StringView.fromSlice("Skybox Bind Group"),
            .layout = bgl,
            .entry_count = bg_entries.len,
            .entries = &bg_entries,
        }) orelse return error.BindGroupFailed;

        const pl_desc = wgpu.PipelineLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("Skybox Pipeline Layout"),
            .bind_group_layout_count = 1,
            .bind_group_layouts = @ptrCast(&bgl),
        };
        const pipeline_layout = device.createPipelineLayout(&pl_desc) orelse return error.PipelineLayoutFailed;

        const vertex_attrib = wgpu.VertexAttribute{
            .shader_location = 0,
            .offset = 0,
            .format = .float32x3,
        };
        const vertex_layout = wgpu.VertexBufferLayout{
            .array_stride = @sizeOf([3]f32),
            .step_mode = .vertex,
            .attribute_count = 1,
            .attributes = @ptrCast(&vertex_attrib),
        };

        const color_target = wgpu.ColorTargetState{
            .format = target_format,
            .blend = null,
            .write_mask = wgpu.ColorWriteMasks.all,
        };

        const fragment_state = wgpu.FragmentState{
            .module = shader_module,
            .entry_point = wgpu.StringView.fromSlice("fs_main"),
            .target_count = 1,
            .targets = @ptrCast(&color_target),
        };

        // Depth state: less_equal compare, no depth write
        const depth_stencil_state = wgpu.DepthStencilState{
            .format = depth_format,
            .depth_write_enabled = .false,
            .depth_compare = .less_equal,
            .stencil_front = .{},
            .stencil_back = .{},
        };

        const render_pipeline = device.createRenderPipeline(&.{
            .label = wgpu.StringView.fromSlice("Skybox Render Pipeline"),
            .layout = pipeline_layout,
            .vertex = .{
                .module = shader_module,
                .entry_point = wgpu.StringView.fromSlice("vs_main"),
                .buffer_count = 1,
                .buffers = @ptrCast(&vertex_layout),
            },
            .primitive = .{
                .topology = .triangle_list,
                .cull_mode = .none,
                .front_face = .ccw,
            },
            .depth_stencil = &depth_stencil_state,
            .multisample = .{
                .count = 1,
                .mask = 0xffffffff,
            },
            .fragment = &fragment_state,
        }) orelse return error.RenderPipelineFailed;

        return Skybox{
            .device = device,
            .queue = queue,
            .texture = tex,
            .cube_view = cube_view,
            .sampler = sampler,
            .render_pipeline = render_pipeline,
            .pipeline_layout = pipeline_layout,
            .bind_group_layout = bgl,
            .bind_group = bg,
            .uniform_buffer = uniform_buf,
            .vertex_buffer = vertex_buf,
        };
    }

    pub fn render(self: *Skybox, render_pass: *wgpu.RenderPassEncoder, view: Mat4, proj: Mat4) void {
        const uniforms = SkyboxUniforms{
            .view = view.m,
            .proj = proj.m,
        };
        self.queue.writeBuffer(self.uniform_buffer, 0, &uniforms, @sizeOf(SkyboxUniforms));

        render_pass.setPipeline(self.render_pipeline);
        render_pass.setBindGroup(0, self.bind_group, 0, null);
        render_pass.setVertexBuffer(0, self.vertex_buffer, 0, @sizeOf([36][3]f32));
        render_pass.draw(36, 1, 0, 0);
    }

    pub fn deinit(self: *Skybox) void {
        self.vertex_buffer.destroy();
        self.vertex_buffer.release();

        self.uniform_buffer.destroy();
        self.uniform_buffer.release();

        self.bind_group.release();
        self.bind_group_layout.release();
        self.pipeline_layout.release();
        self.render_pipeline.release();

        self.sampler.release();
        self.cube_view.release();
        self.texture.destroy();
        self.texture.release();
    }
};

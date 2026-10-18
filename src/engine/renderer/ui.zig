//! 2D UI & Signed Distance Field (SDF) Text Rendering Pipeline
//! Complies with AGENTS.md: generic engine infrastructure in src/engine/renderer/.

const std = @import("std");
const wgpu = @import("wgpu");
pub const FontAtlas = @import("font.zig").FontAtlas;
pub const GlyphMetrics = @import("font.zig").GlyphMetrics;

pub const UiVertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
    color: [4]f32,
    mode: f32, // 0.0 = solid quad, 1.0 = SDF font text
    _pad: f32 = 0.0,
};

pub const UiUniforms = extern struct {
    screen_size: [2]f32,
    _pad: [2]f32 = .{ 0.0, 0.0 },
};

pub const UiRenderer = struct {
    pub const MAX_VERTICES: usize = 16384;
    pub const MAX_INDICES: usize = 24576;

    device: *wgpu.Device,
    queue: *wgpu.Queue,

    render_pipeline: *wgpu.RenderPipeline,
    pipeline_layout: *wgpu.PipelineLayout,
    bind_group_layout: *wgpu.BindGroupLayout,
    bind_group: *wgpu.BindGroup,

    vertex_buffer: *wgpu.Buffer,
    index_buffer: *wgpu.Buffer,
    uniform_buffer: *wgpu.Buffer,

    font_texture: *wgpu.Texture,
    font_texture_view: *wgpu.TextureView,
    font_sampler: *wgpu.Sampler,
    font: FontAtlas,

    vertices: [MAX_VERTICES]UiVertex = undefined,
    indices: [MAX_INDICES]u16 = undefined,
    vertex_count: usize = 0,
    index_count: usize = 0,

    screen_width: f32 = 1024.0,
    screen_height: f32 = 680.0,

    pub fn init(device: *wgpu.Device, queue: *wgpu.Queue, surface_format: wgpu.TextureFormat, depth_format: ?wgpu.TextureFormat) !UiRenderer {
        const shader_source = @embedFile("../shaders/ui.wgsl");
        const shader_desc = wgpu.shaderModuleWGSLDescriptor(.{
            .label = "UI Shader",
            .code = shader_source,
        });
        const shader_module = device.createShaderModule(&shader_desc) orelse return error.ShaderCompilationFailed;
        defer shader_module.release();

        const uniform_buf = device.createBuffer(&.{
            .label = wgpu.StringView.fromSlice("UI Uniform Buffer"),
            .usage = wgpu.BufferUsages.uniform | wgpu.BufferUsages.copy_dst,
            .size = @sizeOf(UiUniforms),
            .mapped_at_creation = @intFromBool(false),
        }) orelse return error.UniformBufferFailed;

        // 1. Generate Signed Distance Field (SDF) Font Atlas Texture
        const font = FontAtlas.init();
        const font_texture = device.createTexture(&.{
            .label = wgpu.StringView.fromSlice("UI Font Atlas Texture"),
            .usage = wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_dst,
            .dimension = .@"2d",
            .size = .{
                .width = FontAtlas.ATLAS_WIDTH,
                .height = FontAtlas.ATLAS_HEIGHT,
                .depth_or_array_layers = 1,
            },
            .format = .rgba8_unorm,
            .mip_level_count = 1,
            .sample_count = 1,
        }) orelse return error.TextureCreationFailed;

        const atlas_bytes_count = FontAtlas.ATLAS_WIDTH * FontAtlas.ATLAS_HEIGHT * 4;
        const atlas_pixels = try std.heap.page_allocator.alloc(u8, atlas_bytes_count);
        defer std.heap.page_allocator.free(atlas_pixels);
        font.generateSdfRgba8(atlas_pixels);

        const copy_dst_info = wgpu.TexelCopyTextureInfo{
            .texture = font_texture,
            .mip_level = 0,
            .origin = .{},
            .aspect = .all,
        };
        const copy_buf_layout = wgpu.TexelCopyBufferLayout{
            .offset = 0,
            .bytes_per_row = FontAtlas.ATLAS_WIDTH * 4,
            .rows_per_image = FontAtlas.ATLAS_HEIGHT,
        };
        const copy_size = wgpu.Extent3D{
            .width = FontAtlas.ATLAS_WIDTH,
            .height = FontAtlas.ATLAS_HEIGHT,
            .depth_or_array_layers = 1,
        };
        queue.writeTexture(&copy_dst_info, atlas_pixels.ptr, atlas_pixels.len, &copy_buf_layout, &copy_size);

        const font_texture_view = font_texture.createView(&.{
            .label = wgpu.StringView.fromSlice("UI Font Texture View"),
            .format = .rgba8_unorm,
            .dimension = .@"2d",
            .base_mip_level = 0,
            .mip_level_count = 1,
            .base_array_layer = 0,
            .array_layer_count = 1,
            .aspect = .all,
        }) orelse return error.TextureViewFailed;

        const font_sampler = device.createSampler(&.{
            .label = wgpu.StringView.fromSlice("UI Font Sampler"),
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
        }) orelse return error.SamplerCreationFailed;

        // 2. Bind Group Layout (Uniforms + Texture + Sampler)
        const bgl_entries = [_]wgpu.BindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = wgpu.ShaderStages.vertex,
                .buffer = .{
                    .@"type" = .uniform,
                    .has_dynamic_offset = @intFromBool(false),
                    .min_binding_size = @sizeOf(UiUniforms),
                },
            },
            .{
                .binding = 1,
                .visibility = wgpu.ShaderStages.fragment,
                .texture = .{
                    .sample_type = .float,
                    .view_dimension = .@"2d",
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
            .label = wgpu.StringView.fromSlice("UI Bind Group Layout"),
            .entry_count = bgl_entries.len,
            .entries = &bgl_entries,
        }) orelse return error.BindGroupLayoutFailed;

        const bg_entries = [_]wgpu.BindGroupEntry{
            .{
                .binding = 0,
                .buffer = uniform_buf,
                .offset = 0,
                .size = @sizeOf(UiUniforms),
            },
            .{
                .binding = 1,
                .texture_view = font_texture_view,
            },
            .{
                .binding = 2,
                .sampler = font_sampler,
            },
        };

        const bind_group = device.createBindGroup(&.{
            .label = wgpu.StringView.fromSlice("UI Bind Group"),
            .layout = bgl,
            .entry_count = bg_entries.len,
            .entries = &bg_entries,
        }) orelse return error.BindGroupFailed;

        const pipeline_layout = device.createPipelineLayout(&.{
            .label = wgpu.StringView.fromSlice("UI Pipeline Layout"),
            .bind_group_layout_count = 1,
            .bind_group_layouts = @ptrCast(&bgl),
        }) orelse return error.PipelineLayoutFailed;

        const vertex_attribs = [_]wgpu.VertexAttribute{
            .{
                .shader_location = 0,
                .offset = @offsetOf(UiVertex, "position"),
                .format = .float32x2,
            },
            .{
                .shader_location = 1,
                .offset = @offsetOf(UiVertex, "uv"),
                .format = .float32x2,
            },
            .{
                .shader_location = 2,
                .offset = @offsetOf(UiVertex, "color"),
                .format = .float32x4,
            },
            .{
                .shader_location = 3,
                .offset = @offsetOf(UiVertex, "mode"),
                .format = .float32,
            },
        };

        const vertex_buffer_layout = wgpu.VertexBufferLayout{
            .array_stride = @sizeOf(UiVertex),
            .step_mode = .vertex,
            .attribute_count = vertex_attribs.len,
            .attributes = &vertex_attribs,
        };

        const color_target = wgpu.ColorTargetState{
            .format = surface_format,
            .blend = &wgpu.BlendState.alpha_blending,
            .write_mask = wgpu.ColorWriteMasks.all,
        };

        const fragment_state = wgpu.FragmentState{
            .module = shader_module,
            .entry_point = wgpu.StringView.fromSlice("fs_main"),
            .target_count = 1,
            .targets = @ptrCast(&color_target),
        };

        var depth_stencil_state: ?wgpu.DepthStencilState = null;
        if (depth_format) |df| {
            depth_stencil_state = wgpu.DepthStencilState{
                .format = df,
                .depth_write_enabled = .false,
                .depth_compare = .always,
                .stencil_front = .{},
                .stencil_back = .{},
            };
        }

        const render_pipeline = device.createRenderPipeline(&.{
            .label = wgpu.StringView.fromSlice("UI Render Pipeline"),
            .layout = pipeline_layout,
            .vertex = .{
                .module = shader_module,
                .entry_point = wgpu.StringView.fromSlice("vs_main"),
                .buffer_count = 1,
                .buffers = @ptrCast(&vertex_buffer_layout),
            },
            .primitive = .{
                .topology = .triangle_list,
                .cull_mode = .none,
            },
            .fragment = &fragment_state,
            .depth_stencil = if (depth_stencil_state) |*ds| ds else null,
            .multisample = .{},
        }) orelse return error.RenderPipelineFailed;


        const vertex_buf = device.createBuffer(&.{
            .label = wgpu.StringView.fromSlice("UI Vertex Buffer"),
            .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
            .size = MAX_VERTICES * @sizeOf(UiVertex),
            .mapped_at_creation = @intFromBool(false),
        }) orelse return error.VertexBufferFailed;

        const index_buf = device.createBuffer(&.{
            .label = wgpu.StringView.fromSlice("UI Index Buffer"),
            .usage = wgpu.BufferUsages.index | wgpu.BufferUsages.copy_dst,
            .size = MAX_INDICES * @sizeOf(u16),
            .mapped_at_creation = @intFromBool(false),
        }) orelse return error.IndexBufferFailed;

        return UiRenderer{
            .device = device,
            .queue = queue,
            .render_pipeline = render_pipeline,
            .pipeline_layout = pipeline_layout,
            .bind_group_layout = bgl,
            .bind_group = bind_group,
            .vertex_buffer = vertex_buf,
            .index_buffer = index_buf,
            .uniform_buffer = uniform_buf,
            .font_texture = font_texture,
            .font_texture_view = font_texture_view,
            .font_sampler = font_sampler,
            .font = font,
        };
    }

    pub fn setScreenSize(self: *UiRenderer, width: f32, height: f32) void {
        self.screen_width = width;
        self.screen_height = height;
    }

    pub fn begin(self: *UiRenderer) void {
        self.vertex_count = 0;
        self.index_count = 0;
    }

    pub fn drawRect(self: *UiRenderer, x: f32, y: f32, w: f32, h: f32, color: [4]f32) void {
        if (self.vertex_count + 4 > MAX_VERTICES or self.index_count + 6 > MAX_INDICES) return;

        const base_idx = @as(u16, @intCast(self.vertex_count));

        self.vertices[self.vertex_count + 0] = .{ .position = .{ x, y }, .uv = .{ 0.0, 0.0 }, .color = color, .mode = 0.0 };
        self.vertices[self.vertex_count + 1] = .{ .position = .{ x + w, y }, .uv = .{ 0.0, 0.0 }, .color = color, .mode = 0.0 };
        self.vertices[self.vertex_count + 2] = .{ .position = .{ x + w, y + h }, .uv = .{ 0.0, 0.0 }, .color = color, .mode = 0.0 };
        self.vertices[self.vertex_count + 3] = .{ .position = .{ x, y + h }, .uv = .{ 0.0, 0.0 }, .color = color, .mode = 0.0 };

        self.indices[self.index_count + 0] = base_idx + 0;
        self.indices[self.index_count + 1] = base_idx + 1;
        self.indices[self.index_count + 2] = base_idx + 2;
        self.indices[self.index_count + 3] = base_idx + 0;
        self.indices[self.index_count + 4] = base_idx + 2;
        self.indices[self.index_count + 5] = base_idx + 3;

        self.vertex_count += 4;
        self.index_count += 6;
    }

    pub fn drawRectBorder(self: *UiRenderer, x: f32, y: f32, w: f32, h: f32, thickness: f32, color: [4]f32) void {
        self.drawRect(x, y, w, thickness, color); // Top
        self.drawRect(x, y + h - thickness, w, thickness, color); // Bottom
        self.drawRect(x, y + thickness, thickness, h - 2.0 * thickness, color); // Left
        self.drawRect(x + w - thickness, y + thickness, thickness, h - 2.0 * thickness, color); // Right
    }

    pub fn drawCrosshair(self: *UiRenderer, cx: f32, cy: f32, size: f32, thickness: f32, color: [4]f32) void {
        const half_t = thickness * 0.5;
        self.drawRect(cx - size, cy - half_t, size * 2.0, thickness, color);
        self.drawRect(cx - half_t, cy - size, thickness, size * 2.0, color);
    }

    pub fn drawProgressBar(self: *UiRenderer, x: f32, y: f32, w: f32, h: f32, fraction: f32, fg_color: [4]f32, bg_color: [4]f32) void {
        self.drawRect(x, y, w, h, bg_color);
        self.drawRectBorder(x, y, w, h, 1.0, .{ 0.1, 0.1, 0.1, 0.9 });
        const clamped_frac = std.math.clamp(fraction, 0.0, 1.0);
        if (clamped_frac > 0.01) {
            self.drawRect(x + 1.0, y + 1.0, (w - 2.0) * clamped_frac, h - 2.0, fg_color);
        }
    }

    pub fn drawSelectionBox(self: *UiRenderer, x1: f32, y1: f32, x2: f32, y2: f32, fill_color: [4]f32, border_color: [4]f32) void {
        const x = @min(x1, x2);
        const y = @min(y1, y2);
        const w = @abs(x2 - x1);
        const h = @abs(y2 - y1);
        if (w > 1.0 and h > 1.0) {
            self.drawRect(x, y, w, h, fill_color);
            self.drawRectBorder(x, y, w, h, 1.5, border_color);
        }
    }

    /// Renders text using the Signed Distance Field (SDF) font atlas.
    pub fn drawText(self: *UiRenderer, text: []const u8, x: f32, y: f32, font_size: f32, color: [4]f32) void {
        var cur_x = x;
        var cur_y = y;
        // Quad size matches the 32x32 cell scale where the 8x8 glyph sits in 24x24 active area
        const quad_size = font_size * (32.0 / 24.0);
        const pad_offset = font_size * (4.0 / 24.0);

        for (text) |c| {
            if (c == '\n') {
                cur_x = x;
                cur_y += font_size * 1.25;
                continue;
            }

            const m = self.font.getMetrics(c);
            if (c != ' ') {
                if (self.vertex_count + 4 > MAX_VERTICES or self.index_count + 6 > MAX_INDICES) return;

                const qx = cur_x - pad_offset - m.bearing_x * font_size;
                const qy = cur_y - pad_offset;
                const base_idx = @as(u16, @intCast(self.vertex_count));

                self.vertices[self.vertex_count + 0] = .{ .position = .{ qx, qy }, .uv = .{ m.u0, m.v0 }, .color = color, .mode = 1.0 };
                self.vertices[self.vertex_count + 1] = .{ .position = .{ qx + quad_size, qy }, .uv = .{ m.u1, m.v0 }, .color = color, .mode = 1.0 };
                self.vertices[self.vertex_count + 2] = .{ .position = .{ qx + quad_size, qy + quad_size }, .uv = .{ m.u1, m.v1 }, .color = color, .mode = 1.0 };
                self.vertices[self.vertex_count + 3] = .{ .position = .{ qx, qy + quad_size }, .uv = .{ m.u0, m.v1 }, .color = color, .mode = 1.0 };

                self.indices[self.index_count + 0] = base_idx + 0;
                self.indices[self.index_count + 1] = base_idx + 1;
                self.indices[self.index_count + 2] = base_idx + 2;
                self.indices[self.index_count + 3] = base_idx + 0;
                self.indices[self.index_count + 4] = base_idx + 2;
                self.indices[self.index_count + 5] = base_idx + 3;

                self.vertex_count += 4;
                self.index_count += 6;
            }

            cur_x += m.advance * font_size;
        }
    }

    pub fn measureText(self: *const UiRenderer, text: []const u8, font_size: f32) [2]f32 {
        return self.font.measureText(text, font_size);
    }

    pub fn render(self: *UiRenderer, pass: *wgpu.RenderPassEncoder) void {
        if (self.index_count == 0) return;

        const ubo_data = UiUniforms{
            .screen_size = .{ self.screen_width, self.screen_height },
        };
        self.queue.writeBuffer(self.uniform_buffer, 0, &ubo_data, @sizeOf(UiUniforms));
        self.queue.writeBuffer(self.vertex_buffer, 0, self.vertices[0..self.vertex_count].ptr, self.vertex_count * @sizeOf(UiVertex));
        self.queue.writeBuffer(self.index_buffer, 0, self.indices[0..self.index_count].ptr, self.index_count * @sizeOf(u16));

        pass.setPipeline(self.render_pipeline);
        pass.setBindGroup(0, self.bind_group, 0, null);
        pass.setVertexBuffer(0, self.vertex_buffer, 0, self.vertex_count * @sizeOf(UiVertex));
        pass.setIndexBuffer(self.index_buffer, .uint16, 0, self.index_count * @sizeOf(u16));
        pass.drawIndexed(@intCast(self.index_count), 1, 0, 0, 0);
    }

    pub fn deinit(self: *UiRenderer) void {
        self.font_sampler.release();
        self.font_texture_view.release();
        self.font_texture.destroy();
        self.font_texture.release();
        self.index_buffer.destroy();
        self.index_buffer.release();
        self.vertex_buffer.destroy();
        self.vertex_buffer.release();
        self.uniform_buffer.destroy();
        self.uniform_buffer.release();
        self.bind_group.release();
        self.bind_group_layout.release();
        self.pipeline_layout.release();
        self.render_pipeline.release();
    }
};

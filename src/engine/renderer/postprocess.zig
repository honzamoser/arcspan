//! Post-Processing Pipeline (HDR, ACES Tone-Mapping, Bloom)
//! Implements TASK-403 for cinematic visual fidelity.
//! Complies with AGENTS.md: generic engine infrastructure in src/engine/renderer/.

const std = @import("std");
const wgpu = @import("wgpu");

pub const PostProcessUniforms = extern struct {
    bloom_intensity: f32 = 0.08,
    exposure: f32 = 1.0,
    gamma: f32 = 2.2,
    bright_threshold: f32 = 1.0,
    texel_size: [2]f32 = .{ 0.0, 0.0 },
    blur_dir: [2]f32 = .{ 1.0, 0.0 },
};

pub const PostProcessor = struct {
    device: *wgpu.Device,
    queue: *wgpu.Queue,
    surface_format: wgpu.TextureFormat,

    width: u32,
    height: u32,
    bloom_width: u32,
    bloom_height: u32,

    // HDR scene offscreen render target
    hdr_texture: *wgpu.Texture,
    hdr_view: *wgpu.TextureView,

    // Bloom ping-pong textures at half resolution
    bloom_tex_a: *wgpu.Texture,
    bloom_view_a: *wgpu.TextureView,

    bloom_tex_b: *wgpu.Texture,
    bloom_view_b: *wgpu.TextureView,

    sampler: *wgpu.Sampler,

    // Uniform buffers for passes
    uniform_buf_bright: *wgpu.Buffer,
    uniform_buf_blur_h: *wgpu.Buffer,
    uniform_buf_blur_v: *wgpu.Buffer,
    uniform_buf_comp: *wgpu.Buffer,

    // Pipelines
    bright_pipeline: *wgpu.RenderPipeline,
    blur_pipeline: *wgpu.RenderPipeline,
    composite_pipeline: *wgpu.RenderPipeline,

    // Bind groups
    bright_bg: *wgpu.BindGroup,
    blur_h_bg: *wgpu.BindGroup,
    blur_v_bg: *wgpu.BindGroup,
    composite_bg: *wgpu.BindGroup,

    bgl_bright: *wgpu.BindGroupLayout,
    bgl_blur: *wgpu.BindGroupLayout,
    bgl_comp: *wgpu.BindGroupLayout,

    pub fn init(device: *wgpu.Device, queue: *wgpu.Queue, surface_format: wgpu.TextureFormat, width: u32, height: u32) !PostProcessor {
        const w = @max(1, width);
        const h = @max(1, height);
        const bw = @max(1, w / 2);
        const bh = @max(1, h / 2);

        const sampler = device.createSampler(&.{
            .label = wgpu.StringView.fromSlice("PostProcess Linear Sampler"),
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
        }) orelse return error.SamplerCreationFailed;

        // 1. Create HDR offscreen texture (rgba16_float)
        const hdr_tex = device.createTexture(&.{
            .label = wgpu.StringView.fromSlice("HDR Scene Texture"),
            .usage = wgpu.TextureUsages.render_attachment | wgpu.TextureUsages.texture_binding,
            .dimension = .@"2d",
            .size = .{ .width = w, .height = h, .depth_or_array_layers = 1 },
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        }) orelse return error.HdrTextureFailed;
        const hdr_view = hdr_tex.createView(null) orelse return error.HdrViewFailed;

        // 2. Create Bloom ping-pong textures
        const bloom_a = device.createTexture(&.{
            .label = wgpu.StringView.fromSlice("Bloom Texture A"),
            .usage = wgpu.TextureUsages.render_attachment | wgpu.TextureUsages.texture_binding,
            .dimension = .@"2d",
            .size = .{ .width = bw, .height = bh, .depth_or_array_layers = 1 },
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        }) orelse return error.BloomTextureFailed;
        const bloom_view_a = bloom_a.createView(null) orelse return error.BloomViewFailed;

        const bloom_b = device.createTexture(&.{
            .label = wgpu.StringView.fromSlice("Bloom Texture B"),
            .usage = wgpu.TextureUsages.render_attachment | wgpu.TextureUsages.texture_binding,
            .dimension = .@"2d",
            .size = .{ .width = bw, .height = bh, .depth_or_array_layers = 1 },
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        }) orelse return error.BloomTextureFailed;
        const bloom_view_b = bloom_b.createView(null) orelse return error.BloomViewFailed;

        // 3. Compile WGSL Shader Module
        const shader_source = @embedFile("../shaders/postprocess.wgsl");
        const shader_desc = wgpu.shaderModuleWGSLDescriptor(.{
            .label = "PostProcess Shader",
            .code = shader_source,
        });
        const shader_module = device.createShaderModule(&shader_desc) orelse return error.ShaderCompilationFailed;
        defer shader_module.release();

        // 4. Uniform Buffers
        const ubo_bright = device.createBuffer(&.{
            .label = wgpu.StringView.fromSlice("UBO Bright Pass"),
            .usage = wgpu.BufferUsages.uniform | wgpu.BufferUsages.copy_dst,
            .size = @sizeOf(PostProcessUniforms),
            .mapped_at_creation = @intFromBool(false),
        }) orelse return error.UniformBufferFailed;

        const ubo_blur_h = device.createBuffer(&.{
            .label = wgpu.StringView.fromSlice("UBO Blur H"),
            .usage = wgpu.BufferUsages.uniform | wgpu.BufferUsages.copy_dst,
            .size = @sizeOf(PostProcessUniforms),
            .mapped_at_creation = @intFromBool(false),
        }) orelse return error.UniformBufferFailed;

        const ubo_blur_v = device.createBuffer(&.{
            .label = wgpu.StringView.fromSlice("UBO Blur V"),
            .usage = wgpu.BufferUsages.uniform | wgpu.BufferUsages.copy_dst,
            .size = @sizeOf(PostProcessUniforms),
            .mapped_at_creation = @intFromBool(false),
        }) orelse return error.UniformBufferFailed;

        const ubo_comp = device.createBuffer(&.{
            .label = wgpu.StringView.fromSlice("UBO Composite"),
            .usage = wgpu.BufferUsages.uniform | wgpu.BufferUsages.copy_dst,
            .size = @sizeOf(PostProcessUniforms),
            .mapped_at_creation = @intFromBool(false),
        }) orelse return error.UniformBufferFailed;

        // Initial uniform data uploads
        var uniforms_bright = PostProcessUniforms{
            .bright_threshold = 1.0,
            .texel_size = .{ 1.0 / @as(f32, @floatFromInt(w)), 1.0 / @as(f32, @floatFromInt(h)) },
        };
        queue.writeBuffer(ubo_bright, 0, &uniforms_bright, @sizeOf(PostProcessUniforms));

        var uniforms_blur_h = PostProcessUniforms{
            .texel_size = .{ 1.0 / @as(f32, @floatFromInt(bw)), 1.0 / @as(f32, @floatFromInt(bh)) },
            .blur_dir = .{ 1.0, 0.0 },
        };
        queue.writeBuffer(ubo_blur_h, 0, &uniforms_blur_h, @sizeOf(PostProcessUniforms));

        var uniforms_blur_v = PostProcessUniforms{
            .texel_size = .{ 1.0 / @as(f32, @floatFromInt(bw)), 1.0 / @as(f32, @floatFromInt(bh)) },
            .blur_dir = .{ 0.0, 1.0 },
        };
        queue.writeBuffer(ubo_blur_v, 0, &uniforms_blur_v, @sizeOf(PostProcessUniforms));

        var uniforms_comp = PostProcessUniforms{
            .bloom_intensity = 0.08,
            .exposure = 1.0,
            .gamma = 2.2,
        };
        queue.writeBuffer(ubo_comp, 0, &uniforms_comp, @sizeOf(PostProcessUniforms));

        // 5. Bright Pass Bind Group Layout & Pipeline
        const bgl_bright_entries = [_]wgpu.BindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = wgpu.ShaderStages.fragment,
                .buffer = .{ .@"type" = .uniform, .min_binding_size = @sizeOf(PostProcessUniforms) },
            },
            .{
                .binding = 1,
                .visibility = wgpu.ShaderStages.fragment,
                .texture = .{ .sample_type = .float, .view_dimension = .@"2d" },
            },
            .{
                .binding = 2,
                .visibility = wgpu.ShaderStages.fragment,
                .sampler = .{ .@"type" = .filtering },
            },
        };
        const bgl_bright = device.createBindGroupLayout(&.{
            .label = wgpu.StringView.fromSlice("BGL Bright Pass"),
            .entry_count = bgl_bright_entries.len,
            .entries = &bgl_bright_entries,
        }) orelse return error.BindGroupLayoutFailed;

        const bright_bg_entries = [_]wgpu.BindGroupEntry{
            .{ .binding = 0, .buffer = ubo_bright, .size = @sizeOf(PostProcessUniforms) },
            .{ .binding = 1, .texture_view = hdr_view },
            .{ .binding = 2, .sampler = sampler },
        };
        const bright_bg = device.createBindGroup(&.{
            .label = wgpu.StringView.fromSlice("BG Bright Pass"),
            .layout = bgl_bright,
            .entry_count = bright_bg_entries.len,
            .entries = &bright_bg_entries,
        }) orelse return error.BindGroupFailed;

        const pl_bright_desc = wgpu.PipelineLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("PL Bright Pass"),
            .bind_group_layout_count = 1,
            .bind_group_layouts = @ptrCast(&bgl_bright),
        };
        const pl_bright = device.createPipelineLayout(&pl_bright_desc) orelse return error.PipelineLayoutFailed;
        defer pl_bright.release();

        const color_target_hdr = wgpu.ColorTargetState{
            .format = .rgba16_float,
            .blend = null,
            .write_mask = wgpu.ColorWriteMasks.all,
        };

        const bright_pipeline = device.createRenderPipeline(&.{
            .label = wgpu.StringView.fromSlice("Pipeline Bright Pass"),
            .layout = pl_bright,
            .vertex = .{
                .module = shader_module,
                .entry_point = wgpu.StringView.fromSlice("vs_fullscreen"),
                .buffer_count = 0,
                .buffers = &[0]wgpu.VertexBufferLayout{},
            },
            .primitive = .{ .topology = .triangle_list },
            .multisample = .{ .count = 1, .mask = 0xffffffff },
            .fragment = &wgpu.FragmentState{
                .module = shader_module,
                .entry_point = wgpu.StringView.fromSlice("fs_bright_pass"),
                .target_count = 1,
                .targets = @ptrCast(&color_target_hdr),
            },
        }) orelse return error.RenderPipelineFailed;

        // 6. Blur Bind Group Layout & Pipeline
        const bgl_blur_entries = [_]wgpu.BindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = wgpu.ShaderStages.fragment,
                .buffer = .{ .@"type" = .uniform, .min_binding_size = @sizeOf(PostProcessUniforms) },
            },
            .{
                .binding = 1,
                .visibility = wgpu.ShaderStages.fragment,
                .texture = .{ .sample_type = .float, .view_dimension = .@"2d" },
            },
            .{
                .binding = 2,
                .visibility = wgpu.ShaderStages.fragment,
                .sampler = .{ .@"type" = .filtering },
            },
        };
        const bgl_blur = device.createBindGroupLayout(&.{
            .label = wgpu.StringView.fromSlice("BGL Blur"),
            .entry_count = bgl_blur_entries.len,
            .entries = &bgl_blur_entries,
        }) orelse return error.BindGroupLayoutFailed;

        const blur_h_bg_entries = [_]wgpu.BindGroupEntry{
            .{ .binding = 0, .buffer = ubo_blur_h, .size = @sizeOf(PostProcessUniforms) },
            .{ .binding = 1, .texture_view = bloom_view_a },
            .{ .binding = 2, .sampler = sampler },
        };
        const blur_h_bg = device.createBindGroup(&.{
            .label = wgpu.StringView.fromSlice("BG Blur H"),
            .layout = bgl_blur,
            .entry_count = blur_h_bg_entries.len,
            .entries = &blur_h_bg_entries,
        }) orelse return error.BindGroupFailed;

        const blur_v_bg_entries = [_]wgpu.BindGroupEntry{
            .{ .binding = 0, .buffer = ubo_blur_v, .size = @sizeOf(PostProcessUniforms) },
            .{ .binding = 1, .texture_view = bloom_view_b },
            .{ .binding = 2, .sampler = sampler },
        };
        const blur_v_bg = device.createBindGroup(&.{
            .label = wgpu.StringView.fromSlice("BG Blur V"),
            .layout = bgl_blur,
            .entry_count = blur_v_bg_entries.len,
            .entries = &blur_v_bg_entries,
        }) orelse return error.BindGroupFailed;

        const pl_blur_desc = wgpu.PipelineLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("PL Blur"),
            .bind_group_layout_count = 1,
            .bind_group_layouts = @ptrCast(&bgl_blur),
        };
        const pl_blur = device.createPipelineLayout(&pl_blur_desc) orelse return error.PipelineLayoutFailed;
        defer pl_blur.release();

        const blur_pipeline = device.createRenderPipeline(&.{
            .label = wgpu.StringView.fromSlice("Pipeline Blur"),
            .layout = pl_blur,
            .vertex = .{
                .module = shader_module,
                .entry_point = wgpu.StringView.fromSlice("vs_fullscreen"),
                .buffer_count = 0,
                .buffers = &[0]wgpu.VertexBufferLayout{},
            },
            .primitive = .{ .topology = .triangle_list },
            .multisample = .{ .count = 1, .mask = 0xffffffff },
            .fragment = &wgpu.FragmentState{
                .module = shader_module,
                .entry_point = wgpu.StringView.fromSlice("fs_blur"),
                .target_count = 1,
                .targets = @ptrCast(&color_target_hdr),
            },
        }) orelse return error.RenderPipelineFailed;

        // 7. Composite Pass Bind Group Layout & Pipeline (Writes to surface format)
        const bgl_comp_entries = [_]wgpu.BindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = wgpu.ShaderStages.fragment,
                .buffer = .{ .@"type" = .uniform, .min_binding_size = @sizeOf(PostProcessUniforms) },
            },
            .{
                .binding = 1,
                .visibility = wgpu.ShaderStages.fragment,
                .texture = .{ .sample_type = .float, .view_dimension = .@"2d" },
            },
            .{
                .binding = 2,
                .visibility = wgpu.ShaderStages.fragment,
                .sampler = .{ .@"type" = .filtering },
            },
            .{
                .binding = 3,
                .visibility = wgpu.ShaderStages.fragment,
                .texture = .{ .sample_type = .float, .view_dimension = .@"2d" },
            },
        };
        const bgl_comp = device.createBindGroupLayout(&.{
            .label = wgpu.StringView.fromSlice("BGL Composite"),
            .entry_count = bgl_comp_entries.len,
            .entries = &bgl_comp_entries,
        }) orelse return error.BindGroupLayoutFailed;

        const comp_bg_entries = [_]wgpu.BindGroupEntry{
            .{ .binding = 0, .buffer = ubo_comp, .size = @sizeOf(PostProcessUniforms) },
            .{ .binding = 1, .texture_view = hdr_view },
            .{ .binding = 2, .sampler = sampler },
            .{ .binding = 3, .texture_view = bloom_view_a },
        };
        const composite_bg = device.createBindGroup(&.{
            .label = wgpu.StringView.fromSlice("BG Composite"),
            .layout = bgl_comp,
            .entry_count = comp_bg_entries.len,
            .entries = &comp_bg_entries,
        }) orelse return error.BindGroupFailed;

        const pl_comp_desc = wgpu.PipelineLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("PL Composite"),
            .bind_group_layout_count = 1,
            .bind_group_layouts = @ptrCast(&bgl_comp),
        };
        const pl_comp = device.createPipelineLayout(&pl_comp_desc) orelse return error.PipelineLayoutFailed;
        defer pl_comp.release();

        const color_target_swapchain = wgpu.ColorTargetState{
            .format = surface_format,
            .blend = null,
            .write_mask = wgpu.ColorWriteMasks.all,
        };

        const composite_pipeline = device.createRenderPipeline(&.{
            .label = wgpu.StringView.fromSlice("Pipeline Composite"),
            .layout = pl_comp,
            .vertex = .{
                .module = shader_module,
                .entry_point = wgpu.StringView.fromSlice("vs_fullscreen"),
                .buffer_count = 0,
                .buffers = &[0]wgpu.VertexBufferLayout{},
            },
            .primitive = .{ .topology = .triangle_list },
            .multisample = .{ .count = 1, .mask = 0xffffffff },
            .fragment = &wgpu.FragmentState{
                .module = shader_module,
                .entry_point = wgpu.StringView.fromSlice("fs_composite"),
                .target_count = 1,
                .targets = @ptrCast(&color_target_swapchain),
            },
        }) orelse return error.RenderPipelineFailed;

        return PostProcessor{
            .device = device,
            .queue = queue,
            .surface_format = surface_format,
            .width = w,
            .height = h,
            .bloom_width = bw,
            .bloom_height = bh,
            .hdr_texture = hdr_tex,
            .hdr_view = hdr_view,
            .bloom_tex_a = bloom_a,
            .bloom_view_a = bloom_view_a,
            .bloom_tex_b = bloom_b,
            .bloom_view_b = bloom_view_b,
            .sampler = sampler,
            .uniform_buf_bright = ubo_bright,
            .uniform_buf_blur_h = ubo_blur_h,
            .uniform_buf_blur_v = ubo_blur_v,
            .uniform_buf_comp = ubo_comp,
            .bright_pipeline = bright_pipeline,
            .blur_pipeline = blur_pipeline,
            .composite_pipeline = composite_pipeline,
            .bright_bg = bright_bg,
            .blur_h_bg = blur_h_bg,
            .blur_v_bg = blur_v_bg,
            .composite_bg = composite_bg,
            .bgl_bright = bgl_bright,
            .bgl_blur = bgl_blur,
            .bgl_comp = bgl_comp,
        };
    }

    /// Resizes offscreen HDR and bloom textures when window size changes
    pub fn resize(self: *PostProcessor, new_width: u32, new_height: u32) !void {
        if (new_width == 0 or new_height == 0) return;
        if (new_width == self.width and new_height == self.height) return;

        self.width = new_width;
        self.height = new_height;
        self.bloom_width = @max(1, new_width / 2);
        self.bloom_height = @max(1, new_height / 2);

        // Release old textures, views, and bind groups
        self.bright_bg.release();
        self.blur_h_bg.release();
        self.blur_v_bg.release();
        self.composite_bg.release();

        self.hdr_view.release();
        self.hdr_texture.destroy();
        self.hdr_texture.release();

        self.bloom_view_a.release();
        self.bloom_tex_a.destroy();
        self.bloom_tex_a.release();

        self.bloom_view_b.release();
        self.bloom_tex_b.destroy();
        self.bloom_tex_b.release();

        // Recreate textures
        self.hdr_texture = self.device.createTexture(&.{
            .label = wgpu.StringView.fromSlice("HDR Scene Texture Resized"),
            .usage = wgpu.TextureUsages.render_attachment | wgpu.TextureUsages.texture_binding,
            .dimension = .@"2d",
            .size = .{ .width = self.width, .height = self.height, .depth_or_array_layers = 1 },
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        }).?;
        self.hdr_view = self.hdr_texture.createView(null).?;

        self.bloom_tex_a = self.device.createTexture(&.{
            .label = wgpu.StringView.fromSlice("Bloom Texture A Resized"),
            .usage = wgpu.TextureUsages.render_attachment | wgpu.TextureUsages.texture_binding,
            .dimension = .@"2d",
            .size = .{ .width = self.bloom_width, .height = self.bloom_height, .depth_or_array_layers = 1 },
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        }).?;
        self.bloom_view_a = self.bloom_tex_a.createView(null).?;

        self.bloom_tex_b = self.device.createTexture(&.{
            .label = wgpu.StringView.fromSlice("Bloom Texture B Resized"),
            .usage = wgpu.TextureUsages.render_attachment | wgpu.TextureUsages.texture_binding,
            .dimension = .@"2d",
            .size = .{ .width = self.bloom_width, .height = self.bloom_height, .depth_or_array_layers = 1 },
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        }).?;
        self.bloom_view_b = self.bloom_tex_b.createView(null).?;

        // Recreate bind groups
        const bright_bg_entries = [_]wgpu.BindGroupEntry{
            .{ .binding = 0, .buffer = self.uniform_buf_bright, .size = @sizeOf(PostProcessUniforms) },
            .{ .binding = 1, .texture_view = self.hdr_view },
            .{ .binding = 2, .sampler = self.sampler },
        };
        self.bright_bg = self.device.createBindGroup(&.{
            .label = wgpu.StringView.fromSlice("BG Bright Pass Resized"),
            .layout = self.bgl_bright,
            .entry_count = bright_bg_entries.len,
            .entries = &bright_bg_entries,
        }).?;

        const blur_h_bg_entries = [_]wgpu.BindGroupEntry{
            .{ .binding = 0, .buffer = self.uniform_buf_blur_h, .size = @sizeOf(PostProcessUniforms) },
            .{ .binding = 1, .texture_view = self.bloom_view_a },
            .{ .binding = 2, .sampler = self.sampler },
        };
        self.blur_h_bg = self.device.createBindGroup(&.{
            .label = wgpu.StringView.fromSlice("BG Blur H Resized"),
            .layout = self.bgl_blur,
            .entry_count = blur_h_bg_entries.len,
            .entries = &blur_h_bg_entries,
        }).?;

        const blur_v_bg_entries = [_]wgpu.BindGroupEntry{
            .{ .binding = 0, .buffer = self.uniform_buf_blur_v, .size = @sizeOf(PostProcessUniforms) },
            .{ .binding = 1, .texture_view = self.bloom_view_b },
            .{ .binding = 2, .sampler = self.sampler },
        };
        self.blur_v_bg = self.device.createBindGroup(&.{
            .label = wgpu.StringView.fromSlice("BG Blur V Resized"),
            .layout = self.bgl_blur,
            .entry_count = blur_v_bg_entries.len,
            .entries = &blur_v_bg_entries,
        }).?;

        const comp_bg_entries = [_]wgpu.BindGroupEntry{
            .{ .binding = 0, .buffer = self.uniform_buf_comp, .size = @sizeOf(PostProcessUniforms) },
            .{ .binding = 1, .texture_view = self.hdr_view },
            .{ .binding = 2, .sampler = self.sampler },
            .{ .binding = 3, .texture_view = self.bloom_view_a },
        };
        self.composite_bg = self.device.createBindGroup(&.{
            .label = wgpu.StringView.fromSlice("BG Composite Resized"),
            .layout = self.bgl_comp,
            .entry_count = comp_bg_entries.len,
            .entries = &comp_bg_entries,
        }).?;

        // Update texel size uniforms
        var uniforms_bright = PostProcessUniforms{
            .bright_threshold = 1.0,
            .texel_size = .{ 1.0 / @as(f32, @floatFromInt(self.width)), 1.0 / @as(f32, @floatFromInt(self.height)) },
        };
        self.queue.writeBuffer(self.uniform_buf_bright, 0, &uniforms_bright, @sizeOf(PostProcessUniforms));

        var uniforms_blur_h = PostProcessUniforms{
            .texel_size = .{ 1.0 / @as(f32, @floatFromInt(self.bloom_width)), 1.0 / @as(f32, @floatFromInt(self.bloom_height)) },
            .blur_dir = .{ 1.0, 0.0 },
        };
        self.queue.writeBuffer(self.uniform_buf_blur_h, 0, &uniforms_blur_h, @sizeOf(PostProcessUniforms));

        var uniforms_blur_v = PostProcessUniforms{
            .texel_size = .{ 1.0 / @as(f32, @floatFromInt(self.bloom_width)), 1.0 / @as(f32, @floatFromInt(self.bloom_height)) },
            .blur_dir = .{ 0.0, 1.0 },
        };
        self.queue.writeBuffer(self.uniform_buf_blur_v, 0, &uniforms_blur_v, @sizeOf(PostProcessUniforms));
    }

    /// Executes the full post-processing pass:
    /// 1. Extracts bright areas from hdr_view into bloom_tex_a
    /// 2. Blurs bloom_tex_a horizontally into bloom_tex_b
    /// 3. Blurs bloom_tex_b vertically into bloom_tex_a
    /// 4. Composites hdr_view + bloom_tex_a via ACES Tone-Mapping onto target swapchain view
    pub fn process(self: *PostProcessor, encoder: *wgpu.CommandEncoder, target_swapchain_view: *wgpu.TextureView) void {
        // Pass 1: Bright extraction pass (hdr -> bloom_tex_a)
        {
            const color_att = wgpu.ColorAttachment{
                .view = self.bloom_view_a,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
            };
            const pass = encoder.beginRenderPass(&.{
                .label = wgpu.StringView.fromSlice("Bloom Bright Pass"),
                .color_attachment_count = 1,
                .color_attachments = @ptrCast(&color_att),
            }).?;
            pass.setPipeline(self.bright_pipeline);
            pass.setBindGroup(0, self.bright_bg, 0, null);
            pass.draw(3, 1, 0, 0);
            pass.end();
            pass.release();
        }

        // Pass 2: Horizontal blur (bloom_tex_a -> bloom_tex_b)
        {
            const color_att = wgpu.ColorAttachment{
                .view = self.bloom_view_b,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
            };
            const pass = encoder.beginRenderPass(&.{
                .label = wgpu.StringView.fromSlice("Bloom Blur H Pass"),
                .color_attachment_count = 1,
                .color_attachments = @ptrCast(&color_att),
            }).?;
            pass.setPipeline(self.blur_pipeline);
            pass.setBindGroup(0, self.blur_h_bg, 0, null);
            pass.draw(3, 1, 0, 0);
            pass.end();
            pass.release();
        }

        // Pass 3: Vertical blur (bloom_tex_b -> bloom_tex_a)
        {
            const color_att = wgpu.ColorAttachment{
                .view = self.bloom_view_a,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
            };
            const pass = encoder.beginRenderPass(&.{
                .label = wgpu.StringView.fromSlice("Bloom Blur V Pass"),
                .color_attachment_count = 1,
                .color_attachments = @ptrCast(&color_att),
            }).?;
            pass.setPipeline(self.blur_pipeline);
            pass.setBindGroup(0, self.blur_v_bg, 0, null);
            pass.draw(3, 1, 0, 0);
            pass.end();
            pass.release();
        }

        // Pass 4: Fullscreen Composite (hdr + bloom_tex_a -> swapchain)
        {
            const color_att = wgpu.ColorAttachment{
                .view = target_swapchain_view,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
            };
            const pass = encoder.beginRenderPass(&.{
                .label = wgpu.StringView.fromSlice("Composite ToneMapping Pass"),
                .color_attachment_count = 1,
                .color_attachments = @ptrCast(&color_att),
            }).?;
            pass.setPipeline(self.composite_pipeline);
            pass.setBindGroup(0, self.composite_bg, 0, null);
            pass.draw(3, 1, 0, 0);
            pass.end();
            pass.release();
        }
    }

    pub fn deinit(self: *PostProcessor) void {
        self.composite_bg.release();
        self.blur_v_bg.release();
        self.blur_h_bg.release();
        self.bright_bg.release();

        self.bgl_comp.release();
        self.bgl_blur.release();
        self.bgl_bright.release();

        self.composite_pipeline.release();
        self.blur_pipeline.release();
        self.bright_pipeline.release();

        self.uniform_buf_comp.destroy();
        self.uniform_buf_comp.release();

        self.uniform_buf_blur_v.destroy();
        self.uniform_buf_blur_v.release();

        self.uniform_buf_blur_h.destroy();
        self.uniform_buf_blur_h.release();

        self.uniform_buf_bright.destroy();
        self.uniform_buf_bright.release();

        self.sampler.release();

        self.bloom_view_b.release();
        self.bloom_tex_b.destroy();
        self.bloom_tex_b.release();

        self.bloom_view_a.release();
        self.bloom_tex_a.destroy();
        self.bloom_tex_a.release();

        self.hdr_view.release();
        self.hdr_texture.destroy();
        self.hdr_texture.release();
    }
};

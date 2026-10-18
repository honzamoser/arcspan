const std = @import("std");
const wgpu = @import("wgpu");
const math = @import("../math.zig");
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Window = @import("../platform/window.zig").Window;
const Scene = @import("scene.zig").Scene;
const Vertex = @import("scene.zig").Vertex;
const Camera = @import("../camera/camera.zig").Camera;
pub const UiRenderer = @import("ui.zig").UiRenderer;

// Dynamic Multi-Lighting & CSM Subsystems
const lighting_mod = @import("lighting.zig");
pub const PointLight = lighting_mod.PointLight;
pub const SpotLight = lighting_mod.SpotLight;
pub const DirectionalLight = lighting_mod.DirectionalLight;
pub const LightingUniforms = lighting_mod.LightingUniforms;
pub const ShadowMap = lighting_mod.ShadowMap;
pub const computeCascadeMatrices = lighting_mod.computeCascadeMatrices;
pub const DEFAULT_CASCADE_SPLITS = lighting_mod.DEFAULT_CASCADE_SPLITS;
pub const NUM_CASCADES = lighting_mod.NUM_CASCADES;
pub const MAX_POINT_LIGHTS = lighting_mod.MAX_POINT_LIGHTS;
pub const MAX_SPOT_LIGHTS = lighting_mod.MAX_SPOT_LIGHTS;

// Backward compatibility alias
pub const UniformBufferData = LightingUniforms;

// Skybox & IBL Subsystem
const skybox_mod = @import("skybox.zig");
pub const Skybox = skybox_mod.Skybox;

// Post-Processing Pipeline
const postprocess_mod = @import("postprocess.zig");
pub const PostProcessor = postprocess_mod.PostProcessor;
pub const PostProcessUniforms = postprocess_mod.PostProcessUniforms;

// GPU Particle Emitter Subsystem
const particles_mod = @import("particles.zig");
pub const Particle = particles_mod.Particle;
pub const ParticleSystem = particles_mod.ParticleSystem;

pub const Renderer = struct {
    instance: *wgpu.Instance,
    surface: *wgpu.Surface,
    adapter: *wgpu.Adapter,
    device: *wgpu.Device,
    queue: *wgpu.Queue,

    surface_format: wgpu.TextureFormat,
    surface_config: wgpu.SurfaceConfiguration,

    // Main HDR 3D Scene Pipeline
    render_pipeline: *wgpu.RenderPipeline,
    pipeline_layout: *wgpu.PipelineLayout,
    bind_group_layout: *wgpu.BindGroupLayout,
    bind_group: *wgpu.BindGroup,

    vertex_buffer: *wgpu.Buffer,
    index_buffer: *wgpu.Buffer,
    uniform_buffer: *wgpu.Buffer,

    depth_texture: *wgpu.Texture,
    depth_texture_view: *wgpu.TextureView,

    diffuse_texture: *wgpu.Texture,
    diffuse_texture_view: *wgpu.TextureView,
    diffuse_sampler: *wgpu.Sampler,

    // Phase 4: Dynamic Lighting & Cascaded Shadow Maps (CSM)
    shadow_map: ShadowMap,
    shadow_pipeline: *wgpu.RenderPipeline,
    shadow_pipeline_layout: *wgpu.PipelineLayout,
    shadow_bgl: *wgpu.BindGroupLayout,
    shadow_uniform_bufs: [NUM_CASCADES]*wgpu.Buffer,
    shadow_bg: [NUM_CASCADES]*wgpu.BindGroup,

    lighting_data: LightingUniforms,

    // Phase 4: Skybox & IBL
    skybox: Skybox,

    // Phase 4: Post-Processing Pipeline (HDR, ACES Tone-Mapping, Bloom)
    post_processor: PostProcessor,

    // Phase 4: GPU Particle Emitter Subsystem
    particles: ParticleSystem,

    ui: UiRenderer,

    pub fn create(allocator: std.mem.Allocator, window: *const Window) !*Renderer {
        const self = try allocator.create(Renderer);
        errdefer allocator.destroy(self);
        try self.initInto(window);
        return self;
    }

    pub fn destroy(self: *Renderer, allocator: std.mem.Allocator) void {
        self.deinit();
        allocator.destroy(self);
    }

    pub fn init(window: *const Window) !Renderer {
        var self: Renderer = undefined;
        try self.initInto(window);
        return self;
    }

    pub fn initInto(self: *Renderer, window: *const Window) !void {
        const instance = wgpu.Instance.create(null) orelse {
            std.log.err("Failed to create WGPU instance", .{});
            return error.WgpuInstanceFailed;
        };

        const surface = try window.createWgpuSurface(instance);


        const adapter_resp = instance.requestAdapterSync(&.{
            .compatible_surface = surface,
            .power_preference = .high_performance,
            .feature_level = .core,
        }, 50_000_000);

        if (adapter_resp.status != .success or adapter_resp.adapter == null) {
            std.log.err("Failed to request WGPU adapter: {s}", .{adapter_resp.message orelse "unknown"});
            return error.WgpuAdapterFailed;
        }
        const adapter = adapter_resp.adapter.?;

        const device_resp = adapter.requestDeviceSync(instance, &.{
            .label = wgpu.StringView.fromSlice("Game Engine Device"),
            .required_limits = null,
        }, 50_000_000);

        if (device_resp.status != .success or device_resp.device == null) {
            std.log.err("Failed to request WGPU device: {s}", .{device_resp.message orelse "unknown"});
            return error.WgpuDeviceFailed;
        }
        const device = device_resp.device.?;
        const queue = device.getQueue() orelse return error.WgpuQueueFailed;

        // Query surface capabilities
        var surface_caps: wgpu.SurfaceCapabilities = undefined;
        if (surface.getCapabilities(adapter, &surface_caps) != .success) {
            return error.SurfaceCapabilitiesFailed;
        }
        defer surface_caps.freeMembers();

        var preferred_format: wgpu.TextureFormat = .bgra8_unorm;
        if (surface_caps.format_count > 0) {
            preferred_format = surface_caps.formats[0];
            for (0..surface_caps.format_count) |i| {
                const fmt = surface_caps.formats[i];
                if (fmt == .bgra8_unorm or fmt == .rgba8_unorm or fmt == .bgra8_unorm_srgb) {
                    preferred_format = fmt;
                    break;
                }
            }
        }

        const surface_config = wgpu.SurfaceConfiguration{
            .device = device,
            .format = preferred_format,
            .usage = wgpu.TextureUsages.render_attachment,
            .width = window.width,
            .height = window.height,
            .alpha_mode = .auto,
            .present_mode = .fifo, // VSync
        };
        surface.configure(&surface_config);

        // 1. Create Depth Texture for 3D rendering
        const depth_fmt = wgpu.TextureFormat.depth24_plus;
        const depth_tex = device.createTexture(&.{
            .label = wgpu.StringView.fromSlice("Depth Texture"),
            .size = .{ .width = window.width, .height = window.height, .depth_or_array_layers = 1 },
            .mip_level_count = 1,
            .sample_count = 1,
            .dimension = .@"2d",
            .format = depth_fmt,
            .usage = wgpu.TextureUsages.render_attachment,
        }) orelse return error.DepthTextureFailed;
        const depth_view = depth_tex.createView(null) orelse return error.DepthViewFailed;

        // 2. Initialize CSM Shadow Map GPU resource (TASK-401)
        const shadow_map = try ShadowMap.init(device);

        // Compile Shadow Depth Shader Module
        const shadow_shader_source = @embedFile("../shaders/shadow.wgsl");
        const shadow_shader_desc = wgpu.shaderModuleWGSLDescriptor(.{
            .label = "Shadow Shader Module",
            .code = shadow_shader_source,
        });
        const shadow_shader_module = device.createShaderModule(&shadow_shader_desc) orelse return error.ShaderCompilationFailed;
        defer shadow_shader_module.release();

        // Shadow pipeline uniform buffers and bind groups (1 per cascade)
        var shadow_uniform_bufs: [NUM_CASCADES]*wgpu.Buffer = undefined;
        var shadow_bg: [NUM_CASCADES]*wgpu.BindGroup = undefined;

        const shadow_bgl_entry = wgpu.BindGroupLayoutEntry{
            .binding = 0,
            .visibility = wgpu.ShaderStages.vertex,
            .buffer = .{
                .@"type" = .uniform,
                .has_dynamic_offset = @intFromBool(false),
                .min_binding_size = @sizeOf(Mat4),
            },
        };
        const shadow_bgl = device.createBindGroupLayout(&.{
            .label = wgpu.StringView.fromSlice("Shadow BGL"),
            .entry_count = 1,
            .entries = @ptrCast(&shadow_bgl_entry),
        }) orelse return error.BindGroupLayoutFailed;

        for (0..NUM_CASCADES) |i| {
            shadow_uniform_bufs[i] = device.createBuffer(&.{
                .label = wgpu.StringView.fromSlice("Shadow Cascade Uniform Buffer"),
                .usage = wgpu.BufferUsages.uniform | wgpu.BufferUsages.copy_dst,
                .size = @sizeOf(Mat4),
                .mapped_at_creation = @intFromBool(false),
            }) orelse return error.UniformBufferFailed;

            const bg_entry = wgpu.BindGroupEntry{
                .binding = 0,
                .buffer = shadow_uniform_bufs[i],
                .offset = 0,
                .size = @sizeOf(Mat4),
            };
            shadow_bg[i] = device.createBindGroup(&.{
                .label = wgpu.StringView.fromSlice("Shadow Cascade BG"),
                .layout = shadow_bgl,
                .entry_count = 1,
                .entries = @ptrCast(&bg_entry),
            }) orelse return error.BindGroupFailed;
        }

        const shadow_pl_desc = wgpu.PipelineLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("Shadow Pipeline Layout"),
            .bind_group_layout_count = 1,
            .bind_group_layouts = @ptrCast(&shadow_bgl),
        };
        const shadow_pipeline_layout = device.createPipelineLayout(&shadow_pl_desc) orelse return error.PipelineLayoutFailed;

        const shadow_vertex_attrib = wgpu.VertexAttribute{
            .shader_location = 0,
            .offset = @offsetOf(Vertex, "position"),
            .format = .float32x3,
        };
        const shadow_vertex_layout = wgpu.VertexBufferLayout{
            .array_stride = @sizeOf(Vertex),
            .step_mode = .vertex,
            .attribute_count = 1,
            .attributes = @ptrCast(&shadow_vertex_attrib),
        };
        const shadow_depth_state = wgpu.DepthStencilState{
            .format = depth_fmt,
            .depth_write_enabled = .true,
            .depth_compare = .less,
            .stencil_front = .{},
            .stencil_back = .{},
        };

        const shadow_pipeline = device.createRenderPipeline(&.{
            .label = wgpu.StringView.fromSlice("Shadow Render Pipeline"),
            .layout = shadow_pipeline_layout,
            .vertex = .{
                .module = shadow_shader_module,
                .entry_point = wgpu.StringView.fromSlice("vs_main"),
                .buffer_count = 1,
                .buffers = @ptrCast(&shadow_vertex_layout),
            },
            .primitive = .{
                .topology = .triangle_list,
                .cull_mode = .back,
                .front_face = .ccw,
            },
            .depth_stencil = &shadow_depth_state,
            .multisample = .{ .count = 1, .mask = 0xffffffff },
            .fragment = null, // Depth-only pass
        }) orelse return error.RenderPipelineFailed;

        // 3. Initialize Skybox & IBL Subsystem (TASK-402)
        // Main scene HDR target is rgba16_float
        const hdr_format: wgpu.TextureFormat = .rgba16_float;
        const skybox = try Skybox.init(device, queue, hdr_format, depth_fmt);

        // 4. Initialize Post-Processing Pipeline (TASK-403)
        const post_processor = try PostProcessor.init(device, queue, preferred_format, window.width, window.height);

        // 5. Initialize GPU Particle Emitter Subsystem (TASK-404)
        const particles = try ParticleSystem.init(device, queue, hdr_format, depth_fmt);

        // 6. Main Scene WGSL Shader Module
        const shader_source = @embedFile("../shaders/scene.wgsl");
        const shader_desc = wgpu.shaderModuleWGSLDescriptor(.{
            .label = "Scene Shader",
            .code = shader_source,
        });
        const shader_module = device.createShaderModule(&shader_desc) orelse return error.ShaderCompilationFailed;
        defer shader_module.release();

        // Create Main Scene Uniform Buffer (LightingUniforms)
        const uniform_buf = device.createBuffer(&.{
            .label = wgpu.StringView.fromSlice("Lighting Uniform Buffer"),
            .usage = wgpu.BufferUsages.uniform | wgpu.BufferUsages.copy_dst,
            .size = @sizeOf(LightingUniforms),
            .mapped_at_creation = @intFromBool(false),
        }) orelse return error.UniformBufferFailed;

        // Procedural Checkerboard Diffuse Texture
        const tex_width: u32 = 256;
        const tex_height: u32 = 256;
        const tex_pixels = try std.heap.page_allocator.alloc(u8, tex_width * tex_height * 4);
        defer std.heap.page_allocator.free(tex_pixels);
        for (0..tex_height) |y| {
            for (0..tex_width) |x| {
                const idx = (y * tex_width + x) * 4;
                const check = ((x / 32) + (y / 32)) % 2 == 0;
                const border = (x % 32 == 0 or y % 32 == 0);
                if (border) {
                    tex_pixels[idx + 0] = 70;
                    tex_pixels[idx + 1] = 70;
                    tex_pixels[idx + 2] = 80;
                    tex_pixels[idx + 3] = 255;
                } else if (check) {
                    tex_pixels[idx + 0] = 245;
                    tex_pixels[idx + 1] = 245;
                    tex_pixels[idx + 2] = 250;
                    tex_pixels[idx + 3] = 255;
                } else {
                    tex_pixels[idx + 0] = 180;
                    tex_pixels[idx + 1] = 190;
                    tex_pixels[idx + 2] = 205;
                    tex_pixels[idx + 3] = 255;
                }
            }
        }

        const diffuse_texture = device.createTexture(&.{
            .label = wgpu.StringView.fromSlice("Diffuse Checker Texture"),
            .usage = wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_dst,
            .dimension = .@"2d",
            .size = .{ .width = tex_width, .height = tex_height, .depth_or_array_layers = 1 },
            .format = .rgba8_unorm,
            .mip_level_count = 1,
            .sample_count = 1,
        }) orelse return error.TextureCreationFailed;

        const copy_dst_info = wgpu.TexelCopyTextureInfo{
            .texture = diffuse_texture,
            .mip_level = 0,
            .origin = .{},
            .aspect = .all,
        };
        const copy_buf_layout = wgpu.TexelCopyBufferLayout{
            .offset = 0,
            .bytes_per_row = tex_width * 4,
            .rows_per_image = tex_height,
        };
        const copy_size = wgpu.Extent3D{
            .width = tex_width,
            .height = tex_height,
            .depth_or_array_layers = 1,
        };
        queue.writeTexture(&copy_dst_info, tex_pixels.ptr, tex_pixels.len, &copy_buf_layout, &copy_size);

        const diffuse_texture_view = diffuse_texture.createView(&.{
            .label = wgpu.StringView.fromSlice("Diffuse Texture View"),
            .format = .rgba8_unorm,
            .dimension = .@"2d",
            .base_mip_level = 0,
            .mip_level_count = 1,
            .base_array_layer = 0,
            .array_layer_count = 1,
            .aspect = .all,
        }) orelse return error.TextureViewFailed;

        const diffuse_sampler = device.createSampler(&.{
            .label = wgpu.StringView.fromSlice("Diffuse Sampler"),
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
        }) orelse return error.SamplerCreationFailed;

        // 7. Full Scene Bind Group Layout (7 entries: uniforms, diffuse, sampler, shadow array, shadow sampler, env cube, env sampler)
        const bgl_entries = [_]wgpu.BindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = wgpu.ShaderStages.vertex | wgpu.ShaderStages.fragment,
                .buffer = .{
                    .@"type" = .uniform,
                    .has_dynamic_offset = @intFromBool(false),
                    .min_binding_size = @sizeOf(LightingUniforms),
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
                .sampler = .{ .@"type" = .filtering },
            },
            .{
                .binding = 3,
                .visibility = wgpu.ShaderStages.fragment,
                .texture = .{
                    .sample_type = .depth,
                    .view_dimension = .@"2d_array",
                    .multisampled = @intFromBool(false),
                },
            },
            .{
                .binding = 4,
                .visibility = wgpu.ShaderStages.fragment,
                .sampler = .{ .@"type" = .comparison },
            },
            .{
                .binding = 5,
                .visibility = wgpu.ShaderStages.fragment,
                .texture = .{
                    .sample_type = .float,
                    .view_dimension = .cube,
                    .multisampled = @intFromBool(false),
                },
            },
            .{
                .binding = 6,
                .visibility = wgpu.ShaderStages.fragment,
                .sampler = .{ .@"type" = .filtering },
            },
        };

        const bgl = device.createBindGroupLayout(&.{
            .label = wgpu.StringView.fromSlice("Scene Bind Group Layout"),
            .entry_count = bgl_entries.len,
            .entries = &bgl_entries,
        }) orelse return error.BindGroupLayoutFailed;

        const bg_entries = [_]wgpu.BindGroupEntry{
            .{ .binding = 0, .buffer = uniform_buf, .offset = 0, .size = @sizeOf(LightingUniforms) },
            .{ .binding = 1, .texture_view = diffuse_texture_view },
            .{ .binding = 2, .sampler = diffuse_sampler },
            .{ .binding = 3, .texture_view = shadow_map.array_view },
            .{ .binding = 4, .sampler = shadow_map.sampler },
            .{ .binding = 5, .texture_view = skybox.cube_view },
            .{ .binding = 6, .sampler = skybox.sampler },
        };
        const bind_group = device.createBindGroup(&.{
            .label = wgpu.StringView.fromSlice("Scene Bind Group"),
            .layout = bgl,
            .entry_count = bg_entries.len,
            .entries = &bg_entries,
        }) orelse return error.BindGroupFailed;

        const pl_desc = wgpu.PipelineLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("Scene Pipeline Layout"),
            .bind_group_layout_count = 1,
            .bind_group_layouts = @ptrCast(&bgl),
        };
        const pipeline_layout = device.createPipelineLayout(&pl_desc) orelse return error.PipelineLayoutFailed;

        const vertex_attribs = [_]wgpu.VertexAttribute{
            .{ .shader_location = 0, .offset = @offsetOf(Vertex, "position"), .format = .float32x3 },
            .{ .shader_location = 1, .offset = @offsetOf(Vertex, "normal"), .format = .float32x3 },
            .{ .shader_location = 2, .offset = @offsetOf(Vertex, "color"), .format = .float32x3 },
            .{ .shader_location = 3, .offset = @offsetOf(Vertex, "uv"), .format = .float32x2 },
            .{ .shader_location = 4, .offset = @offsetOf(Vertex, "material_params"), .format = .float32x4 },
        };
        const vertex_buffer_layout = wgpu.VertexBufferLayout{
            .array_stride = @sizeOf(Vertex),
            .step_mode = .vertex,
            .attribute_count = vertex_attribs.len,
            .attributes = &vertex_attribs,
        };

        // Render pipeline outputs to offscreen HDR texture (.rgba16_float)
        const color_target = wgpu.ColorTargetState{
            .format = hdr_format,
            .blend = &wgpu.BlendState.alpha_blending,
            .write_mask = wgpu.ColorWriteMasks.all,
        };

        const fragment_state = wgpu.FragmentState{
            .module = shader_module,
            .entry_point = wgpu.StringView.fromSlice("fs_main"),
            .target_count = 1,
            .targets = @ptrCast(&color_target),
        };

        const depth_stencil_state = wgpu.DepthStencilState{
            .format = depth_fmt,
            .depth_write_enabled = .true,
            .depth_compare = .less,
            .stencil_front = .{},
            .stencil_back = .{},
        };

        const render_pipeline = device.createRenderPipeline(&.{
            .label = wgpu.StringView.fromSlice("Scene Render Pipeline"),
            .layout = pipeline_layout,
            .vertex = .{
                .module = shader_module,
                .entry_point = wgpu.StringView.fromSlice("vs_main"),
                .buffer_count = 1,
                .buffers = @ptrCast(&vertex_buffer_layout),
            },
            .primitive = .{
                .topology = .triangle_list,
                .cull_mode = .back,
                .front_face = .ccw,
            },
            .depth_stencil = &depth_stencil_state,
            .multisample = .{ .count = 1, .mask = 0xffffffff },
            .fragment = &fragment_state,
        }) orelse return error.RenderPipelineFailed;

        // Mesh Buffers
        const default_scene = Scene.initDefault();
        const max_vbuf_size = Scene.MAX_VERTICES * @sizeOf(Vertex);
        const vertex_buf = device.createBuffer(&.{
            .label = wgpu.StringView.fromSlice("Mesh Vertex Buffer"),
            .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
            .size = max_vbuf_size,
            .mapped_at_creation = @intFromBool(false),
        }) orelse return error.VertexBufferFailed;
        queue.writeBuffer(vertex_buf, 0, default_scene.vertices.ptr, default_scene.vertices.len * @sizeOf(Vertex));

        const max_ibuf_size = Scene.MAX_INDICES * @sizeOf(u16);
        const index_buf = device.createBuffer(&.{
            .label = wgpu.StringView.fromSlice("Mesh Index Buffer"),
            .usage = wgpu.BufferUsages.index | wgpu.BufferUsages.copy_dst,
            .size = max_ibuf_size,
            .mapped_at_creation = @intFromBool(false),
        }) orelse return error.IndexBufferFailed;
        queue.writeBuffer(index_buf, 0, default_scene.indices.ptr, default_scene.indices.len * @sizeOf(u16));

        var ui = try UiRenderer.init(device, queue, preferred_format, null);
        ui.setScreenSize(@floatFromInt(window.width), @floatFromInt(window.height));


        // Default lighting state
        var lighting_data: LightingUniforms = undefined;
        @memset(std.mem.asBytes(&lighting_data), 0);
        lighting_data.dir_light = DirectionalLight{
            .direction = .{ -0.55, -0.82, -0.35 },
            .intensity = 2.5,
            .color = .{ 1.0, 0.96, 0.88 },
        };
        lighting_data.cascade_splits = DEFAULT_CASCADE_SPLITS;
        lighting_data.ambient_color = .{ 1.0, 1.0, 1.0 };
        lighting_data.ambient_intensity = 0.40;
        lighting_data.light_counts = .{ 0, 0, 1, @intCast(NUM_CASCADES) }; // Shadows enabled

        // Add 2 initial point lights to showcase dynamic multi-lighting immediately
        lighting_data.point_lights[0] = PointLight{
            .position = .{ 0.0, 2.5, 0.0 },
            .radius = 12.0,
            .color = .{ 0.2, 0.8, 1.0 }, // Cyan magic light
            .intensity = 3.5,
        };
        lighting_data.point_lights[1] = PointLight{
            .position = .{ 3.0, 1.5, 2.0 },
            .radius = 8.0,
            .color = .{ 1.0, 0.4, 0.1 }, // Warm torch glow
            .intensity = 2.8,
        };
        lighting_data.light_counts[0] = 2; // 2 active point lights

        self.instance = instance;
        self.surface = surface;
        self.adapter = adapter;
        self.device = device;
        self.queue = queue;
        self.surface_format = preferred_format;
        self.surface_config = surface_config;
        self.render_pipeline = render_pipeline;
        self.pipeline_layout = pipeline_layout;
        self.bind_group_layout = bgl;
        self.bind_group = bind_group;
        self.vertex_buffer = vertex_buf;
        self.index_buffer = index_buf;
        self.uniform_buffer = uniform_buf;
        self.depth_texture = depth_tex;
        self.depth_texture_view = depth_view;
        self.diffuse_texture = diffuse_texture;
        self.diffuse_texture_view = diffuse_texture_view;
        self.diffuse_sampler = diffuse_sampler;
        self.shadow_map = shadow_map;
        self.shadow_pipeline = shadow_pipeline;
        self.shadow_pipeline_layout = shadow_pipeline_layout;
        self.shadow_bgl = shadow_bgl;
        self.shadow_uniform_bufs = shadow_uniform_bufs;
        self.shadow_bg = shadow_bg;
        self.lighting_data = lighting_data;
        self.skybox = skybox;
        self.post_processor = post_processor;
        self.particles = particles;
        self.ui = ui;
    }


    /// Dynamically adds a point light into the scene lighting buffer
    pub fn addPointLight(self: *Renderer, pos: [3]f32, radius: f32, color: [3]f32, intensity: f32) void {
        const count = self.lighting_data.light_counts[0];
        if (count < MAX_POINT_LIGHTS) {
            self.lighting_data.point_lights[count] = PointLight{
                .position = pos,
                .radius = radius,
                .color = color,
                .intensity = intensity,
            };
            self.lighting_data.light_counts[0] += 1;
        }
    }

    /// Dynamically adds a spot light into the scene lighting buffer
    pub fn addSpotLight(self: *Renderer, pos: [3]f32, dir: [3]f32, inner_cone_cos: f32, outer_cone_cos: f32, color: [3]f32, intensity: f32) void {
        const count = self.lighting_data.light_counts[1];
        if (count < MAX_SPOT_LIGHTS) {
            self.lighting_data.spot_lights[count] = SpotLight{
                .position = pos,
                .inner_cone_cos = inner_cone_cos,
                .direction = dir,
                .outer_cone_cos = outer_cone_cos,
                .color = color,
                .intensity = intensity,
            };
            self.lighting_data.light_counts[1] += 1;
        }
    }

    /// Clears dynamic point and spot lights
    pub fn clearLights(self: *Renderer) void {
        self.lighting_data.light_counts[0] = 0;
        self.lighting_data.light_counts[1] = 0;
    }

    /// Updates directional light orientation, intensity, and color
    pub fn setDirectionalLight(self: *Renderer, dir: [3]f32, intensity: f32, color: [3]f32) void {
        self.lighting_data.dir_light.direction = dir;
        self.lighting_data.dir_light.intensity = intensity;
        self.lighting_data.dir_light.color = color;
    }

    /// Triggers a particle burst in the particle system
    pub fn spawnParticleBurst(self: *Renderer, pos: Vec3, count: u32, speed: f32, color: [4]f32, size: f32, lifetime: f32) void {
        self.particles.spawnBurst(pos, count, speed, color, size, lifetime);
    }

    /// Advances particle simulation physics
    pub fn updateParticles(self: *Renderer, dt: f32) void {
        self.particles.update(dt);
    }

    /// Uploads an RGBA8 image as a new GPU Texture and TextureView
    pub fn createTextureRgba(self: *Renderer, width: u32, height: u32, pixels: []const u8) !struct { texture: *wgpu.Texture, view: *wgpu.TextureView } {
        const tex = self.device.createTexture(&.{
            .label = wgpu.StringView.fromSlice("Uploaded Texture"),
            .usage = wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_dst,
            .dimension = .@"2d",
            .size = .{ .width = width, .height = height, .depth_or_array_layers = 1 },
            .format = .rgba8_unorm,
            .mip_level_count = 1,
            .sample_count = 1,
        }) orelse return error.TextureCreationFailed;

        const copy_dst_info = wgpu.TexelCopyTextureInfo{
            .texture = tex,
            .mip_level = 0,
            .origin = .{},
            .aspect = .all,
        };
        const copy_buf_layout = wgpu.TexelCopyBufferLayout{
            .offset = 0,
            .bytes_per_row = width * 4,
            .rows_per_image = height,
        };
        const copy_size = wgpu.Extent3D{
            .width = width,
            .height = height,
            .depth_or_array_layers = 1,
        };
        self.queue.writeTexture(&copy_dst_info, pixels.ptr, pixels.len, &copy_buf_layout, &copy_size);

        const view = tex.createView(&.{
            .label = wgpu.StringView.fromSlice("Uploaded Texture View"),
            .format = .rgba8_unorm,
            .dimension = .@"2d",
            .base_mip_level = 0,
            .mip_level_count = 1,
            .base_array_layer = 0,
            .array_layer_count = 1,
            .aspect = .all,
        }) orelse return error.TextureViewFailed;

        return .{ .texture = tex, .view = view };
    }

    /// Updates bind group to use a new diffuse texture view
    pub fn setDiffuseTextureView(self: *Renderer, new_view: *wgpu.TextureView) !void {
        self.bind_group.release();
        const bg_entries = [_]wgpu.BindGroupEntry{
            .{ .binding = 0, .buffer = self.uniform_buffer, .offset = 0, .size = @sizeOf(LightingUniforms) },
            .{ .binding = 1, .texture_view = new_view },
            .{ .binding = 2, .sampler = self.diffuse_sampler },
            .{ .binding = 3, .texture_view = self.shadow_map.array_view },
            .{ .binding = 4, .sampler = self.shadow_map.sampler },
            .{ .binding = 5, .texture_view = self.skybox.cube_view },
            .{ .binding = 6, .sampler = self.skybox.sampler },
        };
        self.bind_group = self.device.createBindGroup(&.{
            .label = wgpu.StringView.fromSlice("Scene Bind Group Dynamic"),
            .layout = self.bind_group_layout,
            .entry_count = bg_entries.len,
            .entries = &bg_entries,
        }) orelse return error.BindGroupFailed;
    }

    pub fn resize(self: *Renderer, width: u32, height: u32) void {
        if (width == 0 or height == 0) return;
        self.surface_config.width = width;
        self.surface_config.height = height;
        self.surface.configure(&self.surface_config);
        self.ui.setScreenSize(@floatFromInt(width), @floatFromInt(height));

        self.depth_texture_view.release();
        self.depth_texture.destroy();
        self.depth_texture.release();

        const depth_fmt = wgpu.TextureFormat.depth24_plus;
        self.depth_texture = self.device.createTexture(&.{
            .label = wgpu.StringView.fromSlice("Depth Texture"),
            .size = .{ .width = width, .height = height, .depth_or_array_layers = 1 },
            .mip_level_count = 1,
            .sample_count = 1,
            .dimension = .@"2d",
            .format = depth_fmt,
            .usage = wgpu.TextureUsages.render_attachment,
        }).?;
        self.depth_texture_view = self.depth_texture.createView(null).?;

        self.post_processor.resize(width, height) catch |err| {
            std.log.err("PostProcessor resize failed: {}", .{err});
        };
    }

    pub fn render(self: *Renderer, scene: *Scene, time_seconds: f32) !void {
        return self.renderWithCamera(scene, null, time_seconds);
    }

    pub fn renderWithCamera(self: *Renderer, scene: *Scene, camera: ?*const Camera, time_seconds: f32) !void {
        var surface_tex: wgpu.SurfaceTexture = undefined;
        self.surface.getCurrentTexture(&surface_tex);

        switch (surface_tex.status) {
            .success_optimal, .success_suboptimal => {},
            .outdated, .lost => {
                self.surface.configure(&self.surface_config);
                return;
            },
            else => {
                std.log.err("Surface getCurrentTexture returned error: {s}", .{@tagName(surface_tex.status)});
                return error.SurfaceAcquireFailed;
            },
        }

        const target_texture = surface_tex.texture orelse return error.NoTargetTexture;
        defer target_texture.release();

        const target_view = target_texture.createView(null) orelse return error.ViewCreationFailed;
        defer target_view.release();

        // 1. Compute Camera Matrices & View Direction Vectors
        var view: Mat4 = undefined;
        var proj: Mat4 = undefined;
        var view_proj: Mat4 = undefined;
        var eye_pos: [3]f32 = undefined;
        var cam_right: Vec3 = undefined;
        var cam_up: Vec3 = undefined;
        var active_cam: Camera = undefined;

        const aspect = @as(f32, @floatFromInt(self.surface_config.width)) / @as(f32, @floatFromInt(self.surface_config.height));

        if (camera) |cam| {
            active_cam = cam.*;
            active_cam.aspect = aspect;
            view = active_cam.getViewMatrix();
            proj = active_cam.getProjMatrix();
            view_proj = proj.mul(view);
            eye_pos = .{ active_cam.position.x, active_cam.position.y, active_cam.position.z };

            const fwd = active_cam.getForward().normalize();
            cam_right = Vec3.init(0.0, 1.0, 0.0).cross(fwd).normalize();
            cam_up = fwd.cross(cam_right).normalize();
        } else {
            proj = Mat4.perspective(std.math.degreesToRadians(45.0), aspect, 0.1, 100.0);
            const pitch = std.math.clamp(scene.rotation_x, -1.45, 1.45);
            const yaw = scene.rotation_y;
            const dist = @max(1.0, scene.camera_distance);
            const cos_p = @cos(pitch);
            const sin_p = @sin(pitch);
            const cos_y = @cos(yaw);
            const sin_y = @sin(yaw);

            const eye = Vec3.init(dist * cos_p * sin_y, 0.8 + dist * sin_p, dist * cos_p * cos_y);
            const tgt = Vec3.init(0, 0, 0);
            const up = Vec3.init(0, 1, 0);
            view = Mat4.lookAt(eye, tgt, up);
            view_proj = proj.mul(view);
            eye_pos = .{ eye.x, eye.y, eye.z };

            active_cam = Camera{
                .position = eye,
                .fov_deg = 45.0,
                .aspect = aspect,
                .near = 0.1,
                .far = 100.0,
            };
            const fwd = tgt.sub(eye).normalize();
            cam_right = up.cross(fwd).normalize();
            cam_up = fwd.cross(cam_right).normalize();
        }

        // 2. Compute 3-Split Cascaded Shadow Map Projections
        const dir_light_vec = Vec3.init(
            self.lighting_data.dir_light.direction[0],
            self.lighting_data.dir_light.direction[1],
            self.lighting_data.dir_light.direction[2],
        );
        const cascade_matrices = computeCascadeMatrices(active_cam, dir_light_vec, aspect, DEFAULT_CASCADE_SPLITS);

        // 3. Update Scene Geometry Buffers
        if (scene.vertices_dirty) {
            self.queue.writeBuffer(self.vertex_buffer, 0, scene.vertices.ptr, scene.vertices.len * @sizeOf(Vertex));
            self.queue.writeBuffer(self.index_buffer, 0, scene.indices.ptr, scene.indices.len * @sizeOf(u16));
            scene.vertices_dirty = false;
        }

        // 4. Update Lighting Uniform Buffer
        self.lighting_data.model = Mat4.identity.m;
        self.lighting_data.view_proj = view_proj.m;
        self.lighting_data.camera_pos = eye_pos;
        self.lighting_data.time = time_seconds;
        self.lighting_data.cascade_splits = DEFAULT_CASCADE_SPLITS;
        for (0..NUM_CASCADES) |c_idx| {
            self.lighting_data.cascade_view_proj[c_idx] = cascade_matrices[c_idx].m;
        }
        self.queue.writeBuffer(self.uniform_buffer, 0, &self.lighting_data, @sizeOf(LightingUniforms));

        // Create Command Encoder
        const encoder = self.device.createCommandEncoder(&.{
            .label = wgpu.StringView.fromSlice("Main Command Encoder"),
        }) orelse return error.CommandEncoderFailed;
        defer encoder.release();

        // 5. Pass 1: Cascaded Shadow Passes (Depth-only, 3 cascades)
        if (self.lighting_data.light_counts[2] != 0 and scene.indices.len > 0) {
            for (0..NUM_CASCADES) |c_idx| {
                self.queue.writeBuffer(self.shadow_uniform_bufs[c_idx], 0, &cascade_matrices[c_idx].m, @sizeOf(Mat4));

                const depth_att = wgpu.DepthStencilAttachment{
                    .view = self.shadow_map.layer_views[c_idx],
                    .depth_load_op = .clear,
                    .depth_store_op = .store,
                    .depth_clear_value = 1.0,
                    .depth_read_only = @intFromBool(false),
                    .stencil_load_op = .@"undefined",
                    .stencil_store_op = .@"undefined",
                    .stencil_clear_value = 0,
                    .stencil_read_only = @intFromBool(false),
                };

                const shadow_pass = encoder.beginRenderPass(&.{
                    .label = wgpu.StringView.fromSlice("CSM Shadow Render Pass"),
                    .color_attachment_count = 0,
                    .color_attachments = &[0]wgpu.ColorAttachment{},
                    .depth_stencil_attachment = &depth_att,
                }) orelse return error.RenderPassFailed;

                shadow_pass.setPipeline(self.shadow_pipeline);
                shadow_pass.setBindGroup(0, self.shadow_bg[c_idx], 0, null);
                shadow_pass.setVertexBuffer(0, self.vertex_buffer, 0, scene.vertices.len * @sizeOf(Vertex));
                shadow_pass.setIndexBuffer(self.index_buffer, .uint16, 0, scene.indices.len * @sizeOf(u16));
                shadow_pass.drawIndexed(@intCast(scene.indices.len), 1, 0, 0, 0);

                shadow_pass.end();
                shadow_pass.release();
            }
        }

        // 6. Pass 2: Main 3D HDR Scene Pass (PBR + Multi-Lighting + CSM + IBL + Skybox + Particles)
        {
            const color_attachment = wgpu.ColorAttachment{
                .view = self.post_processor.hdr_view,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 0.08, .g = 0.09, .b = 0.12, .a = 1.0 },
            };

            const depth_attachment = wgpu.DepthStencilAttachment{
                .view = self.depth_texture_view,
                .depth_load_op = .clear,
                .depth_store_op = .store,
                .depth_clear_value = 1.0,
                .depth_read_only = @intFromBool(false),
                .stencil_load_op = .@"undefined",
                .stencil_store_op = .@"undefined",
                .stencil_clear_value = 0,
                .stencil_read_only = @intFromBool(false),
            };

            const render_pass = encoder.beginRenderPass(&.{
                .label = wgpu.StringView.fromSlice("Main HDR 3D Scene Pass"),
                .color_attachment_count = 1,
                .color_attachments = @ptrCast(&color_attachment),
                .depth_stencil_attachment = &depth_attachment,
            }) orelse return error.RenderPassFailed;

            // 6a. Draw 3D Geometries
            if (scene.indices.len > 0) {
                render_pass.setPipeline(self.render_pipeline);
                render_pass.setBindGroup(0, self.bind_group, 0, null);
                render_pass.setVertexBuffer(0, self.vertex_buffer, 0, scene.vertices.len * @sizeOf(Vertex));
                render_pass.setIndexBuffer(self.index_buffer, .uint16, 0, scene.indices.len * @sizeOf(u16));
                render_pass.drawIndexed(@intCast(scene.indices.len), 1, 0, 0, 0);
            }

            // 6b. Draw Skybox at far plane
            self.skybox.render(render_pass, view, proj);

            // 6c. Draw 3D Particle System
            self.particles.render(render_pass, view_proj, cam_right, cam_up);

            render_pass.end();
            render_pass.release();
        }

        // 7. Pass 3: Post-Processing Pipeline (HDR Bloom + ACES Tonemapping + Gamma -> target_view)
        self.post_processor.process(encoder, target_view);

        // 8. Pass 4: 2D UI Overlay Pass on top of Swapchain
        {
            const ui_color_att = wgpu.ColorAttachment{
                .view = target_view,
                .load_op = .load,
                .store_op = .store,
            };
            const ui_pass = encoder.beginRenderPass(&.{
                .label = wgpu.StringView.fromSlice("2D UI Overlay Pass"),
                .color_attachment_count = 1,
                .color_attachments = @ptrCast(&ui_color_att),
                .depth_stencil_attachment = null,
            }) orelse return error.RenderPassFailed;

            self.ui.render(ui_pass);
            ui_pass.end();
            ui_pass.release();
        }

        // 9. Submit to GPU Queue
        const command_buffer = encoder.finish(null) orelse return error.FinishEncoderFailed;
        defer command_buffer.release();

        const cmd_buffers = [_]*const wgpu.CommandBuffer{command_buffer};
        self.queue.submit(&cmd_buffers);

        // Present Frame to display
        _ = self.surface.present();
    }

    pub fn deinit(self: *Renderer) void {
        self.ui.deinit();
        self.particles.deinit();
        self.post_processor.deinit();
        self.skybox.deinit();

        for (self.shadow_bg) |bg| {
            bg.release();
        }
        for (self.shadow_uniform_bufs) |buf| {
            buf.destroy();
            buf.release();
        }
        self.shadow_pipeline.release();
        self.shadow_pipeline_layout.release();
        self.shadow_bgl.release();
        self.shadow_map.deinit();

        self.diffuse_sampler.release();
        self.diffuse_texture_view.release();
        self.diffuse_texture.destroy();
        self.diffuse_texture.release();

        self.depth_texture_view.release();
        self.depth_texture.destroy();
        self.depth_texture.release();

        self.vertex_buffer.destroy();
        self.vertex_buffer.release();

        self.index_buffer.destroy();
        self.index_buffer.release();

        self.uniform_buffer.destroy();
        self.uniform_buffer.release();

        self.bind_group.release();
        self.bind_group_layout.release();
        self.pipeline_layout.release();
        self.render_pipeline.release();

        self.surface.unconfigure();
        self.surface.release();
        self.queue.release();
        self.device.destroy();
        self.device.release();
        self.adapter.release();
        self.instance.release();
    }
};

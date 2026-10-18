//! GPU Particle Emitter Subsystem
//! Implements TASK-404 for particle effects (bursts, sparks, explosions, smoke).
//! Complies with AGENTS.md: generic engine infrastructure in src/engine/renderer/.

const std = @import("std");
const wgpu = @import("wgpu");
const math = @import("../math.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

pub const Particle = extern struct {
    position: [3]f32,
    lifetime: f32,
    velocity: [3]f32,
    max_lifetime: f32,
    color: [4]f32,
    size: f32,
    growth: f32,
    pad: [2]f32 = .{ 0.0, 0.0 },
};

pub const ParticleUniforms = extern struct {
    view_proj: [4][4]f32,
    cam_right: [3]f32,
    pad0: f32 = 0.0,
    cam_up: [3]f32,
    pad1: f32 = 0.0,
};

pub const QuadVertex = extern struct {
    quad_pos: [2]f32,
    uv: [2]f32,
};

const QUAD_VERTICES = [_]QuadVertex{
    .{ .quad_pos = .{ -0.5, -0.5 }, .uv = .{ 0.0, 0.0 } },
    .{ .quad_pos = .{  0.5, -0.5 }, .uv = .{ 1.0, 0.0 } },
    .{ .quad_pos = .{  0.5,  0.5 }, .uv = .{ 1.0, 1.0 } },
    .{ .quad_pos = .{ -0.5,  0.5 }, .uv = .{ 0.0, 1.0 } },
};

const QUAD_INDICES = [_]u16{ 0, 1, 2, 0, 2, 3 };

pub const ParticleSystem = struct {
    pub const MAX_PARTICLES: usize = 4096;

    device: *wgpu.Device,
    queue: *wgpu.Queue,

    render_pipeline: *wgpu.RenderPipeline,
    pipeline_layout: *wgpu.PipelineLayout,
    bind_group_layout: *wgpu.BindGroupLayout,
    bind_group: *wgpu.BindGroup,

    uniform_buffer: *wgpu.Buffer,
    quad_vertex_buffer: *wgpu.Buffer,
    quad_index_buffer: *wgpu.Buffer,
    instance_buffer: *wgpu.Buffer,

    particles: [MAX_PARTICLES]Particle = undefined,
    particle_count: usize = 0,
    rng_state: u64 = 0x853c49e6748fea9b,

    fn randomFloat(self: *ParticleSystem) f32 {
        // Simple Xorshift64Star
        var x = self.rng_state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.rng_state = x;
        const r = x *% 0x2545F4914F6CDD1D;
        const u = @as(u32, @truncate(r >> 32));
        return @as(f32, @floatFromInt(u)) / 4294967296.0;
    }

    pub fn init(device: *wgpu.Device, queue: *wgpu.Queue, target_format: wgpu.TextureFormat, depth_format: wgpu.TextureFormat) !ParticleSystem {
        const shader_source = @embedFile("../shaders/particle.wgsl");
        const shader_desc = wgpu.shaderModuleWGSLDescriptor(.{
            .label = "Particle Shader",
            .code = shader_source,
        });
        const shader_module = device.createShaderModule(&shader_desc) orelse return error.ShaderCompilationFailed;
        defer shader_module.release();

        // 1. Uniform Buffer
        const uniform_buf = device.createBuffer(&.{
            .label = wgpu.StringView.fromSlice("Particle Uniform Buffer"),
            .usage = wgpu.BufferUsages.uniform | wgpu.BufferUsages.copy_dst,
            .size = @sizeOf(ParticleUniforms),
            .mapped_at_creation = @intFromBool(false),
        }) orelse return error.UniformBufferFailed;

        // 2. Quad Mesh Buffers
        const quad_vbuf = device.createBuffer(&.{
            .label = wgpu.StringView.fromSlice("Particle Quad Vertex Buffer"),
            .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
            .size = @sizeOf([4]QuadVertex),
            .mapped_at_creation = @intFromBool(false),
        }) orelse return error.VertexBufferFailed;
        queue.writeBuffer(quad_vbuf, 0, &QUAD_VERTICES, @sizeOf([4]QuadVertex));

        const quad_ibuf = device.createBuffer(&.{
            .label = wgpu.StringView.fromSlice("Particle Quad Index Buffer"),
            .usage = wgpu.BufferUsages.index | wgpu.BufferUsages.copy_dst,
            .size = @sizeOf([6]u16),
            .mapped_at_creation = @intFromBool(false),
        }) orelse return error.IndexBufferFailed;
        queue.writeBuffer(quad_ibuf, 0, &QUAD_INDICES, @sizeOf([6]u16));

        // 3. Dynamic Instance Buffer
        const instance_buf = device.createBuffer(&.{
            .label = wgpu.StringView.fromSlice("Particle Instance Buffer"),
            .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
            .size = MAX_PARTICLES * @sizeOf(Particle),
            .mapped_at_creation = @intFromBool(false),
        }) orelse return error.InstanceBufferFailed;

        // 4. Bind Group Layout
        const bgl_entry = wgpu.BindGroupLayoutEntry{
            .binding = 0,
            .visibility = wgpu.ShaderStages.vertex,
            .buffer = .{
                .@"type" = .uniform,
                .has_dynamic_offset = @intFromBool(false),
                .min_binding_size = @sizeOf(ParticleUniforms),
            },
        };
        const bgl = device.createBindGroupLayout(&.{
            .label = wgpu.StringView.fromSlice("Particle Bind Group Layout"),
            .entry_count = 1,
            .entries = @ptrCast(&bgl_entry),
        }) orelse return error.BindGroupLayoutFailed;

        const bg_entry = wgpu.BindGroupEntry{
            .binding = 0,
            .buffer = uniform_buf,
            .offset = 0,
            .size = @sizeOf(ParticleUniforms),
        };
        const bg = device.createBindGroup(&.{
            .label = wgpu.StringView.fromSlice("Particle Bind Group"),
            .layout = bgl,
            .entry_count = 1,
            .entries = @ptrCast(&bg_entry),
        }) orelse return error.BindGroupFailed;

        const pl_desc = wgpu.PipelineLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("Particle Pipeline Layout"),
            .bind_group_layout_count = 1,
            .bind_group_layouts = @ptrCast(&bgl),
        };
        const pipeline_layout = device.createPipelineLayout(&pl_desc) orelse return error.PipelineLayoutFailed;

        // Vertex Buffer 0: Quad Geometry (vertex mode)
        const quad_attribs = [_]wgpu.VertexAttribute{
            .{ .shader_location = 0, .offset = @offsetOf(QuadVertex, "quad_pos"), .format = .float32x2 },
            .{ .shader_location = 1, .offset = @offsetOf(QuadVertex, "uv"), .format = .float32x2 },
        };
        const quad_buffer_layout = wgpu.VertexBufferLayout{
            .array_stride = @sizeOf(QuadVertex),
            .step_mode = .vertex,
            .attribute_count = quad_attribs.len,
            .attributes = &quad_attribs,
        };

        // Vertex Buffer 1: Particle Instances (instance mode)
        const instance_attribs = [_]wgpu.VertexAttribute{
            .{ .shader_location = 2, .offset = @offsetOf(Particle, "position"), .format = .float32x3 },
            .{ .shader_location = 3, .offset = @offsetOf(Particle, "lifetime"), .format = .float32 },
            .{ .shader_location = 4, .offset = @offsetOf(Particle, "velocity"), .format = .float32x3 },
            .{ .shader_location = 5, .offset = @offsetOf(Particle, "max_lifetime"), .format = .float32 },
            .{ .shader_location = 6, .offset = @offsetOf(Particle, "color"), .format = .float32x4 },
            .{ .shader_location = 7, .offset = @offsetOf(Particle, "size"), .format = .float32 },
            .{ .shader_location = 8, .offset = @offsetOf(Particle, "growth"), .format = .float32 },
        };
        const instance_buffer_layout = wgpu.VertexBufferLayout{
            .array_stride = @sizeOf(Particle),
            .step_mode = .instance,
            .attribute_count = instance_attribs.len,
            .attributes = &instance_attribs,
        };

        const vbuf_layouts = [_]wgpu.VertexBufferLayout{ quad_buffer_layout, instance_buffer_layout };

        // Additive alpha blending for glowing effects
        const blend_state = wgpu.BlendState{
            .color = .{
                .src_factor = .src_alpha,
                .dst_factor = .one,
                .operation = .add,
            },
            .alpha = .{
                .src_factor = .one,
                .dst_factor = .one_minus_src_alpha,
                .operation = .add,
            },
        };

        const color_target = wgpu.ColorTargetState{
            .format = target_format,
            .blend = &blend_state,
            .write_mask = wgpu.ColorWriteMasks.all,
        };

        const fragment_state = wgpu.FragmentState{
            .module = shader_module,
            .entry_point = wgpu.StringView.fromSlice("fs_main"),
            .target_count = 1,
            .targets = @ptrCast(&color_target),
        };

        const depth_stencil_state = wgpu.DepthStencilState{
            .format = depth_format,
            .depth_write_enabled = .false,
            .depth_compare = .less_equal,
            .stencil_front = .{},
            .stencil_back = .{},
        };

        const render_pipeline = device.createRenderPipeline(&.{
            .label = wgpu.StringView.fromSlice("Particle Render Pipeline"),
            .layout = pipeline_layout,
            .vertex = .{
                .module = shader_module,
                .entry_point = wgpu.StringView.fromSlice("vs_main"),
                .buffer_count = vbuf_layouts.len,
                .buffers = &vbuf_layouts,
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

        return ParticleSystem{
            .device = device,
            .queue = queue,
            .render_pipeline = render_pipeline,
            .pipeline_layout = pipeline_layout,
            .bind_group_layout = bgl,
            .bind_group = bg,
            .uniform_buffer = uniform_buf,
            .quad_vertex_buffer = quad_vbuf,
            .quad_index_buffer = quad_ibuf,
            .instance_buffer = instance_buf,
        };
    }

    /// Spawns an omni-directional burst of particles at given world position.
    pub fn spawnBurst(self: *ParticleSystem, pos: Vec3, count: u32, speed: f32, color: [4]f32, size: f32, lifetime: f32) void {
        var spawned: u32 = 0;
        while (spawned < count and self.particle_count < MAX_PARTICLES) : (spawned += 1) {
            // Generate random spherical unit direction
            const theta = self.randomFloat() * std.math.pi * 2.0;
            const phi = (self.randomFloat() - 0.5) * std.math.pi;
            const speed_var = speed * (0.6 + self.randomFloat() * 0.8);

            const cos_phi = @cos(phi);
            const vx = @cos(theta) * cos_phi * speed_var;
            const vy = @sin(phi) * speed_var + (speed * 0.3); // slight upward bias
            const vz = @sin(theta) * cos_phi * speed_var;

            const p_life = lifetime * (0.8 + self.randomFloat() * 0.4);

            self.particles[self.particle_count] = Particle{
                .position = .{ pos.x, pos.y, pos.z },
                .lifetime = p_life,
                .velocity = .{ vx, vy, vz },
                .max_lifetime = p_life,
                .color = color,
                .size = size * (0.7 + self.randomFloat() * 0.6),
                .growth = -size * 0.2,
            };
            self.particle_count += 1;
        }
    }

    /// Advances particle physics (gravity, drag, size growth, lifetime) and compacts alive particles.
    pub fn update(self: *ParticleSystem, dt: f32) void {
        var alive: usize = 0;
        var i: usize = 0;
        const count = self.particle_count;

        while (i < count) : (i += 1) {
            var p = &self.particles[i];
            p.lifetime -= dt;

            if (p.lifetime > 0.0) {
                // Gravity & velocity integration
                p.velocity[1] -= 9.81 * dt * 0.5;
                // Linear drag
                const drag = @max(0.0, 1.0 - 0.4 * dt);
                p.velocity[0] *= drag;
                p.velocity[1] *= drag;
                p.velocity[2] *= drag;

                p.position[0] += p.velocity[0] * dt;
                p.position[1] += p.velocity[1] * dt;
                p.position[2] += p.velocity[2] * dt;

                p.size = @max(0.01, p.size + p.growth * dt);

                if (alive != i) {
                    self.particles[alive] = p.*;
                }
                alive += 1;
            }
        }
        self.particle_count = alive;
    }

    /// Renders all active particles as camera-facing billboards.
    pub fn render(self: *ParticleSystem, render_pass: *wgpu.RenderPassEncoder, view_proj: Mat4, cam_right: Vec3, cam_up: Vec3) void {
        if (self.particle_count == 0) return;

        const uniforms = ParticleUniforms{
            .view_proj = view_proj.m,
            .cam_right = .{ cam_right.x, cam_right.y, cam_right.z },
            .cam_up = .{ cam_up.x, cam_up.y, cam_up.z },
        };
        self.queue.writeBuffer(self.uniform_buffer, 0, &uniforms, @sizeOf(ParticleUniforms));

        // Upload active instance data
        self.queue.writeBuffer(
            self.instance_buffer,
            0,
            &self.particles,
            self.particle_count * @sizeOf(Particle),
        );

        render_pass.setPipeline(self.render_pipeline);
        render_pass.setBindGroup(0, self.bind_group, 0, null);
        render_pass.setVertexBuffer(0, self.quad_vertex_buffer, 0, @sizeOf([4]QuadVertex));
        render_pass.setVertexBuffer(1, self.instance_buffer, 0, self.particle_count * @sizeOf(Particle));
        render_pass.setIndexBuffer(self.quad_index_buffer, .uint16, 0, @sizeOf([6]u16));
        render_pass.drawIndexed(6, @intCast(self.particle_count), 0, 0, 0);
    }

    pub fn deinit(self: *ParticleSystem) void {
        self.instance_buffer.destroy();
        self.instance_buffer.release();

        self.quad_index_buffer.destroy();
        self.quad_index_buffer.release();

        self.quad_vertex_buffer.destroy();
        self.quad_vertex_buffer.release();

        self.uniform_buffer.destroy();
        self.uniform_buffer.release();

        self.bind_group.release();
        self.bind_group_layout.release();
        self.pipeline_layout.release();
        self.render_pipeline.release();
    }
};

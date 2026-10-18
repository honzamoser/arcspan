const std = @import("std");
const math = @import("../math.zig");
const primitives = @import("primitives.zig");
const mat_mod = @import("material.zig");
const game_state = @import("../state/game_state.zig");
const Vec3 = math.Vec3;

pub const Vertex = primitives.Vertex;
pub const PrimitiveType = primitives.PrimitiveType;
pub const Material = mat_mod.Material;
pub const ShadingModel = mat_mod.ShadingModel;
pub const AlphaMode = mat_mod.AlphaMode;

pub const RenderObject = struct {
    primitive_type: PrimitiveType = .cube,
    custom_vertices: ?[]const Vertex = null,
    custom_indices: ?[]const u16 = null,
    position: [3]f32 = .{ 0.0, 0.0, 0.0 },
    rotation: [3]f32 = .{ 0.0, 0.0, 0.0 },
    scale: [3]f32 = .{ 1.0, 1.0, 1.0 },
    material: Material = .{},
    visible: bool = true,

    pub fn getColor(self: RenderObject) [4]f32 {
        return self.material.base_color;
    }
};

pub const Scene = struct {
    pub const MAX_VERTICES: usize = 65536;
    pub const MAX_INDICES: usize = 131072;
    pub const MAX_OBJECTS: usize = 2048;

    allocator: std.mem.Allocator = std.heap.page_allocator,

    // Default / Single Cube Data (Preserves 100% backward compatibility)
    vertex_data: [24]Vertex = primitives.cube_vertices,
    vertices: []const Vertex = &primitives.cube_vertices,
    indices: []const u16 = &primitives.cube_indices,

    // Dynamic Multi-Primitive Combined Mesh Buffers
    combined_vertices: []Vertex = &.{},
    combined_indices: []u16 = &.{},
    combined_vertex_count: usize = 0,
    combined_index_count: usize = 0,

    // Registered Scene Objects
    objects: []RenderObject = &.{},
    object_count: usize = 0,

    // Scene animation & transform state
    rotation_x: f32 = 0.0,
    rotation_y: f32 = 0.0,
    camera_distance: f32 = 3.5,
    vertices_dirty: bool = false,

    pub const cube_vertices = primitives.cube_vertices;
    pub const cube_indices = primitives.cube_indices;

    pub fn initDefault() Scene {
        var s = Scene{};
        s.allocator = std.heap.page_allocator;
        s.objects = s.allocator.alloc(RenderObject, MAX_OBJECTS) catch &.{};
        s.combined_vertices = s.allocator.alloc(Vertex, MAX_VERTICES) catch &.{};
        s.combined_indices = s.allocator.alloc(u16, MAX_INDICES) catch &.{};
        s.vertices = &s.vertex_data;
        s.indices = &cube_indices;
        return s;
    }

    pub fn deinit(self: *Scene) void {
        if (self.objects.len > 0) self.allocator.free(self.objects);
        if (self.combined_vertices.len > 0) self.allocator.free(self.combined_vertices);
        if (self.combined_indices.len > 0) self.allocator.free(self.combined_indices);
        self.objects = &.{};
        self.combined_vertices = &.{};
        self.combined_indices = &.{};
    }

    pub fn ensureObjectCapacity(self: *Scene, needed: usize) !void {
        if (needed <= self.objects.len) return;
        const new_cap = @max(needed, if (self.objects.len == 0) MAX_OBJECTS else self.objects.len * 2);
        if (self.objects.len == 0) {
            self.objects = try self.allocator.alloc(RenderObject, new_cap);
        } else {
            self.objects = try self.allocator.realloc(self.objects, new_cap);
        }
    }

    pub fn ensureMeshCapacity(self: *Scene, needed_v: usize, needed_i: usize) !void {
        if (needed_v > self.combined_vertices.len) {
            const new_vcap = @max(needed_v, if (self.combined_vertices.len == 0) MAX_VERTICES else self.combined_vertices.len * 2);
            if (self.combined_vertices.len == 0) {
                self.combined_vertices = try self.allocator.alloc(Vertex, new_vcap);
            } else {
                self.combined_vertices = try self.allocator.realloc(self.combined_vertices, new_vcap);
            }
        }
        if (needed_i > self.combined_indices.len) {
            const new_icap = @max(needed_i, if (self.combined_indices.len == 0) MAX_INDICES else self.combined_indices.len * 2);
            if (self.combined_indices.len == 0) {
                self.combined_indices = try self.allocator.alloc(u16, new_icap);
            } else {
                self.combined_indices = try self.allocator.realloc(self.combined_indices, new_icap);
            }
        }
    }

    pub fn addObject(self: *Scene, obj: RenderObject) ?usize {
        self.ensureObjectCapacity(self.object_count + 1) catch return null;
        const idx = self.object_count;
        self.objects[idx] = obj;
        self.object_count += 1;
        self.rebuildCombinedMesh();
        return idx;
    }

    pub fn addCube(self: *Scene, pos: [3]f32, scale_dim: [3]f32, mat: Material) ?usize {
        return self.addObject(.{
            .primitive_type = .cube,
            .position = pos,
            .scale = scale_dim,
            .material = mat,
        });
    }

    pub fn addSphere(self: *Scene, pos: [3]f32, radius: f32, mat: Material) ?usize {
        const dia = radius * 2.0;
        return self.addObject(.{
            .primitive_type = .sphere,
            .position = pos,
            .scale = .{ dia, dia, dia },
            .material = mat,
        });
    }

    pub fn addPyramid(self: *Scene, pos: [3]f32, scale_dim: [3]f32, mat: Material) ?usize {
        return self.addObject(.{
            .primitive_type = .pyramid,
            .position = pos,
            .scale = scale_dim,
            .material = mat,
        });
    }

    pub fn addCylinder(self: *Scene, pos: [3]f32, radius: f32, height: f32, mat: Material) ?usize {
        return self.addObject(.{
            .primitive_type = .cylinder,
            .position = pos,
            .scale = .{ radius * 2.0, height, radius * 2.0 },
            .material = mat,
        });
    }

    pub fn addPlane(self: *Scene, pos: [3]f32, size_xz: [2]f32, mat: Material) ?usize {
        return self.addObject(.{
            .primitive_type = .plane,
            .position = pos,
            .scale = .{ size_xz[0], 1.0, size_xz[1] },
            .material = mat,
        });
    }

    pub fn addCustomMesh(self: *Scene, verts: []const Vertex, inds: []const u16, pos: [3]f32, rot: [3]f32, scale_dim: [3]f32, mat: Material) ?usize {
        return self.addObject(.{
            .primitive_type = .cube,
            .custom_vertices = verts,
            .custom_indices = inds,
            .position = pos,
            .rotation = rot,
            .scale = scale_dim,
            .material = mat,
        });
    }

    pub fn clearObjects(self: *Scene) void {
        self.object_count = 0;
        self.vertices = &self.vertex_data;
        self.indices = &cube_indices;
        self.vertices_dirty = true;
    }

    /// Rebuilds combined vertex and index buffers combining all scene objects
    pub fn rebuildCombinedMesh(self: *Scene) void {
        if (self.object_count == 0) {
            self.vertices = &self.vertex_data;
            self.indices = &cube_indices;
            self.vertices_dirty = true;
            return;
        }

        self.ensureMeshCapacity(MAX_VERTICES, MAX_INDICES) catch return;

        var v_out: usize = 0;
        var i_out: usize = 0;

        for (self.objects[0..self.object_count]) |obj| {
            if (!obj.visible) continue;

            const tmpl_vertices = if (obj.custom_vertices) |cv| cv else primitives.getPrimitiveMesh(obj.primitive_type).vertices;
            const tmpl_indices = if (obj.custom_indices) |ci| ci else primitives.getPrimitiveMesh(obj.primitive_type).indices;
            if (v_out + tmpl_vertices.len > self.combined_vertices.len or i_out + tmpl_indices.len > self.combined_indices.len) {
                self.ensureMeshCapacity(v_out + tmpl_vertices.len, i_out + tmpl_indices.len) catch break;
            }

            const base_vertex = @as(u16, @intCast(v_out));
            const mat = obj.material;
            const mat_params = [4]f32{
                mat.metallic,
                mat.roughness,
                mat.emissive_intensity,
                @floatFromInt(@intFromEnum(mat.shading_model)),
            };

            for (tmpl_vertices) |v| {
                // Apply object scale
                const scaled_pos = [3]f32{
                    v.position[0] * obj.scale[0],
                    v.position[1] * obj.scale[1],
                    v.position[2] * obj.scale[2],
                };
                // Apply object rotation to position
                const rotated_pos = primitives.rotateVectorEuler(scaled_pos, obj.rotation);
                // Apply object translation
                const final_pos = [3]f32{
                    rotated_pos[0] + obj.position[0],
                    rotated_pos[1] + obj.position[1],
                    rotated_pos[2] + obj.position[2],
                };
                // Rotate surface normal
                const rotated_norm = primitives.rotateVectorEuler(v.normal, obj.rotation);
                // Tint base template vertex color by material base color
                const final_color = [3]f32{
                    v.color[0] * mat.base_color[0],
                    v.color[1] * mat.base_color[1],
                    v.color[2] * mat.base_color[2],
                };

                self.combined_vertices[v_out] = .{
                    .position = final_pos,
                    .normal = rotated_norm,
                    .color = final_color,
                    .uv = v.uv,
                    .material_params = mat_params,
                };
                v_out += 1;
            }

            for (tmpl_indices) |idx| {
                self.combined_indices[i_out] = base_vertex + idx;
                i_out += 1;
            }
        }

        self.combined_vertex_count = v_out;
        self.combined_index_count = i_out;
        self.vertices = self.combined_vertices[0..v_out];
        self.indices = self.combined_indices[0..i_out];
        self.vertices_dirty = true;
    }

    /// Automatically syncs active entities from GameState into the renderable Scene!
    pub fn syncFromGameState(self: *Scene, state: *const game_state.GameState) void {
        self.object_count = 0;

        for (&state.entities) |*ent| {
            if (ent.active == 0) continue;
            self.ensureObjectCapacity(self.object_count + 1) catch break;

            const p_type: PrimitiveType = @enumFromInt(ent.entity_type % 5);
            const sm: ShadingModel = switch (ent.shading_model) {
                1 => .unlit,
                2 => .blinn_phong,
                else => .pbr,
            };
            self.objects[self.object_count] = .{
                .primitive_type = p_type,
                .position = .{ ent.position.x, ent.position.y, ent.position.z },
                .rotation = .{ ent.rotation.x, ent.rotation.y, ent.rotation.z },
                .scale = .{ ent.scale.x, ent.scale.y, ent.scale.z },
                .material = .{
                    .base_color = ent.color,
                    .metallic = ent.metallic,
                    .roughness = ent.roughness,
                    .emissive_intensity = ent.emissive,
                    .shading_model = sm,
                },
                .visible = true,
            };
            self.object_count += 1;
        }

        self.rebuildCombinedMesh();
    }

    pub fn setFaceColor(self: *Scene, face_index: u32, r: f32, g: f32, b: f32) void {
        if (face_index >= 6) return;
        const start = face_index * 4;
        for (0..4) |i| {
            self.vertex_data[start + i].color = .{ r, g, b };
        }
        if (self.object_count == 0) {
            self.vertices = &self.vertex_data;
        }
        self.vertices_dirty = true;
    }

    pub fn getFaceColor(self: *const Scene, face_index: u32) [3]f32 {
        if (face_index >= 6) return .{ 0.0, 0.0, 0.0 };
        return self.vertex_data[face_index * 4].color;
    }

    pub fn update(self: *Scene, dt: f32) void {
        self.rotation_x += dt * 0.45;
        self.rotation_y += dt * 0.75;
    }
};

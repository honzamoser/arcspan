const std = @import("std");
const math = @import("../math.zig");
const primitives = @import("../renderer/primitives.zig");
const mat_mod = @import("../renderer/material.zig");
const scene_mod = @import("../renderer/scene.zig");

pub const Vertex = primitives.Vertex;
pub const Material = mat_mod.Material;

pub const MeshData = struct {
    vertices: []Vertex,
    indices: []u16,
    material: Material = .{},
    name: []const u8 = "",

    pub fn deinit(self: *MeshData, allocator: std.mem.Allocator) void {
        if (self.vertices.len > 0) allocator.free(self.vertices);
        if (self.indices.len > 0) allocator.free(self.indices);
        self.vertices = &.{};
        self.indices = &.{};
    }
};

pub const ModelData = struct {
    meshes: []MeshData,

    pub fn deinit(self: *ModelData, allocator: std.mem.Allocator) void {
        for (self.meshes) |*m| {
            m.deinit(allocator);
        }
        if (self.meshes.len > 0) allocator.free(self.meshes);
        self.meshes = &.{};
    }
};

/// ------------------------------------------------------------------------------------------------
/// Wavefront OBJ Loader
/// ------------------------------------------------------------------------------------------------
pub const ObjLoader = struct {
    pub fn loadFromMemory(allocator: std.mem.Allocator, text: []const u8) !MeshData {
        var positions = std.ArrayList([3]f32).empty;
        defer positions.deinit(allocator);

        var normals = std.ArrayList([3]f32).empty;
        defer normals.deinit(allocator);

        var uvs = std.ArrayList([2]f32).empty;
        defer uvs.deinit(allocator);

        var vertices = std.ArrayList(Vertex).empty;
        defer vertices.deinit(allocator);

        var indices = std.ArrayList(u16).empty;
        defer indices.deinit(allocator);

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \r\t");
            if (line.len == 0 or line[0] == '#') continue;

            var tokens = std.mem.tokenizeAny(u8, line, " \t");
            const tag = tokens.next() orelse continue;

            if (std.mem.eql(u8, tag, "v")) {
                const x = try std.fmt.parseFloat(f32, tokens.next() orelse "0");
                const y = try std.fmt.parseFloat(f32, tokens.next() orelse "0");
                const z = try std.fmt.parseFloat(f32, tokens.next() orelse "0");
                try positions.append(allocator, .{ x, y, z });
            } else if (std.mem.eql(u8, tag, "vn")) {
                const x = try std.fmt.parseFloat(f32, tokens.next() orelse "0");
                const y = try std.fmt.parseFloat(f32, tokens.next() orelse "0");
                const z = try std.fmt.parseFloat(f32, tokens.next() orelse "0");
                try normals.append(allocator, .{ x, y, z });
            } else if (std.mem.eql(u8, tag, "vt")) {
                const u = try std.fmt.parseFloat(f32, tokens.next() orelse "0");
                const v = try std.fmt.parseFloat(f32, tokens.next() orelse "0");
                try uvs.append(allocator, .{ u, v });
            } else if (std.mem.eql(u8, tag, "f")) {
                var face_indices: [4]Vertex = undefined;
                var face_count: usize = 0;

                while (tokens.next()) |face_spec| {
                    if (face_count >= 4) break; // supports triangles & quads
                    var v_idx: ?usize = null;
                    var vt_idx: ?usize = null;
                    var vn_idx: ?usize = null;

                    var spec_it = std.mem.splitScalar(u8, face_spec, '/');
                    if (spec_it.next()) |v_str| {
                        if (v_str.len > 0) {
                            const val = try std.fmt.parseInt(isize, v_str, 10);
                            v_idx = if (val > 0) @intCast(val - 1) else @intCast(@as(isize, @intCast(positions.items.len)) + val);
                        }
                    }
                    if (spec_it.next()) |vt_str| {
                        if (vt_str.len > 0) {
                            const val = try std.fmt.parseInt(isize, vt_str, 10);
                            vt_idx = if (val > 0) @intCast(val - 1) else @intCast(@as(isize, @intCast(uvs.items.len)) + val);
                        }
                    }
                    if (spec_it.next()) |vn_str| {
                        if (vn_str.len > 0) {
                            const val = try std.fmt.parseInt(isize, vn_str, 10);
                            vn_idx = if (val > 0) @intCast(val - 1) else @intCast(@as(isize, @intCast(normals.items.len)) + val);
                        }
                    }

                    const pos = if (v_idx) |idx| (if (idx < positions.items.len) positions.items[idx] else .{ 0, 0, 0 }) else .{ 0, 0, 0 };
                    const norm = if (vn_idx) |idx| (if (idx < normals.items.len) normals.items[idx] else .{ 0, 1, 0 }) else .{ 0, 1, 0 };
                    const uv = if (vt_idx) |idx| (if (idx < uvs.items.len) uvs.items[idx] else .{ 0, 0 }) else .{ 0, 0 };

                    face_indices[face_count] = .{
                        .position = pos,
                        .normal = norm,
                        .color = .{ 1.0, 1.0, 1.0 },
                        .uv = uv,
                        .material_params = .{ 0.0, 0.5, 0.0, 0.0 },
                    };
                    face_count += 1;
                }

                if (face_count >= 3) {
                    const base_idx = @as(u16, @intCast(vertices.items.len));
                    try vertices.append(allocator, face_indices[0]);
                    try vertices.append(allocator, face_indices[1]);
                    try vertices.append(allocator, face_indices[2]);
                    try indices.append(allocator, base_idx + 0);
                    try indices.append(allocator, base_idx + 1);
                    try indices.append(allocator, base_idx + 2);

                    if (face_count == 4) {
                        try vertices.append(allocator, face_indices[3]);
                        try indices.append(allocator, base_idx + 0);
                        try indices.append(allocator, base_idx + 2);
                        try indices.append(allocator, base_idx + 3);
                    }
                }
            }
        }

        return MeshData{
            .vertices = try vertices.toOwnedSlice(allocator),
            .indices = try indices.toOwnedSlice(allocator),
            .material = Material.default(),
        };
    }
};

/// ------------------------------------------------------------------------------------------------
/// glTF 2.0 (Binary .GLB and JSON .GLTF) Loader
/// ------------------------------------------------------------------------------------------------
pub const GltfLoader = struct {
    pub const GLB_MAGIC: u32 = 0x46546C67; // 'glTF'
    pub const CHUNK_JSON: u32 = 0x4E4F534A; // 'JSON'
    pub const CHUNK_BIN: u32 = 0x004E4942;  // 'BIN\0'

    pub const ComponentType = enum(u32) {
        byte = 5120,
        ubyte = 5121,
        short = 5122,
        ushort = 5123,
        uint = 5125,
        float = 5126,
    };

    pub fn isGlb(bytes: []const u8) bool {
        if (bytes.len < 12) return false;
        const magic = std.mem.readInt(u32, bytes[0..4][0..4], .little);
        return magic == GLB_MAGIC;
    }

    pub fn loadGlbFromMemory(allocator: std.mem.Allocator, bytes: []const u8) !ModelData {
        if (bytes.len < 20) return error.InvalidGlbHeader;

        const magic = std.mem.readInt(u32, bytes[0..4][0..4], .little);
        if (magic != GLB_MAGIC) return error.NotGlb;

        const version = std.mem.readInt(u32, bytes[4..8][0..4], .little);
        if (version != 2) return error.UnsupportedGltfVersion;

        const total_length = std.mem.readInt(u32, bytes[8..12][0..4], .little);
        if (total_length > bytes.len) return error.TruncatedGlb;

        var offset: usize = 12;
        var json_slice: ?[]const u8 = null;
        var bin_slice: ?[]const u8 = null;

        while (offset + 8 <= total_length) {
            const chunk_len = std.mem.readInt(u32, bytes[offset..offset + 4][0..4], .little);
            const chunk_type = std.mem.readInt(u32, bytes[offset + 4..offset + 8][0..4], .little);
            const chunk_start = offset + 8;
            const chunk_end = chunk_start + chunk_len;
            if (chunk_end > bytes.len) return error.TruncatedGlbChunk;

            if (chunk_type == CHUNK_JSON) {
                json_slice = bytes[chunk_start..chunk_end];
            } else if (chunk_type == CHUNK_BIN) {
                bin_slice = bytes[chunk_start..chunk_end];
            }
            offset = chunk_end;
        }

        const json_data = json_slice orelse return error.MissingGlbJsonChunk;
        const bin_data = bin_slice orelse &.{};

        return parseGltf(allocator, json_data, bin_data);
    }

    pub fn loadGltfJson(allocator: std.mem.Allocator, json_text: []const u8, bin_buffer: []const u8) !ModelData {
        return parseGltf(allocator, json_text, bin_buffer);
    }

    fn parseGltf(allocator: std.mem.Allocator, json_text: []const u8, bin_buffer: []const u8) !ModelData {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidGltfJson;

        const buffer_views = root.object.get("bufferViews");
        const accessors = root.object.get("accessors");
        const meshes_val = root.object.get("meshes");

        if (meshes_val == null or meshes_val.? != .array) {
            return ModelData{ .meshes = try allocator.alloc(MeshData, 0) };
        }

        var result_meshes = std.ArrayList(MeshData).empty;
        defer result_meshes.deinit(allocator);

        for (meshes_val.?.array.items) |mesh_obj| {
            if (mesh_obj != .object) continue;
            const prims = mesh_obj.object.get("primitives") orelse continue;
            if (prims != .array) continue;

            for (prims.array.items) |prim_obj| {
                if (prim_obj != .object) continue;
                const attrs = prim_obj.object.get("attributes") orelse continue;
                if (attrs != .object) continue;

                const pos_acc_idx = attrs.object.get("POSITION");
                if (pos_acc_idx == null or pos_acc_idx.? != .integer) continue;

                const norm_acc_idx = attrs.object.get("NORMAL");
                const uv_acc_idx = attrs.object.get("TEXCOORD_0");
                const ind_acc_idx = prim_obj.object.get("indices");

                const pos_slice = try readAccessorFloat3(allocator, accessors, buffer_views, bin_buffer, @intCast(pos_acc_idx.?.integer));
                defer allocator.free(pos_slice);

                var norm_slice: ?[][3]f32 = null;
                if (norm_acc_idx) |na| {
                    if (na == .integer) {
                        norm_slice = readAccessorFloat3(allocator, accessors, buffer_views, bin_buffer, @intCast(na.integer)) catch null;
                    }
                }
                defer if (norm_slice) |ns| allocator.free(ns);

                var uv_slice: ?[][2]f32 = null;
                if (uv_acc_idx) |ua| {
                    if (ua == .integer) {
                        uv_slice = readAccessorFloat2(allocator, accessors, buffer_views, bin_buffer, @intCast(ua.integer)) catch null;
                    }
                }
                defer if (uv_slice) |us| allocator.free(us);

                const vert_count = pos_slice.len;
                var verts = try allocator.alloc(Vertex, vert_count);
                for (0..vert_count) |i| {
                    verts[i] = .{
                        .position = pos_slice[i],
                        .normal = if (norm_slice) |ns| (if (i < ns.len) ns[i] else .{ 0, 1, 0 }) else .{ 0, 1, 0 },
                        .color = .{ 1.0, 1.0, 1.0 },
                        .uv = if (uv_slice) |us| (if (i < us.len) us[i] else .{ 0, 0 }) else .{ 0, 0 },
                        .material_params = .{ 0.0, 0.5, 0.0, 0.0 },
                    };
                }

                var indices: []u16 = &.{};
                if (ind_acc_idx) |ia| {
                    if (ia == .integer) {
                        indices = readAccessorIndices(allocator, accessors, buffer_views, bin_buffer, @intCast(ia.integer)) catch &.{};
                    }
                }

                if (indices.len == 0) {
                    indices = try allocator.alloc(u16, vert_count);
                    for (0..vert_count) |i| {
                        indices[i] = @intCast(i);
                    }
                }

                var mat = Material.default();
                if (prim_obj.object.get("material")) |mat_idx_val| {
                    if (mat_idx_val == .integer) {
                        if (root.object.get("materials")) |mats_val| {
                            if (mats_val == .array and @as(usize, @intCast(mat_idx_val.integer)) < mats_val.array.items.len) {
                                const m_obj = mats_val.array.items[@intCast(mat_idx_val.integer)];
                                if (m_obj == .object) {
                                    if (m_obj.object.get("pbrMetallicRoughness")) |pbr_val| {
                                        if (pbr_val == .object) {
                                            if (pbr_val.object.get("metallicFactor")) |mf| {
                                                if (mf == .float) mat.metallic = @floatCast(mf.float) else if (mf == .integer) mat.metallic = @floatFromInt(mf.integer);
                                            }
                                            if (pbr_val.object.get("roughnessFactor")) |rf| {
                                                if (rf == .float) mat.roughness = @floatCast(rf.float) else if (rf == .integer) mat.roughness = @floatFromInt(rf.integer);
                                            }
                                            if (pbr_val.object.get("baseColorFactor")) |bcf| {
                                                if (bcf == .array and bcf.array.items.len >= 3) {
                                                    for (0..@min(4, bcf.array.items.len)) |c| {
                                                        const cv = bcf.array.items[c];
                                                        if (cv == .float) mat.base_color[c] = @floatCast(cv.float) else if (cv == .integer) mat.base_color[c] = @floatFromInt(cv.integer);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                try result_meshes.append(allocator, .{
                    .vertices = verts,
                    .indices = indices,
                    .material = mat,
                });
            }
        }

        return ModelData{
            .meshes = try result_meshes.toOwnedSlice(allocator),
        };
    }

    fn readAccessorFloat3(allocator: std.mem.Allocator, accessors: ?std.json.Value, buffer_views: ?std.json.Value, bin: []const u8, acc_idx: usize) ![][3]f32 {
        if (accessors == null or accessors.? != .array or acc_idx >= accessors.?.array.items.len) return error.InvalidAccessor;
        const acc = accessors.?.array.items[acc_idx];
        if (acc != .object) return error.InvalidAccessor;

        const count_val = acc.object.get("count") orelse return error.InvalidAccessor;
        const count: usize = @intCast(count_val.integer);
        const bv_idx_val = acc.object.get("bufferView") orelse return error.InvalidAccessor;
        const bv_idx: usize = @intCast(bv_idx_val.integer);
        const acc_offset: usize = if (acc.object.get("byteOffset")) |bo| @intCast(bo.integer) else 0;

        if (buffer_views == null or buffer_views.? != .array or bv_idx >= buffer_views.?.array.items.len) return error.InvalidBufferView;
        const bv = buffer_views.?.array.items[bv_idx];
        if (bv != .object) return error.InvalidBufferView;

        const bv_offset: usize = if (bv.object.get("byteOffset")) |bo| @intCast(bo.integer) else 0;
        const start = bv_offset + acc_offset;
        const stride: usize = if (bv.object.get("byteStride")) |bs| @intCast(bs.integer) else 12;

        var out = try allocator.alloc([3]f32, count);
        for (0..count) |i| {
            const pos = start + i * stride;
            if (pos + 12 > bin.len) return error.BufferViewOutOfBounds;
            const x = @as(f32, @bitCast(std.mem.readInt(u32, bin[pos .. pos + 4][0..4], .little)));
            const y = @as(f32, @bitCast(std.mem.readInt(u32, bin[pos + 4 .. pos + 8][0..4], .little)));
            const z = @as(f32, @bitCast(std.mem.readInt(u32, bin[pos + 8 .. pos + 12][0..4], .little)));
            out[i] = .{ x, y, z };
        }
        return out;
    }

    fn readAccessorFloat2(allocator: std.mem.Allocator, accessors: ?std.json.Value, buffer_views: ?std.json.Value, bin: []const u8, acc_idx: usize) ![][2]f32 {
        if (accessors == null or accessors.? != .array or acc_idx >= accessors.?.array.items.len) return error.InvalidAccessor;
        const acc = accessors.?.array.items[acc_idx];
        if (acc != .object) return error.InvalidAccessor;

        const count_val = acc.object.get("count") orelse return error.InvalidAccessor;
        const count: usize = @intCast(count_val.integer);
        const bv_idx_val = acc.object.get("bufferView") orelse return error.InvalidAccessor;
        const bv_idx: usize = @intCast(bv_idx_val.integer);
        const acc_offset: usize = if (acc.object.get("byteOffset")) |bo| @intCast(bo.integer) else 0;

        if (buffer_views == null or buffer_views.? != .array or bv_idx >= buffer_views.?.array.items.len) return error.InvalidBufferView;
        const bv = buffer_views.?.array.items[bv_idx];
        if (bv != .object) return error.InvalidBufferView;

        const bv_offset: usize = if (bv.object.get("byteOffset")) |bo| @intCast(bo.integer) else 0;
        const start = bv_offset + acc_offset;
        const stride: usize = if (bv.object.get("byteStride")) |bs| @intCast(bs.integer) else 8;

        var out = try allocator.alloc([2]f32, count);
        for (0..count) |i| {
            const pos = start + i * stride;
            if (pos + 8 > bin.len) return error.BufferViewOutOfBounds;
            const u = @as(f32, @bitCast(std.mem.readInt(u32, bin[pos .. pos + 4][0..4], .little)));
            const v = @as(f32, @bitCast(std.mem.readInt(u32, bin[pos + 4 .. pos + 8][0..4], .little)));
            out[i] = .{ u, v };
        }
        return out;
    }

    fn readAccessorIndices(allocator: std.mem.Allocator, accessors: ?std.json.Value, buffer_views: ?std.json.Value, bin: []const u8, acc_idx: usize) ![]u16 {
        if (accessors == null or accessors.? != .array or acc_idx >= accessors.?.array.items.len) return error.InvalidAccessor;
        const acc = accessors.?.array.items[acc_idx];
        if (acc != .object) return error.InvalidAccessor;

        const count_val = acc.object.get("count") orelse return error.InvalidAccessor;
        const count: usize = @intCast(count_val.integer);
        const comp_type_val = acc.object.get("componentType") orelse return error.InvalidAccessor;
        const comp_type: u32 = @intCast(comp_type_val.integer);

        const bv_idx_val = acc.object.get("bufferView") orelse return error.InvalidAccessor;
        const bv_idx: usize = @intCast(bv_idx_val.integer);
        const acc_offset: usize = if (acc.object.get("byteOffset")) |bo| @intCast(bo.integer) else 0;

        if (buffer_views == null or buffer_views.? != .array or bv_idx >= buffer_views.?.array.items.len) return error.InvalidBufferView;
        const bv = buffer_views.?.array.items[bv_idx];
        if (bv != .object) return error.InvalidBufferView;

        const bv_offset: usize = if (bv.object.get("byteOffset")) |bo| @intCast(bo.integer) else 0;
        const start = bv_offset + acc_offset;

        var out = try allocator.alloc(u16, count);
        for (0..count) |i| {
            if (comp_type == @intFromEnum(ComponentType.ushort)) {
                const pos = start + i * 2;
                if (pos + 2 > bin.len) return error.BufferViewOutOfBounds;
                out[i] = std.mem.readInt(u16, bin[pos .. pos + 2][0..2], .little);
            } else if (comp_type == @intFromEnum(ComponentType.ubyte)) {
                const pos = start + i;
                if (pos + 1 > bin.len) return error.BufferViewOutOfBounds;
                out[i] = bin[pos];
            } else if (comp_type == @intFromEnum(ComponentType.uint)) {
                const pos = start + i * 4;
                if (pos + 4 > bin.len) return error.BufferViewOutOfBounds;
                const val32 = std.mem.readInt(u32, bin[pos .. pos + 4][0..4], .little);
                out[i] = @intCast(val32);
            } else {
                return error.UnsupportedIndexType;
            }
        }
        return out;
    }
};

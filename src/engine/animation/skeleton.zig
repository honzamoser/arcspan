const std = @import("std");
const math = @import("../math.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

pub const MAX_BONES: usize = 128;

pub const Bone = struct {
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: u8 = 0,
    parent_index: ?u16 = null,
    local_transform: Mat4 = Mat4.identity,
    inverse_bind_matrix: Mat4 = Mat4.identity,

    pub fn setName(self: *Bone, str: []const u8) void {
        const copy_len = @min(str.len, 32);
        @memcpy(self.name[0..copy_len], str[0..copy_len]);
        self.name_len = @intCast(copy_len);
    }

    pub fn getName(self: *const Bone) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Keyframe = struct {
    time: f32,
    translation: Vec3 = Vec3.zero,
    scale: Vec3 = Vec3.init(1, 1, 1),
    rotation_euler: Vec3 = Vec3.zero, // Pitch, Yaw, Roll radians

    pub fn toMatrix(self: Keyframe) Mat4 {
        const t = Mat4.translation(self.translation.x, self.translation.y, self.translation.z);
        const rx = Mat4.rotationX(self.rotation_euler.x);
        const ry = Mat4.rotationY(self.rotation_euler.y);
        const rz = Mat4.rotationZ(self.rotation_euler.z);
        const s = Mat4.scaling(self.scale.x, self.scale.y, self.scale.z);
        // T * Rz * Ry * Rx * S
        return t.mul(rz).mul(ry).mul(rx).mul(s);
    }
};

pub const BoneTrack = struct {
    bone_index: u16,
    keyframes: []Keyframe,

    pub fn sample(self: BoneTrack, time: f32) Mat4 {
        if (self.keyframes.len == 0) return Mat4.identity;
        if (self.keyframes.len == 1) return self.keyframes[0].toMatrix();

        if (time <= self.keyframes[0].time) return self.keyframes[0].toMatrix();
        if (time >= self.keyframes[self.keyframes.len - 1].time) {
            return self.keyframes[self.keyframes.len - 1].toMatrix();
        }

        // Binary search / linear scan for keyframe pair
        var idx: usize = 0;
        while (idx + 1 < self.keyframes.len and self.keyframes[idx + 1].time < time) : (idx += 1) {}

        const k0 = self.keyframes[idx];
        const k1 = self.keyframes[idx + 1];
        const span = k1.time - k0.time;
        const factor = if (span > 1e-6) (time - k0.time) / span else 0.0;

        // Linear interpolation of translation, scale, and euler rotation
        const t = Vec3.init(
            k0.translation.x + (k1.translation.x - k0.translation.x) * factor,
            k0.translation.y + (k1.translation.y - k0.translation.y) * factor,
            k0.translation.z + (k1.translation.z - k0.translation.z) * factor,
        );
        const s = Vec3.init(
            k0.scale.x + (k1.scale.x - k0.scale.x) * factor,
            k0.scale.y + (k1.scale.y - k0.scale.y) * factor,
            k0.scale.z + (k1.scale.z - k0.scale.z) * factor,
        );
        const r = Vec3.init(
            k0.rotation_euler.x + (k1.rotation_euler.x - k0.rotation_euler.x) * factor,
            k0.rotation_euler.y + (k1.rotation_euler.y - k0.rotation_euler.y) * factor,
            k0.rotation_euler.z + (k1.rotation_euler.z - k0.rotation_euler.z) * factor,
        );

        const interp_kf = Keyframe{
            .time = time,
            .translation = t,
            .scale = s,
            .rotation_euler = r,
        };
        return interp_kf.toMatrix();
    }
};

pub const AnimationClip = struct {
    name: []const u8,
    duration: f32,
    tracks: []BoneTrack,

    pub fn deinit(self: *AnimationClip, allocator: std.mem.Allocator) void {
        for (self.tracks) |t| {
            if (t.keyframes.len > 0) allocator.free(t.keyframes);
        }
        if (self.tracks.len > 0) allocator.free(self.tracks);
        self.tracks = &.{};
    }
};

pub const Skeleton = struct {
    bones: [MAX_BONES]Bone = [_]Bone{.{}} ** MAX_BONES,
    bone_count: usize = 0,
    model_matrices: [MAX_BONES]Mat4 = [_]Mat4{Mat4.identity} ** MAX_BONES,
    skinning_palette: [MAX_BONES]Mat4 = [_]Mat4{Mat4.identity} ** MAX_BONES,

    pub fn addBone(self: *Skeleton, name: []const u8, parent: ?u16, local: Mat4, inv_bind: Mat4) ?u16 {
        if (self.bone_count >= MAX_BONES) return null;
        const idx: u16 = @intCast(self.bone_count);
        self.bones[idx] = .{
            .parent_index = parent,
            .local_transform = local,
            .inverse_bind_matrix = inv_bind,
        };
        self.bones[idx].setName(name);
        self.bone_count += 1;
        return idx;
    }

    /// Evaluates hierarchical forward kinematics down bone tree
    pub fn updateHierarchy(self: *Skeleton) void {
        for (0..self.bone_count) |i| {
            const b = self.bones[i];
            if (b.parent_index) |parent| {
                self.model_matrices[i] = self.model_matrices[parent].mul(b.local_transform);
            } else {
                self.model_matrices[i] = b.local_transform;
            }
            // Palette = ModelTransform * InverseBindMatrix
            self.skinning_palette[i] = self.model_matrices[i].mul(b.inverse_bind_matrix);
        }
    }

    /// Applies animation clip sampled at given time and recalculates skinning palette
    pub fn applyAnimation(self: *Skeleton, clip: *const AnimationClip, time_seconds: f32) void {
        const loop_time = if (clip.duration > 0.0) @mod(time_seconds, clip.duration) else 0.0;
        for (clip.tracks) |track| {
            if (track.bone_index < self.bone_count) {
                self.bones[track.bone_index].local_transform = track.sample(loop_time);
            }
        }
        self.updateHierarchy();
    }
};

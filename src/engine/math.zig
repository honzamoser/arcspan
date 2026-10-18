const std = @import("std");

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub const zero = Vec3{ .x = 0, .y = 0, .z = 0 };

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn scale(v: Vec3, s: f32) Vec3 {
        return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s };
    }

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    pub fn length(v: Vec3) f32 {
        return @sqrt(v.dot(v));
    }

    pub fn normalize(v: Vec3) Vec3 {
        const len = v.length();
        if (len == 0) return v;
        return v.scale(1.0 / len);
    }
};

pub const Mat4 = struct {
    // Column-major order: [col][row]
    m: [4][4]f32,

    pub const identity = Mat4{
        .m = .{
            .{ 1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ 0, 0, 0, 1 },
        },
    };

    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var res: Mat4 = undefined;
        inline for (0..4) |c| {
            inline for (0..4) |r| {
                res.m[c][r] = a.m[0][r] * b.m[c][0] +
                    a.m[1][r] * b.m[c][1] +
                    a.m[2][r] * b.m[c][2] +
                    a.m[3][r] * b.m[c][3];
            }
        }
        return res;
    }

    pub fn translation(x: f32, y: f32, z: f32) Mat4 {
        var res = Mat4.identity;
        res.m[3][0] = x;
        res.m[3][1] = y;
        res.m[3][2] = z;
        return res;
    }

    pub fn scaling(sx: f32, sy: f32, sz: f32) Mat4 {
        var res = Mat4.identity;
        res.m[0][0] = sx;
        res.m[1][1] = sy;
        res.m[2][2] = sz;
        return res;
    }

    pub fn rotationX(rad: f32) Mat4 {
        const c = @cos(rad);
        const s = @sin(rad);
        var res = Mat4.identity;
        res.m[1][1] = c;
        res.m[1][2] = s;
        res.m[2][1] = -s;
        res.m[2][2] = c;
        return res;
    }

    pub fn rotationY(rad: f32) Mat4 {
        const c = @cos(rad);
        const s = @sin(rad);
        var res = Mat4.identity;
        res.m[0][0] = c;
        res.m[0][2] = -s;
        res.m[2][0] = s;
        res.m[2][2] = c;
        return res;
    }

    pub fn rotationZ(rad: f32) Mat4 {
        const c = @cos(rad);
        const s = @sin(rad);
        var res = Mat4.identity;
        res.m[0][0] = c;
        res.m[0][1] = s;
        res.m[1][0] = -s;
        res.m[1][1] = c;
        return res;
    }

    pub fn perspective(fov_rad: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const f = 1.0 / @tan(fov_rad * 0.5);
        const fn_range = 1.0 / (near - far);

        var res = Mat4{ .m = [_][4]f32{[_]f32{0} ** 4} ** 4 };
        res.m[0][0] = f / aspect;
        res.m[1][1] = f;
        res.m[2][2] = far * fn_range; // wgpu depth range is [0, 1]
        res.m[2][3] = -1.0;
        res.m[3][2] = near * far * fn_range;
        return res;
    }

    pub fn orthographic(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4 {
        const r_l = 1.0 / (right - left);
        const t_b = 1.0 / (top - bottom);
        const f_n = 1.0 / (far - near);

        var res = Mat4{ .m = [_][4]f32{[_]f32{0} ** 4} ** 4 };
        res.m[0][0] = 2.0 * r_l;
        res.m[1][1] = 2.0 * t_b;
        res.m[2][2] = f_n; // WebGPU depth range [0, 1]
        res.m[3][0] = -(right + left) * r_l;
        res.m[3][1] = -(top + bottom) * t_b;
        res.m[3][2] = -near * f_n;
        res.m[3][3] = 1.0;
        return res;
    }

    pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
        const f = eye.sub(target).normalize();
        const s = up.cross(f).normalize();
        const u = f.cross(s);

        var res = Mat4.identity;
        res.m[0][0] = s.x;
        res.m[1][0] = s.y;
        res.m[2][0] = s.z;

        res.m[0][1] = u.x;
        res.m[1][1] = u.y;
        res.m[2][1] = u.z;

        res.m[0][2] = f.x;
        res.m[1][2] = f.y;
        res.m[2][2] = f.z;

        res.m[3][0] = -s.dot(eye);
        res.m[3][1] = -u.dot(eye);
        res.m[3][2] = -f.dot(eye);

        return res;
    }

    pub fn transformVec4(self: Mat4, v: [4]f32) [4]f32 {
        return .{
            self.m[0][0] * v[0] + self.m[1][0] * v[1] + self.m[2][0] * v[2] + self.m[3][0] * v[3],
            self.m[0][1] * v[0] + self.m[1][1] * v[1] + self.m[2][1] * v[2] + self.m[3][1] * v[3],
            self.m[0][2] * v[0] + self.m[1][2] * v[1] + self.m[2][2] * v[2] + self.m[3][2] * v[3],
            self.m[0][3] * v[0] + self.m[1][3] * v[1] + self.m[2][3] * v[2] + self.m[3][3] * v[3],
        };
    }

    /// Computes the 4x4 matrix inverse using Cramer's rule. Returns null if singular.
    pub fn inverse(self: Mat4) ?Mat4 {
        const m = self.m;
        // Flat array indexed by [col * 4 + row]
        const a00 = m[0][0]; const a01 = m[0][1]; const a02 = m[0][2]; const a03 = m[0][3];
        const a10 = m[1][0]; const a11 = m[1][1]; const a12 = m[1][2]; const a13 = m[1][3];
        const a20 = m[2][0]; const a21 = m[2][1]; const a22 = m[2][2]; const a23 = m[2][3];
        const a30 = m[3][0]; const a31 = m[3][1]; const a32 = m[3][2]; const a33 = m[3][3];

        const b00 = a00 * a11 - a01 * a10;
        const b01 = a00 * a12 - a02 * a10;
        const b02 = a00 * a13 - a03 * a10;
        const b03 = a01 * a12 - a02 * a11;
        const b04 = a01 * a13 - a03 * a11;
        const b05 = a02 * a13 - a03 * a12;
        const b06 = a20 * a31 - a21 * a30;
        const b07 = a20 * a32 - a22 * a30;
        const b08 = a20 * a33 - a23 * a30;
        const b09 = a21 * a32 - a22 * a31;
        const b10 = a21 * a33 - a23 * a31;
        const b11 = a22 * a33 - a23 * a32;

        const det = b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06;
        if (@abs(det) < 1e-7) return null;

        const inv_det = 1.0 / det;
        var res: Mat4 = undefined;

        res.m[0][0] = (a11 * b11 - a12 * b10 + a13 * b09) * inv_det;
        res.m[0][1] = (-a01 * b11 + a02 * b10 - a03 * b09) * inv_det;
        res.m[0][2] = (a31 * b05 - a32 * b04 + a33 * b03) * inv_det;
        res.m[0][3] = (-a21 * b05 + a22 * b04 - a23 * b03) * inv_det;

        res.m[1][0] = (-a10 * b11 + a12 * b08 - a13 * b07) * inv_det;
        res.m[1][1] = (a00 * b11 - a02 * b08 + a03 * b07) * inv_det;
        res.m[1][2] = (-a30 * b05 + a32 * b02 - a33 * b01) * inv_det;
        res.m[1][3] = (a20 * b05 - a22 * b02 + a23 * b01) * inv_det;

        res.m[2][0] = (a10 * b10 - a11 * b08 + a13 * b06) * inv_det;
        res.m[2][1] = (-a00 * b10 + a01 * b08 - a03 * b06) * inv_det;
        res.m[2][2] = (a30 * b04 - a31 * b02 + a33 * b00) * inv_det;
        res.m[2][3] = (-a20 * b04 + a21 * b02 - a23 * b00) * inv_det;

        res.m[3][0] = (-a10 * b09 + a11 * b07 - a12 * b06) * inv_det;
        res.m[3][1] = (a00 * b09 - a01 * b07 + a02 * b06) * inv_det;
        res.m[3][2] = (-a30 * b03 + a31 * b01 - a32 * b00) * inv_det;
        res.m[3][3] = (a20 * b03 - a21 * b01 + a22 * b00) * inv_det;

        return res;
    }
};

pub const Ray = struct {
    origin: Vec3,
    direction: Vec3,

    pub fn init(origin: Vec3, direction: Vec3) Ray {
        return .{
            .origin = origin,
            .direction = direction.normalize(),
        };
    }

    pub fn pointAt(self: Ray, t: f32) Vec3 {
        return self.origin.add(self.direction.scale(t));
    }

    /// Intersects ray with horizontal plane at Y = plane_y. Returns intersection point if hit in front of ray.
    pub fn intersectPlaneY(self: Ray, plane_y: f32) ?Vec3 {
        if (@abs(self.direction.y) < 1e-6) return null; // Parallel to plane
        const t = (plane_y - self.origin.y) / self.direction.y;
        if (t < 0.0) return null; // Behind ray
        return self.pointAt(t);
    }
};

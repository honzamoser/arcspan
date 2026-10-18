const std = @import("std");

pub const Image = struct {
    width: u32,
    height: u32,
    channels: u8, // 3 = RGB, 4 = RGBA
    pixels: []u8, // RGBA8

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        if (self.pixels.len > 0) allocator.free(self.pixels);
        self.pixels = &.{};
    }
};

/// ------------------------------------------------------------------------------------------------
/// QOI (Quite OK Image) Fast Lossless Decoder (Pure Zig)
/// Spec: https://qoiformat.org/qoi-specification.pdf
/// ------------------------------------------------------------------------------------------------
pub const QoiDecoder = struct {
    pub const QOI_MAGIC: u32 = 0x716f6966; // 'qoif'
    pub const QOI_OP_INDEX: u8 = 0x00; // 00xxxxxx
    pub const QOI_OP_DIFF: u8 = 0x40;  // 01xxxxxx
    pub const QOI_OP_LUMA: u8 = 0x80;  // 10xxxxxx
    pub const QOI_OP_RUN: u8 = 0xc0;   // 11xxxxxx
    pub const QOI_OP_RGB: u8 = 0xfe;
    pub const QOI_OP_RGBA: u8 = 0xff;
    pub const QOI_MASK_2: u8 = 0xc0;

    fn colorHash(r: u8, g: u8, b: u8, a: u8) usize {
        const ur: usize = r;
        const ug: usize = g;
        const ub: usize = b;
        const ua: usize = a;
        return (ur * 3 + ug * 5 + ub * 7 + ua * 11) % 64;
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Image {
        if (bytes.len < 14 + 8) return error.InvalidQoiData;

        const magic = std.mem.readInt(u32, bytes[0..4][0..4], .big);
        if (magic != QOI_MAGIC) return error.InvalidQoiMagic;

        const width = std.mem.readInt(u32, bytes[4..8][0..4], .big);
        const height = std.mem.readInt(u32, bytes[8..12][0..4], .big);
        const channels = bytes[12];
        const colorspace = bytes[13];
        _ = colorspace;

        if (width == 0 or height == 0 or (channels != 3 and channels != 4)) {
            return error.InvalidQoiHeader;
        }

        const total_pixels = @as(usize, width) * @as(usize, height);
        var pixels = try allocator.alloc(u8, total_pixels * 4);
        errdefer allocator.free(pixels);

        var index: [64][4]u8 = [_][4]u8{[_]u8{ 0, 0, 0, 0 }} ** 64;
        var r: u8 = 0;
        var g: u8 = 0;
        var b: u8 = 0;
        var a: u8 = 255;

        var in_idx: usize = 14;
        var out_idx: usize = 0;

        while (in_idx < bytes.len - 8 and out_idx < pixels.len) {
            const b1 = bytes[in_idx];
            in_idx += 1;

            if (b1 == QOI_OP_RGB) {
                if (in_idx + 3 > bytes.len) return error.UnexpectedEof;
                r = bytes[in_idx];
                g = bytes[in_idx + 1];
                b = bytes[in_idx + 2];
                in_idx += 3;
            } else if (b1 == QOI_OP_RGBA) {
                if (in_idx + 4 > bytes.len) return error.UnexpectedEof;
                r = bytes[in_idx];
                g = bytes[in_idx + 1];
                b = bytes[in_idx + 2];
                a = bytes[in_idx + 3];
                in_idx += 4;
            } else if ((b1 & QOI_MASK_2) == QOI_OP_INDEX) {
                const idx = b1 & 0x3f;
                r = index[idx][0];
                g = index[idx][1];
                b = index[idx][2];
                a = index[idx][3];
            } else if ((b1 & QOI_MASK_2) == QOI_OP_DIFF) {
                const dr = @as(i8, @intCast((b1 >> 4) & 0x03)) - 2;
                const dg = @as(i8, @intCast((b1 >> 2) & 0x03)) - 2;
                const db = @as(i8, @intCast(b1 & 0x03)) - 2;
                r +%= @as(u8, @bitCast(dr));
                g +%= @as(u8, @bitCast(dg));
                b +%= @as(u8, @bitCast(db));
            } else if ((b1 & QOI_MASK_2) == QOI_OP_LUMA) {
                if (in_idx >= bytes.len) return error.UnexpectedEof;
                const b2 = bytes[in_idx];
                in_idx += 1;
                const dg = @as(i8, @intCast(b1 & 0x3f)) - 32;
                const dr = dg + @as(i8, @intCast((b2 >> 4) & 0x0f)) - 8;
                const db = dg + @as(i8, @intCast(b2 & 0x0f)) - 8;
                r +%= @as(u8, @bitCast(dr));
                g +%= @as(u8, @bitCast(dg));
                b +%= @as(u8, @bitCast(db));
            } else if ((b1 & QOI_MASK_2) == QOI_OP_RUN) {
                const run = (b1 & 0x3f) + 1;
                for (0..run) |_| {
                    if (out_idx + 4 > pixels.len) break;
                    pixels[out_idx + 0] = r;
                    pixels[out_idx + 1] = g;
                    pixels[out_idx + 2] = b;
                    pixels[out_idx + 3] = a;
                    out_idx += 4;
                }
                index[colorHash(r, g, b, a)] = .{ r, g, b, a };
                continue;
            }

            index[colorHash(r, g, b, a)] = .{ r, g, b, a };
            pixels[out_idx + 0] = r;
            pixels[out_idx + 1] = g;
            pixels[out_idx + 2] = b;
            pixels[out_idx + 3] = a;
            out_idx += 4;
        }

        return Image{
            .width = width,
            .height = height,
            .channels = 4,
            .pixels = pixels,
        };
    }

    /// Helper to encode raw RGBA pixels into QOI binary format
    pub fn encode(allocator: std.mem.Allocator, width: u32, height: u32, rgba_pixels: []const u8) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);

        // Header: 'qoif' (4) + width (4) + height (4) + channels (1) + colorspace (1)
        try out.appendSlice(allocator, "qoif");
        var w_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &w_buf, width, .big);
        try out.appendSlice(allocator, &w_buf);
        var h_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &h_buf, height, .big);
        try out.appendSlice(allocator, &h_buf);
        try out.append(allocator, 4); // RGBA
        try out.append(allocator, 0); // sRGB

        var index: [64][4]u8 = [_][4]u8{[_]u8{ 0, 0, 0, 0 }} ** 64;
        var prev_r: u8 = 0;
        var prev_g: u8 = 0;
        var prev_b: u8 = 0;
        var prev_a: u8 = 255;
        var run: u8 = 0;

        const total_pixels = @as(usize, width) * @as(usize, height);
        for (0..total_pixels) |i| {
            const r = rgba_pixels[i * 4 + 0];
            const g = rgba_pixels[i * 4 + 1];
            const b = rgba_pixels[i * 4 + 2];
            const a = rgba_pixels[i * 4 + 3];

            if (r == prev_r and g == prev_g and b == prev_b and a == prev_a) {
                run += 1;
                if (run == 62) {
                    try out.append(allocator, QOI_OP_RUN | (run - 1));
                    run = 0;
                }
            } else {
                if (run > 0) {
                    try out.append(allocator, QOI_OP_RUN | (run - 1));
                    run = 0;
                }

                const hash = colorHash(r, g, b, a);
                if (index[hash][0] == r and index[hash][1] == g and index[hash][2] == b and index[hash][3] == a) {
                    try out.append(allocator, QOI_OP_INDEX | @as(u8, @truncate(hash)));
                } else {
                    index[hash] = .{ r, g, b, a };

                    if (a == prev_a) {
                        const vr = @as(i16, r) - @as(i16, prev_r);
                        const vg = @as(i16, g) - @as(i16, prev_g);
                        const vb = @as(i16, b) - @as(i16, prev_b);

                        const vg_r = vr - vg;
                        const vg_b = vb - vg;

                        if (vr >= -2 and vr <= 1 and vg >= -2 and vg <= 1 and vb >= -2 and vb <= 1) {
                            try out.append(allocator, QOI_OP_DIFF | @as(u8, @truncate((@as(u16, @intCast(vr + 2)) << 4) | (@as(u16, @intCast(vg + 2)) << 2) | @as(u16, @intCast(vb + 2)))));
                        } else if (vg_r >= -8 and vg_r <= 7 and vg >= -32 and vg <= 31 and vg_b >= -8 and vg_b <= 7) {
                            try out.append(allocator, QOI_OP_LUMA | @as(u8, @truncate(@as(u16, @intCast(vg + 32)))));
                            try out.append(allocator, @as(u8, @truncate((@as(u16, @intCast(vg_r + 8)) << 4) | @as(u16, @intCast(vg_b + 8)))));
                        } else {
                            try out.append(allocator, QOI_OP_RGB);
                            try out.append(allocator, r);
                            try out.append(allocator, g);
                            try out.append(allocator, b);
                        }
                    } else {
                        try out.append(allocator, QOI_OP_RGBA);
                        try out.append(allocator, r);
                        try out.append(allocator, g);
                        try out.append(allocator, b);
                        try out.append(allocator, a);
                    }
                }
            }

            prev_r = r;
            prev_g = g;
            prev_b = b;
            prev_a = a;
        }

        if (run > 0) {
            try out.append(allocator, QOI_OP_RUN | (run - 1));
        }

        // 8-byte end padding [0, 0, 0, 0, 0, 0, 0, 1]
        try out.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 });

        return out.toOwnedSlice(allocator);
    }
};

/// ------------------------------------------------------------------------------------------------
/// TGA Uncompressed 24/32-bit Image Decoder
/// ------------------------------------------------------------------------------------------------
pub const TgaDecoder = struct {
    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Image {
        if (bytes.len < 18) return error.InvalidTgaHeader;

        const id_len = bytes[0];
        const image_type = bytes[2];
        if (image_type != 2) return error.UnsupportedTgaType; // Only uncompressed true-color

        const width = std.mem.readInt(u16, bytes[12..14][0..2], .little);
        const height = std.mem.readInt(u16, bytes[14..16][0..2], .little);
        const bpp = bytes[16];
        const descriptor = bytes[17];
        const flip_y = (descriptor & 0x20) == 0; // standard TGA origin is bottom-left

        if (width == 0 or height == 0 or (bpp != 24 and bpp != 32)) {
            return error.InvalidTgaDimensions;
        }

        const data_start = 18 + id_len;
        const bytes_per_pixel = bpp / 8;
        const total_pixels = @as(usize, width) * @as(usize, height);
        if (data_start + total_pixels * bytes_per_pixel > bytes.len) return error.TruncatedTgaData;

        var pixels = try allocator.alloc(u8, total_pixels * 4);
        errdefer allocator.free(pixels);

        for (0..height) |y| {
            const src_y = if (flip_y) height - 1 - y else y;
            for (0..width) |x| {
                const src_idx = data_start + (src_y * width + x) * bytes_per_pixel;
                const dst_idx = (y * width + x) * 4;
                const b = bytes[src_idx + 0];
                const g = bytes[src_idx + 1];
                const r = bytes[src_idx + 2];
                const a = if (bytes_per_pixel == 4) bytes[src_idx + 3] else 255;
                pixels[dst_idx + 0] = r;
                pixels[dst_idx + 1] = g;
                pixels[dst_idx + 2] = b;
                pixels[dst_idx + 3] = a;
            }
        }

        return Image{
            .width = width,
            .height = height,
            .channels = 4,
            .pixels = pixels,
        };
    }
};

/// ------------------------------------------------------------------------------------------------
/// Universal Image Loader (auto-detects QOI, TGA)
/// ------------------------------------------------------------------------------------------------
pub const TextureLoader = struct {
    pub fn loadFromMemory(allocator: std.mem.Allocator, bytes: []const u8) !Image {
        if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "qoif")) {
            return QoiDecoder.decode(allocator, bytes);
        }
        return TgaDecoder.decode(allocator, bytes);
    }

    /// Downsamples RGBA image by 2x for mipmap generation
    pub fn generateNextMipLevel(allocator: std.mem.Allocator, width: u32, height: u32, src: []const u8) !struct { width: u32, height: u32, pixels: []u8 } {
        const mip_w = @max(1, width / 2);
        const mip_h = @max(1, height / 2);
        var dst = try allocator.alloc(u8, mip_w * mip_h * 4);

        for (0..mip_h) |y| {
            for (0..mip_w) |x| {
                const src_x0 = x * 2;
                const src_y0 = y * 2;
                const src_x1 = @min(width - 1, src_x0 + 1);
                const src_y1 = @min(height - 1, src_y0 + 1);

                var r: u32 = 0;
                var g: u32 = 0;
                var b: u32 = 0;
                var a: u32 = 0;

                const coords = [_][2]usize{
                    .{ src_x0, src_y0 },
                    .{ src_x1, src_y0 },
                    .{ src_x0, src_y1 },
                    .{ src_x1, src_y1 },
                };

                for (coords) |c| {
                    const idx = (c[1] * width + c[0]) * 4;
                    r += src[idx + 0];
                    g += src[idx + 1];
                    b += src[idx + 2];
                    a += src[idx + 3];
                }

                const dst_idx = (y * mip_w + x) * 4;
                dst[dst_idx + 0] = @truncate(r / 4);
                dst[dst_idx + 1] = @truncate(g / 4);
                dst[dst_idx + 2] = @truncate(b / 4);
                dst[dst_idx + 3] = @truncate(a / 4);
            }
        }

        return .{ .width = mip_w, .height = mip_h, .pixels = dst };
    }
};

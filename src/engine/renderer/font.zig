//! Font Glyph Atlas & Signed Distance Field (SDF) Texture Generator
//! Complies with AGENTS.md: pure reusable engine infrastructure in src/engine/renderer/.

const std = @import("std");
const glyph_data = @import("font_glyph_data.zig");

pub const GlyphMetrics = struct {
    char_code: u8,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    advance: f32, // Horizontal advance multiplier (relative to font_size)
    bearing_x: f32, // Horizontal offset to the leftmost visible column (relative to font_size)
    min_x: u8,
    max_x: u8,
};

pub const FontAtlas = struct {
    pub const ATLAS_WIDTH: u32 = 512;
    pub const ATLAS_HEIGHT: u32 = 256;
    pub const CELL_SIZE: u32 = 32;
    pub const COLS: u32 = 16;
    pub const ROWS: u32 = 6;
    pub const FIRST_CHAR: u8 = 32;
    pub const LAST_CHAR: u8 = 126;
    pub const GLYPH_COUNT: usize = (LAST_CHAR - FIRST_CHAR + 1);

    metrics: [GLYPH_COUNT]GlyphMetrics = undefined,

    pub fn init() FontAtlas {
        var atlas = FontAtlas{};
        atlas.computeMetrics();
        return atlas;
    }

    fn computeMetrics(self: *FontAtlas) void {
        for (FIRST_CHAR..LAST_CHAR + 1) |char_code_usize| {
            const c: u8 = @intCast(char_code_usize);
            const idx = c - FIRST_CHAR;
            const col = @as(u32, @intCast(idx % COLS));
            const row = @as(u32, @intCast(idx / COLS));

            const uv_u0 = @as(f32, @floatFromInt(col * CELL_SIZE)) / @as(f32, @floatFromInt(ATLAS_WIDTH));
            const uv_v0 = @as(f32, @floatFromInt(row * CELL_SIZE)) / @as(f32, @floatFromInt(ATLAS_HEIGHT));
            const uv_u1 = @as(f32, @floatFromInt((col + 1) * CELL_SIZE)) / @as(f32, @floatFromInt(ATLAS_WIDTH));
            const uv_v1 = @as(f32, @floatFromInt((row + 1) * CELL_SIZE)) / @as(f32, @floatFromInt(ATLAS_HEIGHT));

            if (c == ' ') {
                self.metrics[idx] = .{
                    .char_code = c,
                    .u0 = uv_u0,
                    .v0 = uv_v0,
                    .u1 = uv_u1,
                    .v1 = uv_v1,
                    .advance = 0.40,
                    .bearing_x = 0.0,
                    .min_x = 0,
                    .max_x = 0,
                };
                continue;
            }

            const glyph_offset: usize = (@as(usize, c) - 33) * 8;
            const bytes = glyph_data.GLYPH_BYTES[glyph_offset .. glyph_offset + 8];

            var min_col: u8 = 7;
            var max_col: u8 = 0;
            var has_pixels = false;

            for (0..8) |gy| {
                const b = bytes[gy];
                if (b == 0) continue;
                for (0..8) |gx_usize| {
                    const gx: u8 = @intCast(gx_usize);
                    if (((b >> @as(u3, @intCast(gx))) & 1) != 0) {
                        has_pixels = true;
                        if (gx < min_col) min_col = gx;
                        if (gx > max_col) max_col = gx;
                    }
                }
            }

            const bearing_x: f32 = if (has_pixels) @as(f32, @floatFromInt(min_col)) * (3.0 / 24.0) else 0.0;
            const width_col: f32 = if (has_pixels) @as(f32, @floatFromInt(max_col - min_col + 1)) else 4.0;
            const advance: f32 = (width_col + 1.25) * (3.0 / 24.0);

            self.metrics[idx] = .{
                .char_code = c,
                .u0 = uv_u0,
                .v0 = uv_v0,
                .u1 = uv_u1,
                .v1 = uv_v1,
                .advance = advance,
                .bearing_x = bearing_x,
                .min_x = if (has_pixels) min_col else 0,
                .max_x = if (has_pixels) max_col else 0,
            };
        }
    }

    pub fn getMetrics(self: *const FontAtlas, c: u8) GlyphMetrics {
        if (c >= FIRST_CHAR and c <= LAST_CHAR) {
            return self.metrics[c - FIRST_CHAR];
        }
        return self.metrics['?' - FIRST_CHAR];
    }

    /// Measures the pixel width and height of a text string at a given font size.
    pub fn measureText(self: *const FontAtlas, text: []const u8, font_size: f32) [2]f32 {
        var cursor_x: f32 = 0.0;
        var max_x: f32 = 0.0;
        var line_count: f32 = 1.0;

        for (text) |c| {
            if (c == '\n') {
                if (cursor_x > max_x) max_x = cursor_x;
                cursor_x = 0.0;
                line_count += 1.0;
                continue;
            }
            const m = self.getMetrics(c);
            cursor_x += m.advance * font_size;
        }
        if (cursor_x > max_x) max_x = cursor_x;
        return .{ max_x, line_count * font_size * 1.2 };
    }

    /// Renders an exact Signed Distance Field (SDF) texture for all printable ASCII characters.
    /// Output buffer must have size ATLAS_WIDTH * ATLAS_HEIGHT * 4 bytes (RGBA8).
    pub fn generateSdfRgba8(self: *const FontAtlas, out_pixels: []u8) void {
        @memset(out_pixels, 0);

        // Spread radius in pixels inside the 32x32 cell
        const spread: f32 = 4.0;
        const search_radius: i32 = 5;

        for (FIRST_CHAR..LAST_CHAR + 1) |char_code_usize| {
            const c: u8 = @intCast(char_code_usize);
            if (c == ' ') continue;

            const idx = c - FIRST_CHAR;
            const col = idx % COLS;
            const row = idx / COLS;
            const cell_x = col * CELL_SIZE;
            const cell_y = row * CELL_SIZE;

            const glyph_offset: usize = (@as(usize, c) - 33) * 8;
            const bytes = glyph_data.GLYPH_BYTES[glyph_offset .. glyph_offset + 8];

            // 1. Build an in/out bitmap mask for the 32x32 cell
            // 8x8 glyph is placed in [4, 28) x [4, 28) with 3x3 scaling per source pixel
            var is_solid: [32][32]bool = [_][32]bool{[_]bool{false} ** 32} ** 32;
            for (0..8) |gy| {
                const b = bytes[gy];
                if (b == 0) continue;
                for (0..8) |gx_usize| {
                    const gx: u8 = @intCast(gx_usize);
                    if (((b >> @as(u3, @intCast(gx))) & 1) != 0) {
                        const px_start = 4 + gx * 3;
                        const py_start = 4 + gy * 3;
                        for (0..3) |dy| {
                            for (0..3) |dx| {
                                is_solid[py_start + dy][px_start + dx] = true;
                            }
                        }
                    }
                }
            }

            // 2. Compute exact Euclidean Signed Distance for each pixel in the 32x32 cell
            var py: usize = 0;
            while (py < 32) : (py += 1) {
                var px: usize = 0;
                while (px < 32) : (px += 1) {
                    const solid = is_solid[py][px];
                    var min_dist_sq: f32 = 1000.0;

                    const ipx: i32 = @intCast(px);
                    const ipy: i32 = @intCast(py);

                    var dy: i32 = -search_radius;
                    while (dy <= search_radius) : (dy += 1) {
                        const ny = ipy + dy;
                        if (ny < 0 or ny >= 32) continue;
                        var dx: i32 = -search_radius;
                        while (dx <= search_radius) : (dx += 1) {
                            const nx = ipx + dx;
                            if (nx < 0 or nx >= 32) continue;

                            const neighbor_solid = is_solid[@intCast(ny)][@intCast(nx)];
                            if (neighbor_solid != solid) {
                                const dist_sq = @as(f32, @floatFromInt(dx * dx + dy * dy));
                                if (dist_sq < min_dist_sq) {
                                    min_dist_sq = dist_sq;
                                }
                            }
                        }
                    }

                    const dist = @sqrt(min_dist_sq) - 0.5;
                    const signed_dist = if (solid) dist else -dist;

                    // Normalize distance: 0.5 is edge, > 0.5 inside, < 0.5 outside
                    const norm = std.math.clamp(0.5 + 0.5 * (signed_dist / spread), 0.0, 1.0);
                    const val: u8 = @intFromFloat(norm * 255.0);

                    const out_x = cell_x + px;
                    const out_y = cell_y + py;
                    const pixel_idx = (out_y * ATLAS_WIDTH + out_x) * 4;

                    out_pixels[pixel_idx + 0] = val;
                    out_pixels[pixel_idx + 1] = val;
                    out_pixels[pixel_idx + 2] = val;
                    out_pixels[pixel_idx + 3] = val;
                }
            }
        }
        _ = self;
    }
};

test "FontAtlas metric computation and ASCII character coverage" {
    const atlas = FontAtlas.init();

    // Verify ASCII printable range metrics
    const space_metrics = atlas.getMetrics(' ');
    try std.testing.expect(space_metrics.advance > 0.0);

    const a_metrics = atlas.getMetrics('A');
    try std.testing.expect(a_metrics.advance > space_metrics.advance);
    try std.testing.expect(a_metrics.u1 > a_metrics.u0);
    try std.testing.expect(a_metrics.v1 > a_metrics.v0);

    // Verify text measurement
    const dims = atlas.measureText("Hello World!", 16.0);
    try std.testing.expect(dims[0] > 50.0);
    try std.testing.expect(dims[1] >= 16.0);

    // Verify SDF generation does not crash and produces valid values
    const pixels = try std.testing.allocator.alloc(u8, FontAtlas.ATLAS_WIDTH * FontAtlas.ATLAS_HEIGHT * 4);
    defer std.testing.allocator.free(pixels);
    atlas.generateSdfRgba8(pixels);

    // Check that some pixels have high intensity (inside glyphs)
    var has_high = false;
    for (pixels) |p| {
        if (p > 200) {
            has_high = true;
            break;
        }
    }
    try std.testing.expect(has_high);
}


//! Network Protocol & Packet Framing Definitions
//! Provides binary packet framing, sequence numbers, Glenn Fiedler / ENet style
//! ACK bitfield reliability tracking, and bit-level serialization for vectors & quaternions.

const std = @import("std");

pub const PROTOCOL_MAGIC: u32 = 0x5A4E4554; // 'ZNET'
pub const PROTOCOL_VERSION: u8 = 1;
pub const MAX_PACKET_SIZE: usize = 1200;
pub const HEADER_SIZE: usize = 16;

pub const PacketType = enum(u8) {
    none = 0,
    connect_request = 1,
    connect_accept = 2,
    connect_reject = 3,
    disconnect = 4,
    heartbeat = 5,
    heartbeat_ack = 6,
    snapshot = 7,
    user_input = 8,
    remote_event = 9,
    _,
};

pub const Channel = enum(u8) {
    unreliable = 0,
    reliable = 1,
};

pub const PacketHeader = extern struct {
    magic: u32 = PROTOCOL_MAGIC,
    version: u8 = PROTOCOL_VERSION,
    packet_type: u8 = @intFromEnum(PacketType.none),
    channel: u8 = @intFromEnum(Channel.unreliable),
    flags: u8 = 0,
    sequence: u16 = 0,
    ack: u16 = 0,
    ack_bits: u32 = 0,

    pub fn init(pt: PacketType, ch: Channel, seq: u16, ack: u16, ack_bits: u32) PacketHeader {
        return .{
            .magic = PROTOCOL_MAGIC,
            .version = PROTOCOL_VERSION,
            .packet_type = @intFromEnum(pt),
            .channel = @intFromEnum(ch),
            .flags = 0,
            .sequence = seq,
            .ack = ack,
            .ack_bits = ack_bits,
        };
    }

    pub fn isValid(self: PacketHeader) bool {
        return self.magic == PROTOCOL_MAGIC and self.version == PROTOCOL_VERSION;
    }
};

comptime {
    std.debug.assert(@sizeOf(PacketHeader) == HEADER_SIZE);
}

// -------------------------------------------------------------------------------------------------
// Bit-level and Byte-level Serialization Utilities
// -------------------------------------------------------------------------------------------------

pub const SerializationError = error{
    BufferOverflow,
    BufferUnderflow,
    InvalidData,
};

pub const PacketWriter = struct {
    buffer: []u8,
    cursor: usize = 0,

    pub fn init(buffer: []u8) PacketWriter {
        return .{ .buffer = buffer, .cursor = 0 };
    }

    pub fn remaining(self: PacketWriter) usize {
        return self.buffer.len - self.cursor;
    }

    pub fn written(self: PacketWriter) []const u8 {
        return self.buffer[0..self.cursor];
    }

    pub fn writeHeader(self: *PacketWriter, header: PacketHeader) !void {
        if (self.remaining() < @sizeOf(PacketHeader)) return error.BufferOverflow;
        const bytes: *const [@sizeOf(PacketHeader)]u8 = @ptrCast(&header);
        @memcpy(self.buffer[self.cursor .. self.cursor + @sizeOf(PacketHeader)], bytes);
        self.cursor += @sizeOf(PacketHeader);
    }

    pub fn writeU8(self: *PacketWriter, val: u8) !void {
        if (self.remaining() < 1) return error.BufferOverflow;
        self.buffer[self.cursor] = val;
        self.cursor += 1;
    }

    pub fn writeU16(self: *PacketWriter, val: u16) !void {
        if (self.remaining() < 2) return error.BufferOverflow;
        std.mem.writeInt(u16, self.buffer[self.cursor..][0..2], val, .little);
        self.cursor += 2;
    }

    pub fn writeU32(self: *PacketWriter, val: u32) !void {
        if (self.remaining() < 4) return error.BufferOverflow;
        std.mem.writeInt(u32, self.buffer[self.cursor..][0..4], val, .little);
        self.cursor += 4;
    }

    pub fn writeU64(self: *PacketWriter, val: u64) !void {
        if (self.remaining() < 8) return error.BufferOverflow;
        std.mem.writeInt(u64, self.buffer[self.cursor..][0..8], val, .little);
        self.cursor += 8;
    }

    pub fn writeI32(self: *PacketWriter, val: i32) !void {
        return self.writeU32(@bitCast(val));
    }

    pub fn writeF32(self: *PacketWriter, val: f32) !void {
        return self.writeU32(@bitCast(val));
    }

    pub fn writeF64(self: *PacketWriter, val: f64) !void {
        return self.writeU64(@bitCast(val));
    }

    pub fn writeBytes(self: *PacketWriter, slice: []const u8) !void {
        if (self.remaining() < slice.len) return error.BufferOverflow;
        @memcpy(self.buffer[self.cursor .. self.cursor + slice.len], slice);
        self.cursor += slice.len;
    }

    pub fn writeString(self: *PacketWriter, str: []const u8) !void {
        if (str.len > 65535) return error.InvalidData;
        try self.writeU16(@intCast(str.len));
        try self.writeBytes(str);
    }

    /// Quantized Vector3: maps [min_val, max_val] into a 16-bit unsigned integer per axis
    pub fn writeQuantizedVec3(self: *PacketWriter, v: [3]f32, min_val: f32, max_val: f32) !void {
        const range = max_val - min_val;
        inline for (0..3) |i| {
            const clamped = std.math.clamp(v[i], min_val, max_val);
            const norm = (clamped - min_val) / range;
            const q: u16 = @intFromFloat(norm * 65535.0);
            try self.writeU16(q);
        }
    }

    /// Smallest-three quaternion compression: saves normalized quaternion in 7 bytes
    /// (2 bits index of largest component + 3x 16-bit signed quantized components)
    pub fn writeQuantizedQuat(self: *PacketWriter, q: [4]f32) !void {
        // Find index of component with largest absolute value
        var max_idx: u8 = 0;
        var max_val = @abs(q[0]);
        inline for (1..4) |i| {
            const val = @abs(q[i]);
            if (val > max_val) {
                max_val = val;
                max_idx = @intCast(i);
            }
        }

        // Ensure largest component is positive
        const sign: f32 = if (q[max_idx] < 0.0) -1.0 else 1.0;
        try self.writeU8(max_idx);

        // Quantize the other three components into [-1.0, 1.0] -> [-32767, 32767]
        var comp_i: usize = 0;
        for (0..4) |i| {
            if (i == max_idx) continue;
            const c = q[i] * sign;
            const norm = std.math.clamp(c * 1.41421356, -1.0, 1.0); // * sqrt(2) since max is <= 1/sqrt(2)
            const quantized: i16 = @intFromFloat(norm * 32767.0);
            try self.writeU16(@bitCast(quantized));
            comp_i += 1;
        }
    }
};

pub const PacketReader = struct {
    buffer: []const u8,
    cursor: usize = 0,

    pub fn init(buffer: []const u8) PacketReader {
        return .{ .buffer = buffer, .cursor = 0 };
    }

    pub fn remaining(self: PacketReader) usize {
        return self.buffer.len - self.cursor;
    }

    pub fn readHeader(self: *PacketReader) !PacketHeader {
        if (self.remaining() < @sizeOf(PacketHeader)) return error.BufferUnderflow;
        var header: PacketHeader = undefined;
        const dest_bytes: *[@sizeOf(PacketHeader)]u8 = @ptrCast(&header);
        @memcpy(dest_bytes, self.buffer[self.cursor .. self.cursor + @sizeOf(PacketHeader)]);
        self.cursor += @sizeOf(PacketHeader);
        if (!header.isValid()) return error.InvalidData;
        return header;
    }

    pub fn readU8(self: *PacketReader) !u8 {
        if (self.remaining() < 1) return error.BufferUnderflow;
        const val = self.buffer[self.cursor];
        self.cursor += 1;
        return val;
    }

    pub fn readU16(self: *PacketReader) !u16 {
        if (self.remaining() < 2) return error.BufferUnderflow;
        const val = std.mem.readInt(u16, self.buffer[self.cursor..][0..2], .little);
        self.cursor += 2;
        return val;
    }

    pub fn readU32(self: *PacketReader) !u32 {
        if (self.remaining() < 4) return error.BufferUnderflow;
        const val = std.mem.readInt(u32, self.buffer[self.cursor..][0..4], .little);
        self.cursor += 4;
        return val;
    }

    pub fn readU64(self: *PacketReader) !u64 {
        if (self.remaining() < 8) return error.BufferUnderflow;
        const val = std.mem.readInt(u64, self.buffer[self.cursor..][0..8], .little);
        self.cursor += 8;
        return val;
    }

    pub fn readI32(self: *PacketReader) !i32 {
        return @bitCast(try self.readU32());
    }

    pub fn readF32(self: *PacketReader) !f32 {
        return @bitCast(try self.readU32());
    }

    pub fn readF64(self: *PacketReader) !f64 {
        return @bitCast(try self.readU64());
    }

    pub fn readBytes(self: *PacketReader, dest: []u8) !void {
        if (self.remaining() < dest.len) return error.BufferUnderflow;
        @memcpy(dest, self.buffer[self.cursor .. self.cursor + dest.len]);
        self.cursor += dest.len;
    }

    pub fn readString(self: *PacketReader, dest: []u8) ![]const u8 {
        const len = try self.readU16();
        if (dest.len < len) return error.BufferOverflow;
        const slice = dest[0..len];
        try self.readBytes(slice);
        return slice;
    }

    pub fn readQuantizedVec3(self: *PacketReader, min_val: f32, max_val: f32) ![3]f32 {
        const range = max_val - min_val;
        var res: [3]f32 = undefined;
        inline for (0..3) |i| {
            const q = try self.readU16();
            const norm = @as(f32, @floatFromInt(q)) / 65535.0;
            res[i] = min_val + norm * range;
        }
        return res;
    }

    pub fn readQuantizedQuat(self: *PacketReader) ![4]f32 {
        const max_idx = try self.readU8();
        if (max_idx > 3) return error.InvalidData;

        var q: [4]f32 = undefined;
        var sum_sq: f32 = 0.0;
        for (0..4) |i| {
            if (i == max_idx) continue;
            const raw_q: i16 = @bitCast(try self.readU16());
            const norm = @as(f32, @floatFromInt(raw_q)) / 32767.0;
            const c = norm / 1.41421356;
            q[i] = c;
            sum_sq += c * c;
        }
        const remaining_sq = @max(0.0, 1.0 - sum_sq);
        q[max_idx] = @sqrt(remaining_sq);
        return q;
    }
};

// -------------------------------------------------------------------------------------------------
// Reliability Sequence Helper (Handling 16-bit wrap-around)
// -------------------------------------------------------------------------------------------------

pub fn isSeqNewer(s1: u16, s2: u16) bool {
    return ((s1 > s2) and (s1 - s2 <= 32768)) or ((s1 < s2) and (s2 - s1 > 32768));
}

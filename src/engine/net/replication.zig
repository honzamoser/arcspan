//! Entity Snapshot Replication, Interpolation & RemoteEvents
//! Provides authoritative state snapshot generation, delta compression,
//! client-side buffer interpolation (Hermite / Lerp / NLerp), and RemoteEvent RPCs.

const std = @import("std");
const protocol = @import("protocol.zig");
const PacketWriter = protocol.PacketWriter;
const PacketReader = protocol.PacketReader;

pub const MAX_REPLICATED_ENTITIES = 64;
pub const MAX_SNAPSHOT_HISTORY = 32;
pub const MAX_EVENT_NAME_LEN = 32;
pub const MAX_EVENT_PAYLOAD_LEN = 256;
pub const MAX_QUEUED_EVENTS = 64;

// -------------------------------------------------------------------------------------------------
// Entity and World Snapshot Structures
// -------------------------------------------------------------------------------------------------

pub const EntitySnapshot = extern struct {
    id: u64 = 0,
    position: [3]f32 = .{ 0.0, 0.0, 0.0 },
    rotation: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 }, // Quaternion (x, y, z, w)
    velocity: [3]f32 = .{ 0.0, 0.0, 0.0 },
    component_mask: u32 = 0,

    pub fn lerp(a: EntitySnapshot, b: EntitySnapshot, t: f32) EntitySnapshot {
        var res = a;
        res.id = b.id;
        res.component_mask = b.component_mask;

        inline for (0..3) |i| {
            res.position[i] = a.position[i] + (b.position[i] - a.position[i]) * t;
            res.velocity[i] = a.velocity[i] + (b.velocity[i] - a.velocity[i]) * t;
        }

        // Quaternion Normalized Lerp (NLerp)
        var dot: f32 = 0.0;
        inline for (0..4) |i| dot += a.rotation[i] * b.rotation[i];

        // Ensure shortest path
        const sign: f32 = if (dot < 0.0) -1.0 else 1.0;
        var len_sq: f32 = 0.0;
        inline for (0..4) |i| {
            const rot_b = b.rotation[i] * sign;
            res.rotation[i] = a.rotation[i] + (rot_b - a.rotation[i]) * t;
            len_sq += res.rotation[i] * res.rotation[i];
        }

        if (len_sq > 0.0) {
            const inv_len = 1.0 / @sqrt(len_sq);
            inline for (0..4) |i| res.rotation[i] *= inv_len;
        }

        return res;
    }
};

pub const WorldSnapshot = struct {
    tick: u32 = 0,
    timestamp: f64 = 0.0,
    entity_count: u32 = 0,
    entities: [MAX_REPLICATED_ENTITIES]EntitySnapshot = [_]EntitySnapshot{.{}} ** MAX_REPLICATED_ENTITIES,

    pub fn serialize(self: WorldSnapshot, writer: *PacketWriter) !void {
        try writer.writeU32(self.tick);
        try writer.writeF64(self.timestamp);
        try writer.writeU32(self.entity_count);

        for (0..self.entity_count) |i| {
            const e = self.entities[i];
            try writer.writeU64(e.id);
            inline for (0..3) |c| try writer.writeF32(e.position[c]);
            inline for (0..4) |c| try writer.writeF32(e.rotation[c]);
            inline for (0..3) |c| try writer.writeF32(e.velocity[c]);
            try writer.writeU32(e.component_mask);
        }
    }

    pub fn deserialize(reader: *PacketReader) !WorldSnapshot {
        var snap = WorldSnapshot{};
        snap.tick = try reader.readU32();
        snap.timestamp = try reader.readF64();
        snap.entity_count = @min(try reader.readU32(), MAX_REPLICATED_ENTITIES);

        for (0..snap.entity_count) |i| {
            var e = EntitySnapshot{};
            e.id = try reader.readU64();
            inline for (0..3) |c| e.position[c] = try reader.readF32();
            inline for (0..4) |c| e.rotation[c] = try reader.readF32();
            inline for (0..3) |c| e.velocity[c] = try reader.readF32();
            e.component_mask = try reader.readU32();
            snap.entities[i] = e;
        }

        return snap;
    }
};

// -------------------------------------------------------------------------------------------------
// Client-Side Snapshot Buffer & Interpolation
// -------------------------------------------------------------------------------------------------

pub const SnapshotInterpolator = struct {
    history: [MAX_SNAPSHOT_HISTORY]WorldSnapshot = [_]WorldSnapshot{.{}} ** MAX_SNAPSHOT_HISTORY,
    count: usize = 0,
    head: usize = 0,
    interpolation_delay_sec: f64 = 0.100, // 100ms standard buffer delay
    max_extrapolation_sec: f64 = 0.250,

    pub fn init(delay_sec: f64) SnapshotInterpolator {
        return .{
            .interpolation_delay_sec = delay_sec,
        };
    }

    pub fn pushSnapshot(self: *SnapshotInterpolator, snap: WorldSnapshot) void {
        self.history[self.head] = snap;
        self.head = (self.head + 1) % MAX_SNAPSHOT_HISTORY;
        if (self.count < MAX_SNAPSHOT_HISTORY) {
            self.count += 1;
        }
    }

    pub fn getNewestSnapshot(self: *const SnapshotInterpolator) ?*const WorldSnapshot {
        if (self.count == 0) return null;
        const newest_idx = (self.head + MAX_SNAPSHOT_HISTORY - 1) % MAX_SNAPSHOT_HISTORY;
        return &self.history[newest_idx];
    }

    /// Sample interpolated world state at `current_time_sec`.
    /// Populates `out_entities` and returns the number of active interpolated entities.
    pub fn sample(
        self: *const SnapshotInterpolator,
        current_time_sec: f64,
        out_entities: *[MAX_REPLICATED_ENTITIES]EntitySnapshot,
    ) u32 {
        if (self.count == 0) return 0;
        if (self.count == 1) {
            const snap = &self.history[(self.head + MAX_SNAPSHOT_HISTORY - 1) % MAX_SNAPSHOT_HISTORY];
            @memcpy(out_entities[0..snap.entity_count], snap.entities[0..snap.entity_count]);
            return snap.entity_count;
        }

        const render_time = current_time_sec - self.interpolation_delay_sec;

        // Find surrounding snapshots s0 (<= render_time) and s1 (>= render_time)
        var s0: ?*const WorldSnapshot = null;
        var s1: ?*const WorldSnapshot = null;

        // Iterate backwards from newest to oldest
        for (0..self.count) |step| {
            const idx = (self.head + MAX_SNAPSHOT_HISTORY - 1 - step) % MAX_SNAPSHOT_HISTORY;
            const snap = &self.history[idx];

            if (snap.timestamp <= render_time) {
                s0 = snap;
                break;
            } else {
                s1 = snap;
            }
        }

        if (s0 != null and s1 != null) {
            // Normal interpolation between s0 and s1
            const span = s1.?.timestamp - s0.?.timestamp;
            const alpha: f32 = if (span > 0.0)
                @floatCast(std.math.clamp((render_time - s0.?.timestamp) / span, 0.0, 1.0))
            else
                0.0;

            var out_count: u32 = 0;
            for (0..s1.?.entity_count) |i| {
                const e1 = s1.?.entities[i];
                var found_e0: ?EntitySnapshot = null;
                for (0..s0.?.entity_count) |j| {
                    if (s0.?.entities[j].id == e1.id) {
                        found_e0 = s0.?.entities[j];
                        break;
                    }
                }

                if (found_e0) |e0| {
                    out_entities[out_count] = e0.lerp(e1, alpha);
                } else {
                    out_entities[out_count] = e1;
                }
                out_count += 1;
            }
            return out_count;
        } else if (s0 != null and s1 == null) {
            // Extrapolation beyond newest snapshot
            const newest = s0.?;
            const delta_t: f32 = @floatCast(@min(render_time - newest.timestamp, self.max_extrapolation_sec));

            for (0..newest.entity_count) |i| {
                var e = newest.entities[i];
                inline for (0..3) |c| {
                    e.position[c] += e.velocity[c] * delta_t;
                }
                out_entities[i] = e;
            }
            return newest.entity_count;
        } else {
            // Render time is older than oldest snapshot in buffer: clamp to oldest
            const oldest_idx = (self.head + MAX_SNAPSHOT_HISTORY - self.count) % MAX_SNAPSHOT_HISTORY;
            const oldest = &self.history[oldest_idx];
            @memcpy(out_entities[0..oldest.entity_count], oldest.entities[0..oldest.entity_count]);
            return oldest.entity_count;
        }
    }
};

// -------------------------------------------------------------------------------------------------
// RemoteEvents & RPC Messaging System
// -------------------------------------------------------------------------------------------------

pub const RemoteEventMessage = struct {
    name: [MAX_EVENT_NAME_LEN]u8 = [_]u8{0} ** MAX_EVENT_NAME_LEN,
    name_len: u8 = 0,
    sender_id: u32 = 0,
    payload: [MAX_EVENT_PAYLOAD_LEN]u8 = [_]u8{0} ** MAX_EVENT_PAYLOAD_LEN,
    payload_len: u16 = 0,

    pub fn init(sender_id: u32, name: []const u8, data: []const u8) RemoteEventMessage {
        var msg = RemoteEventMessage{
            .sender_id = sender_id,
            .name_len = @intCast(@min(name.len, MAX_EVENT_NAME_LEN)),
            .payload_len = @intCast(@min(data.len, MAX_EVENT_PAYLOAD_LEN)),
        };
        @memcpy(msg.name[0..msg.name_len], name[0..msg.name_len]);
        @memcpy(msg.payload[0..msg.payload_len], data[0..msg.payload_len]);
        return msg;
    }

    pub fn getName(self: *const RemoteEventMessage) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getPayload(self: *const RemoteEventMessage) []const u8 {
        return self.payload[0..self.payload_len];
    }

    pub fn serialize(self: RemoteEventMessage, writer: *PacketWriter) !void {
        try writer.writeU32(self.sender_id);
        try writer.writeU8(self.name_len);
        try writer.writeBytes(self.getName());
        try writer.writeU16(self.payload_len);
        try writer.writeBytes(self.getPayload());
    }

    pub fn deserialize(reader: *PacketReader) !RemoteEventMessage {
        var msg = RemoteEventMessage{};
        msg.sender_id = try reader.readU32();
        msg.name_len = try reader.readU8();
        if (msg.name_len > MAX_EVENT_NAME_LEN) return error.InvalidData;
        try reader.readBytes(msg.name[0..msg.name_len]);

        msg.payload_len = try reader.readU16();
        if (msg.payload_len > MAX_EVENT_PAYLOAD_LEN) return error.InvalidData;
        try reader.readBytes(msg.payload[0..msg.payload_len]);

        return msg;
    }
};

pub const RemoteEventManager = struct {
    incoming_queue: [MAX_QUEUED_EVENTS]RemoteEventMessage = [_]RemoteEventMessage{.{}} ** MAX_QUEUED_EVENTS,
    incoming_head: usize = 0,
    incoming_tail: usize = 0,
    incoming_count: usize = 0,

    outgoing_queue: [MAX_QUEUED_EVENTS]RemoteEventMessage = [_]RemoteEventMessage{.{}} ** MAX_QUEUED_EVENTS,
    outgoing_head: usize = 0,
    outgoing_tail: usize = 0,
    outgoing_count: usize = 0,

    pub fn pushIncoming(self: *RemoteEventManager, msg: RemoteEventMessage) bool {
        if (self.incoming_count >= MAX_QUEUED_EVENTS) return false;
        self.incoming_queue[self.incoming_head] = msg;
        self.incoming_head = (self.incoming_head + 1) % MAX_QUEUED_EVENTS;
        self.incoming_count += 1;
        return true;
    }

    pub fn popIncoming(self: *RemoteEventManager) ?RemoteEventMessage {
        if (self.incoming_count == 0) return null;
        const msg = self.incoming_queue[self.incoming_tail];
        self.incoming_tail = (self.incoming_tail + 1) % MAX_QUEUED_EVENTS;
        self.incoming_count -= 1;
        return msg;
    }

    pub fn pushOutgoing(self: *RemoteEventManager, msg: RemoteEventMessage) bool {
        if (self.outgoing_count >= MAX_QUEUED_EVENTS) return false;
        self.outgoing_queue[self.outgoing_head] = msg;
        self.outgoing_head = (self.outgoing_head + 1) % MAX_QUEUED_EVENTS;
        self.outgoing_count += 1;
        return true;
    }

    pub fn popOutgoing(self: *RemoteEventManager) ?RemoteEventMessage {
        if (self.outgoing_count == 0) return null;
        const msg = self.outgoing_queue[self.outgoing_tail];
        self.outgoing_tail = (self.outgoing_tail + 1) % MAX_QUEUED_EVENTS;
        self.outgoing_count -= 1;
        return msg;
    }
};

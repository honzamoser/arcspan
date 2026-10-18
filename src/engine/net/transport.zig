//! UDP Transport Layer & Connection Management
//! Implements cross-platform non-blocking UDP sockets, peer state machines,
//! packet sequencing, sliding window ACKs, and RTT ping estimation.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const PacketType = protocol.PacketType;
const Channel = protocol.Channel;
const PacketHeader = protocol.PacketHeader;
const PacketWriter = protocol.PacketWriter;
const PacketReader = protocol.PacketReader;
const MAX_PACKET_SIZE = protocol.MAX_PACKET_SIZE;
const HEADER_SIZE = protocol.HEADER_SIZE;
const isSeqNewer = protocol.isSeqNewer;

// -------------------------------------------------------------------------------------------------
// Cross-Platform OS Socket Abstraction
// -------------------------------------------------------------------------------------------------

pub const NetAddress = struct {
    ip: [4]u8 = .{ 127, 0, 0, 1 },
    port: u16 = 0,

    pub fn init(b0: u8, b1: u8, b2: u8, b3: u8, port: u16) NetAddress {
        return .{ .ip = .{ b0, b1, b2, b3 }, .port = port };
    }

    pub fn loopback(port: u16) NetAddress {
        return init(127, 0, 0, 1, port);
    }

    pub fn any(port: u16) NetAddress {
        return init(0, 0, 0, 0, port);
    }

    pub fn parse(str: []const u8) !NetAddress {
        var colon_idx: ?usize = null;
        for (str, 0..) |char, i| {
            if (char == ':') {
                colon_idx = i;
                break;
            }
        }
        if (colon_idx == null) return error.InvalidAddress;

        const ip_part = str[0..colon_idx.?];
        const port_part = str[colon_idx.? + 1 ..];

        const port = try std.fmt.parseInt(u16, port_part, 10);

        var ip: [4]u8 = undefined;
        var it = std.mem.splitScalar(u8, ip_part, '.');
        var count: usize = 0;
        while (it.next()) |seg| {
            if (count >= 4) return error.InvalidAddress;
            ip[count] = try std.fmt.parseInt(u8, seg, 10);
            count += 1;
        }
        if (count != 4) return error.InvalidAddress;

        return NetAddress{ .ip = ip, .port = port };
    }

    pub fn eql(self: NetAddress, other: NetAddress) bool {
        return std.mem.eql(u8, &self.ip, &other.ip) and self.port == other.port;
    }
};

const SOCKET = usize;
const INVALID_SOCKET: SOCKET = ~@as(SOCKET, 0);

// Windows Winsock2 API bindings
const WSADATA = extern struct {
    wVersion: u16,
    wHighVersion: u16,
    szDescription: [257]u8,
    szSystemStatus: [129]u8,
    iMaxSockets: u16,
    iMaxUdpDg: u16,
    lpVendorInfo: ?*anyopaque,
};

const sockaddr_in = extern struct {
    sin_family: u16 = 2, // AF_INET
    sin_port: u16 = 0,
    sin_addr: u32 = 0,
    sin_zero: [8]u8 = [_]u8{0} ** 8,
};

extern "ws2_32" fn WSAStartup(wVersionRequired: u16, lpWSAData: *WSADATA) callconv(.c) c_int;
extern "ws2_32" fn WSACleanup() callconv(.c) c_int;
extern "ws2_32" fn WSAGetLastError() callconv(.c) c_int;
extern "ws2_32" fn socket(af: c_int, type: c_int, protocol: c_int) callconv(.c) SOCKET;
extern "ws2_32" fn bind(s: SOCKET, name: *const sockaddr_in, namelen: c_int) callconv(.c) c_int;
extern "ws2_32" fn sendto(s: SOCKET, buf: [*]const u8, len: c_int, flags: c_int, to: *const sockaddr_in, tolen: c_int) callconv(.c) c_int;
extern "ws2_32" fn recvfrom(s: SOCKET, buf: [*]u8, len: c_int, flags: c_int, from: *sockaddr_in, fromlen: *c_int) callconv(.c) c_int;
extern "ws2_32" fn closesocket(s: SOCKET) callconv(.c) c_int;
extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: c_long, argp: *c_ulong) callconv(.c) c_int;
extern "ws2_32" fn getsockname(s: SOCKET, name: *sockaddr_in, namelen: *c_int) callconv(.c) c_int;
extern "ws2_32" fn htons(hostshort: u16) callconv(.c) u16;
extern "ws2_32" fn ntohs(netshort: u16) callconv(.c) u16;

var wsa_initialized: bool = false;

pub fn ensureSocketSubsystem() !void {
    if (comptime builtin.os.tag == .windows) {
        if (!wsa_initialized) {
            var wsa: WSADATA = undefined;
            if (WSAStartup(0x0202, &wsa) != 0) return error.SocketInitFailed;
            wsa_initialized = true;
        }
    }
}

pub const UdpSocket = struct {
    handle: SOCKET = INVALID_SOCKET,
    bound_port: u16 = 0,

    pub fn init() !UdpSocket {
        try ensureSocketSubsystem();

        const sock = if (comptime builtin.os.tag == .windows)
            socket(2, 2, 17) // AF_INET, SOCK_DGRAM, IPPROTO_UDP
        else
            @as(SOCKET, @intCast(try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0)));

        if (sock == INVALID_SOCKET) return error.SocketCreationFailed;

        var self = UdpSocket{ .handle = sock };
        try self.setNonBlocking(true);
        return self;
    }

    pub fn close(self: *UdpSocket) void {
        if (self.handle != INVALID_SOCKET) {
            if (comptime builtin.os.tag == .windows) {
                _ = closesocket(self.handle);
            } else {
                std.posix.close(@intCast(self.handle));
            }
            self.handle = INVALID_SOCKET;
        }
    }

    pub fn setNonBlocking(self: *UdpSocket, enabled: bool) !void {
        if (comptime builtin.os.tag == .windows) {
            var mode: c_ulong = if (enabled) 1 else 0;
            const FIONBIO: c_long = @bitCast(@as(u32, 0x8004667e));
            if (ioctlsocket(self.handle, FIONBIO, &mode) != 0) return error.SocketOptionFailed;
        } else {
            const fd: std.posix.fd_t = @intCast(self.handle);
            var flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
            if (enabled) {
                flags |= std.posix.SOCK.NONBLOCK;
            } else {
                flags &= ~@as(usize, std.posix.SOCK.NONBLOCK);
            }
            _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags);
        }
    }

    pub fn bindTo(self: *UdpSocket, addr: NetAddress) !void {
        if (comptime builtin.os.tag == .windows) {
            const raw_ip: u32 = (@as(u32, addr.ip[3]) << 24) |
                (@as(u32, addr.ip[2]) << 16) |
                (@as(u32, addr.ip[1]) << 8) |
                @as(u32, addr.ip[0]);

            var sock_addr = sockaddr_in{
                .sin_family = 2,
                .sin_port = htons(addr.port),
                .sin_addr = raw_ip,
            };

            if (bind(self.handle, &sock_addr, @sizeOf(sockaddr_in)) != 0) {
                return error.BindFailed;
            }

            var local_addr: sockaddr_in = undefined;
            var len: c_int = @sizeOf(sockaddr_in);
            if (getsockname(self.handle, &local_addr, &len) == 0) {
                self.bound_port = ntohs(local_addr.sin_port);
            }
        } else {
            const posix_addr = std.net.Address.initIp4(addr.ip, addr.port);
            try std.posix.bind(@intCast(self.handle), &posix_addr.any, posix_addr.getOsSockLen());
            self.bound_port = addr.port;
        }
    }

    pub fn sendTo(self: *UdpSocket, dest: NetAddress, data: []const u8) !usize {
        if (comptime builtin.os.tag == .windows) {
            const raw_ip: u32 = (@as(u32, dest.ip[3]) << 24) |
                (@as(u32, dest.ip[2]) << 16) |
                (@as(u32, dest.ip[1]) << 8) |
                @as(u32, dest.ip[0]);

            const sock_addr = sockaddr_in{
                .sin_family = 2,
                .sin_port = htons(dest.port),
                .sin_addr = raw_ip,
            };

            const bytes_sent = sendto(
                self.handle,
                data.ptr,
                @intCast(data.len),
                0,
                &sock_addr,
                @sizeOf(sockaddr_in),
            );

            if (bytes_sent < 0) {
                const err = WSAGetLastError();
                if (err == 10035) return 0; // WSAEWOULDBLOCK
                return error.SendFailed;
            }
            return @intCast(bytes_sent);
        } else {
            const posix_addr = std.net.Address.initIp4(dest.ip, dest.port);
            return std.posix.sendto(@intCast(self.handle), data, 0, &posix_addr.any, posix_addr.getOsSockLen());
        }
    }

    pub fn recvFrom(self: *UdpSocket, buffer: []u8) !?struct { len: usize, sender: NetAddress } {
        if (comptime builtin.os.tag == .windows) {
            var sock_addr: sockaddr_in = undefined;
            var from_len: c_int = @sizeOf(sockaddr_in);

            const bytes_read = recvfrom(
                self.handle,
                buffer.ptr,
                @intCast(buffer.len),
                0,
                &sock_addr,
                &from_len,
            );

            if (bytes_read < 0) {
                const err = WSAGetLastError();
                if (err == 10035) return null; // WSAEWOULDBLOCK (no datagram ready)
                if (err == 10054) return null; // WSAECONNRESET (previous ICMP unreachable)
                return error.RecvFailed;
            }

            const sender_ip: [4]u8 = @bitCast(sock_addr.sin_addr);
            const sender_port = ntohs(sock_addr.sin_port);

            return .{
                .len = @intCast(bytes_read),
                .sender = NetAddress{ .ip = sender_ip, .port = sender_port },
            };
        } else {
            var src_addr: std.posix.sockaddr.storage = undefined;
            var src_len: std.posix.socklen_t = @sizeOf(@TypeOf(src_addr));
            const bytes_read = std.posix.recvfrom(
                @intCast(self.handle),
                buffer,
                0,
                @ptrCast(&src_addr),
                &src_len,
            ) catch |err| switch (err) {
                error.WouldBlock => return null,
                else => return err,
            };

            const resolved = std.net.Address.initPosix(@ptrCast(&src_addr));
            const ip4 = resolved.in.sa.addr;
            const sender_ip: [4]u8 = @bitCast(ip4);

            return .{
                .len = bytes_read,
                .sender = NetAddress{ .ip = sender_ip, .port = resolved.getPort() },
            };
        }
    }
};

// -------------------------------------------------------------------------------------------------
// Connection State Machine & Reliability Tracking
// -------------------------------------------------------------------------------------------------

pub const ConnectionState = enum {
    disconnected,
    connecting,
    connected,
    disconnecting,
};

pub const MAX_PENDING_RELIABLE = 32;

pub const PendingReliablePacket = struct {
    sequence: u16 = 0,
    sent_time_ms: f64 = 0.0,
    len: u16 = 0,
    data: [MAX_PACKET_SIZE]u8 = undefined,
    acked: bool = false,
};

pub const Peer = struct {
    id: u32 = 0,
    address: NetAddress = .{},
    state: ConnectionState = .disconnected,

    local_seq: u16 = 0,
    remote_seq: u16 = 0,
    ack_bits: u32 = 0,

    rtt_ms: f32 = 0.0,
    last_send_time_ms: f64 = 0.0,
    last_recv_time_ms: f64 = 0.0,
    last_heartbeat_time_ms: f64 = 0.0,

    pending_reliable: [MAX_PENDING_RELIABLE]PendingReliablePacket = [_]PendingReliablePacket{.{}} ** MAX_PENDING_RELIABLE,

    pub fn init(id: u32, address: NetAddress, now_ms: f64) Peer {
        return .{
            .id = id,
            .address = address,
            .state = .connecting,
            .local_seq = 0,
            .remote_seq = 0,
            .ack_bits = 0,
            .rtt_ms = 0.0,
            .last_send_time_ms = now_ms,
            .last_recv_time_ms = now_ms,
            .last_heartbeat_time_ms = now_ms,
        };
    }

    /// Update received sequence and sliding ACK bitfield
    pub fn onPacketReceived(self: *Peer, incoming_seq: u16, now_ms: f64) void {
        self.last_recv_time_ms = now_ms;
        if (isSeqNewer(incoming_seq, self.remote_seq)) {
            const shift = incoming_seq -% self.remote_seq;
            if (shift <= 32) {
                self.ack_bits = (self.ack_bits << @intCast(shift)) | (@as(u32, 1) << @intCast(shift - 1));
            } else {
                self.ack_bits = 0;
            }
            self.remote_seq = incoming_seq;
        } else {
            const diff = self.remote_seq -% incoming_seq;
            if (diff > 0 and diff <= 32) {
                self.ack_bits |= (@as(u32, 1) << @intCast(diff - 1));
            }
        }
    }

    /// Process received ACK and ACK bitfield from peer to mark pending reliable packets
    pub fn onAckReceived(self: *Peer, ack: u16, ack_bits: u32, now_ms: f64) void {
        for (&self.pending_reliable) |*p| {
            if (p.len == 0 or p.acked) continue;
            if (p.sequence == ack) {
                p.acked = true;
                const sample_rtt = @as(f32, @floatCast(now_ms - p.sent_time_ms));
                self.updateRtt(sample_rtt);
            } else if (!isSeqNewer(p.sequence, ack)) {
                const diff = ack -% p.sequence;
                if (diff > 0 and diff <= 32) {
                    if ((ack_bits & (@as(u32, 1) << @intCast(diff - 1))) != 0) {
                        p.acked = true;
                        const sample_rtt = @as(f32, @floatCast(now_ms - p.sent_time_ms));
                        self.updateRtt(sample_rtt);
                    }
                }
            }
        }
    }

    fn updateRtt(self: *Peer, sample_ms: f32) void {
        if (sample_ms <= 0.0 or sample_ms > 2000.0) return;
        if (self.rtt_ms == 0.0) {
            self.rtt_ms = sample_ms;
        } else {
            // Exponential moving average: 90% previous + 10% sample
            self.rtt_ms = self.rtt_ms * 0.9 + sample_ms * 0.1;
        }
    }

    pub fn nextSequence(self: *Peer) u16 {
        self.local_seq +%= 1;
        return self.local_seq;
    }
};

// -------------------------------------------------------------------------------------------------
// High-Level Network Server & Client
// -------------------------------------------------------------------------------------------------

pub const MAX_CLIENTS = 32;
pub const CLIENT_TIMEOUT_MS = 5000.0;
pub const HEARTBEAT_INTERVAL_MS = 250.0;

pub const ReceivedMessage = struct {
    sender_id: u32,
    packet_type: PacketType,
    payload: []const u8,
};

pub const NetServer = struct {
    socket: UdpSocket,
    clients: [MAX_CLIENTS]?Peer = [_]?Peer{null} ** MAX_CLIENTS,
    active_client_count: u32 = 0,
    recv_buffer: [MAX_PACKET_SIZE]u8 = undefined,

    pub fn init(port: u16) !NetServer {
        var sock = try UdpSocket.init();
        errdefer sock.close();

        try sock.bindTo(NetAddress.any(port));
        return NetServer{
            .socket = sock,
            .clients = [_]?Peer{null} ** MAX_CLIENTS,
            .active_client_count = 0,
        };
    }

    pub fn deinit(self: *NetServer) void {
        self.socket.close();
    }

    pub fn getPort(self: NetServer) u16 {
        return self.socket.bound_port;
    }

    /// Process incoming datagrams and maintain connection heartbeats/timeouts.
    /// Calls `message_handler` for application messages (`snapshot`, `user_input`, `remote_event`).
    pub fn update(
        self: *NetServer,
        now_ms: f64,
        context: anytype,
        comptime on_message: fn (ctx: @TypeOf(context), msg: ReceivedMessage) void,
    ) !void {
        // 1. Read all pending UDP datagrams
        while (try self.socket.recvFrom(&self.recv_buffer)) |packet| {
            if (packet.len < protocol.HEADER_SIZE) continue;

            var reader = PacketReader.init(self.recv_buffer[0..packet.len]);
            const header = reader.readHeader() catch continue;

            const p_type: PacketType = @enumFromInt(header.packet_type);
            const client_idx = self.findClientIndex(packet.sender);

            if (p_type == .connect_request) {
                // Client initiating handshake
                if (client_idx) |c_idx| {
                    // Resend accept if already allocated
                    try self.sendRawPacket(
                        packet.sender,
                        .connect_accept,
                        .reliable,
                        0,
                        header.sequence,
                        0,
                        &[_]u8{@intCast(c_idx)},
                    );
                } else {
                    if (self.allocateClient(packet.sender, now_ms)) |assigned_id| {
                        try self.sendRawPacket(
                            packet.sender,
                            .connect_accept,
                            .reliable,
                            0,
                            header.sequence,
                            0,
                            &[_]u8{@intCast(assigned_id)},
                        );
                    } else {
                        try self.sendRawPacket(
                            packet.sender,
                            .connect_reject,
                            .unreliable,
                            0,
                            header.sequence,
                            0,
                            &[_]u8{},
                        );
                    }
                }
                continue;
            }

            if (client_idx) |idx| {
                var peer = &self.clients[idx].?;
                peer.onPacketReceived(header.sequence, now_ms);
                peer.onAckReceived(header.ack, header.ack_bits, now_ms);

                switch (p_type) {
                    .disconnect => {
                        self.clients[idx] = null;
                        self.active_client_count -%= 1;
                    },
                    .heartbeat => {
                        // Echo ping back with client's sequence for RTT calculation
                        try self.sendRawPacket(
                            peer.address,
                            .heartbeat_ack,
                            .unreliable,
                            peer.nextSequence(),
                            peer.remote_seq,
                            peer.ack_bits,
                            reader.buffer[reader.cursor..],
                        );
                    },
                    .heartbeat_ack => {
                        // Already accounted in onAckReceived
                    },
                    else => {
                        on_message(context, .{
                            .sender_id = @intCast(idx),
                            .packet_type = p_type,
                            .payload = reader.buffer[reader.cursor..],
                        });
                    },
                }
            }
        }

        // 2. Periodic heartbeats, reliable retransmission, and timeout check
        for (&self.clients, 0..) |*slot, idx| {
            if (slot.*) |*peer| {
                // Timeout check
                if (now_ms - peer.last_recv_time_ms > CLIENT_TIMEOUT_MS) {
                    slot.* = null;
                    self.active_client_count -%= 1;
                    continue;
                }

                // Heartbeat
                if (now_ms - peer.last_heartbeat_time_ms > HEARTBEAT_INTERVAL_MS) {
                    peer.last_heartbeat_time_ms = now_ms;
                    var time_buf: [8]u8 = undefined;
                    std.mem.writeInt(u64, &time_buf, @bitCast(now_ms), .little);
                    try self.sendRawPacket(
                        peer.address,
                        .heartbeat,
                        .unreliable,
                        peer.nextSequence(),
                        peer.remote_seq,
                        peer.ack_bits,
                        &time_buf,
                    );
                }

                // Retransmit unacked reliable packets if RTT exceeded
                const resend_threshold = @max(50.0, peer.rtt_ms * 1.5);
                for (&peer.pending_reliable) |*p| {
                    if (p.len > 0 and !p.acked) {
                        if (now_ms - p.sent_time_ms > resend_threshold) {
                            p.sent_time_ms = now_ms;
                            _ = try self.socket.sendTo(peer.address, p.data[0..p.len]);
                        }
                    }
                }
            } else {
                _ = idx;
            }
        }
    }

    pub fn sendToClient(
        self: *NetServer,
        client_id: u32,
        packet_type: PacketType,
        channel: Channel,
        payload: []const u8,
    ) !void {
        if (client_id >= MAX_CLIENTS) return error.InvalidClientId;
        if (self.clients[client_id]) |*peer| {
            const seq = peer.nextSequence();
            var send_buf: [MAX_PACKET_SIZE]u8 = undefined;
            var writer = PacketWriter.init(&send_buf);

            const header = PacketHeader.init(packet_type, channel, seq, peer.remote_seq, peer.ack_bits);
            try writer.writeHeader(header);
            try writer.writeBytes(payload);

            const msg_bytes = writer.written();
            if (channel == .reliable) {
                // Store in peer pending reliable queue
                var stored = false;
                for (&peer.pending_reliable) |*p| {
                    if (p.len == 0 or p.acked) {
                        p.sequence = seq;
                        p.sent_time_ms = 0.0;
                        p.len = @intCast(msg_bytes.len);
                        @memcpy(p.data[0..msg_bytes.len], msg_bytes);
                        p.acked = false;
                        stored = true;
                        break;
                    }
                }
                if (!stored) {
                    peer.pending_reliable[0].sequence = seq;
                    peer.pending_reliable[0].len = @intCast(msg_bytes.len);
                    @memcpy(peer.pending_reliable[0].data[0..msg_bytes.len], msg_bytes);
                    peer.pending_reliable[0].acked = false;
                }
            }

            _ = try self.socket.sendTo(peer.address, msg_bytes);
        }
    }

    pub fn broadcast(
        self: *NetServer,
        packet_type: PacketType,
        channel: Channel,
        payload: []const u8,
    ) !void {
        for (&self.clients, 0..) |slot, idx| {
            if (slot != null) {
                try self.sendToClient(@intCast(idx), packet_type, channel, payload);
            }
        }
    }

    fn sendRawPacket(
        self: *NetServer,
        dest: NetAddress,
        pt: PacketType,
        ch: Channel,
        seq: u16,
        ack: u16,
        ack_bits: u32,
        payload: []const u8,
    ) !void {
        var buf: [MAX_PACKET_SIZE]u8 = undefined;
        var writer = PacketWriter.init(&buf);
        try writer.writeHeader(PacketHeader.init(pt, ch, seq, ack, ack_bits));
        try writer.writeBytes(payload);
        _ = try self.socket.sendTo(dest, writer.written());
    }

    fn findClientIndex(self: NetServer, addr: NetAddress) ?usize {
        for (self.clients, 0..) |slot, i| {
            if (slot) |peer| {
                if (peer.address.eql(addr)) return i;
            }
        }
        return null;
    }

    fn allocateClient(self: *NetServer, addr: NetAddress, now_ms: f64) ?usize {
        for (&self.clients, 0..) |*slot, i| {
            if (slot.* == null) {
                slot.* = Peer.init(@intCast(i), addr, now_ms);
                self.active_client_count += 1;
                return i;
            }
        }
        return null;
    }
};

pub const NetClient = struct {
    socket: UdpSocket,
    server_address: NetAddress = .{},
    state: ConnectionState = .disconnected,
    client_id: ?u32 = null,

    peer: Peer = undefined,
    recv_buffer: [MAX_PACKET_SIZE]u8 = undefined,

    pub fn init() !NetClient {
        var sock = try UdpSocket.init();
        errdefer sock.close();

        try sock.bindTo(NetAddress.any(0));
        return NetClient{
            .socket = sock,
            .server_address = .{},
            .state = .disconnected,
            .client_id = null,
            .peer = undefined,
        };
    }

    pub fn deinit(self: *NetClient) void {
        self.socket.close();
    }

    pub fn connect(self: *NetClient, server_addr: NetAddress, now_ms: f64) !void {
        self.server_address = server_addr;
        self.state = .connecting;
        self.peer = Peer.init(0, server_addr, now_ms);

        // Send connect request
        var buf: [HEADER_SIZE]u8 = undefined;
        var writer = PacketWriter.init(&buf);
        try writer.writeHeader(PacketHeader.init(.connect_request, .reliable, self.peer.nextSequence(), 0, 0));
        _ = try self.socket.sendTo(server_addr, writer.written());
    }

    pub fn disconnect(self: *NetClient) !void {
        if (self.state != .disconnected) {
            var buf: [HEADER_SIZE]u8 = undefined;
            var writer = PacketWriter.init(&buf);
            try writer.writeHeader(PacketHeader.init(.disconnect, .unreliable, self.peer.nextSequence(), self.peer.remote_seq, self.peer.ack_bits));
            _ = try self.socket.sendTo(self.server_address, writer.written());
            self.state = .disconnected;
            self.client_id = null;
        }
    }

    pub fn update(
        self: *NetClient,
        now_ms: f64,
        context: anytype,
        comptime on_message: fn (ctx: @TypeOf(context), msg: ReceivedMessage) void,
    ) !void {
        // 1. Read incoming packets
        while (try self.socket.recvFrom(&self.recv_buffer)) |packet| {
            if (!packet.sender.eql(self.server_address)) continue;
            if (packet.len < protocol.HEADER_SIZE) continue;

            var reader = PacketReader.init(self.recv_buffer[0..packet.len]);
            const header = reader.readHeader() catch continue;

            const p_type: PacketType = @enumFromInt(header.packet_type);
            self.peer.onPacketReceived(header.sequence, now_ms);
            self.peer.onAckReceived(header.ack, header.ack_bits, now_ms);

            switch (p_type) {
                .connect_accept => {
                    self.state = .connected;
                    if (reader.remaining() >= 1) {
                        self.client_id = try reader.readU8();
                    }
                },
                .connect_reject => {
                    self.state = .disconnected;
                },
                .disconnect => {
                    self.state = .disconnected;
                    self.client_id = null;
                },
                .heartbeat => {
                    // Send heartbeat_ack
                    var buf: [MAX_PACKET_SIZE]u8 = undefined;
                    var writer = PacketWriter.init(&buf);
                    try writer.writeHeader(PacketHeader.init(.heartbeat_ack, .unreliable, self.peer.nextSequence(), self.peer.remote_seq, self.peer.ack_bits));
                    try writer.writeBytes(reader.buffer[reader.cursor..]);
                    _ = try self.socket.sendTo(self.server_address, writer.written());
                },
                .heartbeat_ack => {
                    if (reader.remaining() >= 8) {
                        const send_ts = @as(f64, @bitCast(try reader.readU64()));
                        const sample = @as(f32, @floatCast(now_ms - send_ts));
                        self.peer.updateRtt(sample);
                    }
                },
                else => {
                    on_message(context, .{
                        .sender_id = self.client_id orelse 0,
                        .packet_type = p_type,
                        .payload = reader.buffer[reader.cursor..],
                    });
                },
            }
        }

        // 2. Client keepalives and connection timeout
        if (self.state == .connected) {
            if (now_ms - self.peer.last_recv_time_ms > CLIENT_TIMEOUT_MS) {
                self.state = .disconnected;
                self.client_id = null;
            } else if (now_ms - self.peer.last_heartbeat_time_ms > HEARTBEAT_INTERVAL_MS) {
                self.peer.last_heartbeat_time_ms = now_ms;
                var time_buf: [8]u8 = undefined;
                std.mem.writeInt(u64, &time_buf, @bitCast(now_ms), .little);
                try self.send(
                    .heartbeat,
                    .unreliable,
                    &time_buf,
                );
            }
        } else if (self.state == .connecting) {
            // Retransmit connect request if not accepted within 500ms
            if (now_ms - self.peer.last_send_time_ms > 500.0) {
                self.peer.last_send_time_ms = now_ms;
                var buf: [HEADER_SIZE]u8 = undefined;
                var writer = PacketWriter.init(&buf);
                try writer.writeHeader(PacketHeader.init(.connect_request, .reliable, self.peer.nextSequence(), 0, 0));
                _ = try self.socket.sendTo(self.server_address, writer.written());
            }
        }
    }

    pub fn send(self: *NetClient, packet_type: PacketType, channel: Channel, payload: []const u8) !void {
        if (self.state == .disconnected) return error.NotConnected;

        const seq = self.peer.nextSequence();
        var buf: [MAX_PACKET_SIZE]u8 = undefined;
        var writer = PacketWriter.init(&buf);

        const header = PacketHeader.init(packet_type, channel, seq, self.peer.remote_seq, self.peer.ack_bits);
        try writer.writeHeader(header);
        try writer.writeBytes(payload);

        _ = try self.socket.sendTo(self.server_address, writer.written());
    }

    pub fn getRtt(self: NetClient) f32 {
        return self.peer.rtt_ms;
    }
};

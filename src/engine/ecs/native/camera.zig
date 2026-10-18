const ecs = @import("../ecs.zig");
const std = @import("std");
const EngineContext = @import("../../scripting/engine_api.zig").EngineContext;

pub const CameraComponent = struct {
    fov: f32 = 60.0,
    priority: i32 = 0,
};

var top_priority_camera: ?struct {
    entity_id: u64,
    priority: i32,
} = null;

pub fn CameraSystem(world: *ecs.EcsWorld, entity_id: u64, _: f32, context: ?*anyopaque) void {
    const camera_comp_id = world.getComponentIdByName("CameraComponent") orelse return;
    var camera_comp: CameraComponent = undefined;
    const camera_bytes = std.mem.asBytes(&camera_comp);
    _ = world.getComponentData(entity_id, camera_comp_id, camera_bytes) orelse return;

    // if (top_priority_camera == null or camera_comp.priority > top_priority_camera.?.priority) {
    //     top_priority_camera = .{
    //         .entity_id = entity_id,
    //         .priority = camera_comp.priority,
    //     };

    //     const ctx_ptr = context orelse return;
    //     const ctx: *EngineContext = @ptrCast(@alignCast(ctx_ptr));
    //     if (ctx.camera) |camera| {
    //         if (world.getPosition(entity_id)) |p| {
    //             camera.position = .init(p.x, p.y, p.z);
    //             std.debug.print("camera position: {d} {d} {d}\n", .{ p.x, p.y, p.z });
    //         }
    //     }
    // }

    const ctx_ptr = context orelse return;
    const ctx: *EngineContext = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.camera) |camera| {
        if (world.getPosition(entity_id)) |p| {
            camera.position = .init(p.x, p.y, p.z);
            camera.yaw = if (world.getRotation(entity_id)) |r| r.y else 0.0;
            camera.pitch = if (world.getRotation(entity_id)) |r| r.x else 0.0;
            std.debug.print("camera yaw: {d}, pitch: {d}\n", .{ camera.yaw, camera.pitch });
            std.debug.print("camera position: {d} {d} {d}\n", .{ p.x, p.y, p.z });
        }
    }
}

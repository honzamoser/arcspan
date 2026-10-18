//! Re-exports the built-in Zig ECS module (`ecs.zig`) for backward compatibility.
const ecs_mod = @import("ecs.zig");

pub const c = ecs_mod.c;
pub const Position = ecs_mod.Position;
pub const Rotation = ecs_mod.Rotation;
pub const Scale = ecs_mod.Scale;
pub const Velocity = ecs_mod.Velocity;
pub const MeshRender = ecs_mod.MeshRender;
pub const PhysicsBody = ecs_mod.PhysicsBody;
pub const ScriptComponent = ecs_mod.ScriptComponent;
pub const Entity = ecs_mod.Entity;
pub const INVALID_ENTITY = ecs_mod.INVALID_ENTITY;
pub const ComponentId = ecs_mod.ComponentId;
pub const SystemId = ecs_mod.SystemId;
pub const MAX_ENTITIES = ecs_mod.MAX_ENTITIES;
pub const MAX_COMPONENTS = ecs_mod.MAX_COMPONENTS;
pub const MAX_DYNAMIC_COMPONENTS = ecs_mod.MAX_DYNAMIC_COMPONENTS;
pub const MAX_DYNAMIC_SYSTEMS = ecs_mod.MAX_DYNAMIC_SYSTEMS;
pub const DynamicComponent = ecs_mod.DynamicComponent;
pub const NativeSystemFn = ecs_mod.NativeSystemFn;
pub const SystemInfo = ecs_mod.SystemInfo;
pub const EcsWorld = ecs_mod.EcsWorld;

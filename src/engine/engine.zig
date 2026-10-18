pub const math = @import("math.zig");
pub const Window = @import("platform/window.zig").Window;
pub const platform = struct {
    pub const Window = @import("platform/window.zig").Window;
    pub const headless = @import("platform/headless.zig");
    pub const HeadlessServer = headless.HeadlessServer;
    pub const ServerConfig = headless.ServerConfig;
};
pub const InputState = @import("input/input.zig").InputState;
pub const Renderer = @import("renderer/renderer.zig").Renderer;
pub const Scene = @import("renderer/scene.zig").Scene;
pub const Vertex = @import("renderer/scene.zig").Vertex;
pub const RenderObject = @import("renderer/scene.zig").RenderObject;
pub const primitives = @import("renderer/primitives.zig");
pub const PrimitiveType = primitives.PrimitiveType;
pub const material = @import("renderer/material.zig");
pub const Material = material.Material;
pub const ShadingModel = material.ShadingModel;
pub const AlphaMode = material.AlphaMode;

pub const state = @import("state/game_state.zig");

pub const ecs = @import("ecs/ecs.zig");
pub const physics = @import("physics/jolt.zig");
pub const audio = @import("audio/audio.zig");

pub const camera = @import("camera/camera.zig");
pub const Camera = camera.Camera;
pub const FpsCameraController = camera.FpsCameraController;
pub const ThirdPersonController = camera.ThirdPersonController;
pub const RtsCameraController = camera.RtsCameraController;

pub const font = @import("renderer/font.zig");
pub const FontAtlas = font.FontAtlas;
pub const ui = @import("renderer/ui.zig");
pub const UiRenderer = ui.UiRenderer;

pub const lighting = @import("renderer/lighting.zig");
pub const PointLight = lighting.PointLight;
pub const SpotLight = lighting.SpotLight;
pub const DirectionalLight = lighting.DirectionalLight;
pub const LightingUniforms = lighting.LightingUniforms;
pub const ShadowMap = lighting.ShadowMap;

pub const skybox = @import("renderer/skybox.zig");
pub const Skybox = skybox.Skybox;

pub const postprocess = @import("renderer/postprocess.zig");
pub const PostProcessor = postprocess.PostProcessor;

pub const particles = @import("renderer/particles.zig");
pub const Particle = particles.Particle;
pub const ParticleSystem = particles.ParticleSystem;

pub const assets = struct {
    pub const gltf = @import("assets/gltf_loader.zig");
    pub const GltfLoader = gltf.GltfLoader;
    pub const ObjLoader = gltf.ObjLoader;
    pub const MeshData = gltf.MeshData;
    pub const ModelData = gltf.ModelData;

    pub const texture = @import("assets/texture_loader.zig");
    pub const TextureLoader = texture.TextureLoader;
    pub const QoiDecoder = texture.QoiDecoder;
    pub const TgaDecoder = texture.TgaDecoder;
    pub const Image = texture.Image;
};

pub const animation = struct {
    pub const skeleton = @import("animation/skeleton.zig");
    pub const Skeleton = skeleton.Skeleton;
    pub const Bone = skeleton.Bone;
    pub const Keyframe = skeleton.Keyframe;
    pub const BoneTrack = skeleton.BoneTrack;
    pub const AnimationClip = skeleton.AnimationClip;
    pub const MAX_BONES = skeleton.MAX_BONES;
};

pub const scripting = struct {
    pub const wamr = @import("scripting/wamr_bindings.zig");
    pub const wasm3 = wamr; // backward-compatibility alias
    pub const engine_api = @import("scripting/engine_api.zig");
    pub const EngineContext = engine_api.EngineContext;
    pub const ScriptHost = @import("scripting/script_host.zig").ScriptHost;
    pub const script_manager = @import("scripting/script_manager.zig");
    pub const ScriptManager = script_manager.ScriptManager;
    pub const ScriptInstance = script_manager.ScriptInstance;
    pub const Watchdog = script_manager.Watchdog;
    pub const task_scheduler = @import("scripting/task_scheduler.zig");
    pub const TaskScheduler = task_scheduler.TaskScheduler;
    pub const state = @import("state/game_state.zig");
};

pub const net = struct {
    pub const protocol = @import("net/protocol.zig");
    pub const transport = @import("net/transport.zig");
    pub const replication = @import("net/replication.zig");
    pub const UdpSocket = transport.UdpSocket;
    pub const NetAddress = transport.NetAddress;
    pub const NetServer = transport.NetServer;
    pub const NetClient = transport.NetClient;
    pub const PacketType = protocol.PacketType;
    pub const Channel = protocol.Channel;
    pub const EntitySnapshot = replication.EntitySnapshot;
    pub const WorldSnapshot = replication.WorldSnapshot;
    pub const SnapshotInterpolator = replication.SnapshotInterpolator;
    pub const RemoteEventMessage = replication.RemoteEventMessage;
    pub const RemoteEventManager = replication.RemoteEventManager;
};

struct ParticleUniforms {
    view_proj: mat4x4<f32>,
    cam_right: vec3<f32>,
    pad0: f32,
    cam_up: vec3<f32>,
    pad1: f32,
};

@group(0) @binding(0)
var<uniform> uniforms: ParticleUniforms;

struct VertexInput {
    // Quad vertex: [-0.5, 0.5]
    @location(0) quad_pos: vec2<f32>,
    @location(1) uv: vec2<f32>,
    // Instance attributes
    @location(2) inst_pos: vec3<f32>,
    @location(3) inst_lifetime: f32,
    @location(4) inst_vel: vec3<f32>,
    @location(5) inst_max_lifetime: f32,
    @location(6) inst_color: vec4<f32>,
    @location(7) inst_size: f32,
    @location(8) inst_growth: f32,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) color: vec4<f32>,
};

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;

    // Camera billboarding: expand quad along camera right and camera up vectors
    let offset = (uniforms.cam_right * in.quad_pos.x + uniforms.cam_up * in.quad_pos.y) * in.inst_size;
    let world_pos = in.inst_pos + offset;

    out.clip_position = uniforms.view_proj * vec4<f32>(world_pos, 1.0);
    out.uv = in.uv;

    // Fade color alpha over life
    let life_ratio = clamp(in.inst_lifetime / max(in.inst_max_lifetime, 0.001), 0.0, 1.0);
    out.color = vec4<f32>(in.inst_color.rgb, in.inst_color.a * life_ratio);

    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    // Soft circular particle shape
    let dist = length(in.uv - vec2<f32>(0.5, 0.5));
    if (dist > 0.5) {
        discard;
    }
    let alpha = (1.0 - smoothstep(0.1, 0.5, dist)) * in.color.a;
    return vec4<f32>(in.color.rgb, alpha);
}

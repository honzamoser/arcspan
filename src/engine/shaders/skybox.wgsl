struct SkyboxUniforms {
    view: mat4x4<f32>,
    proj: mat4x4<f32>,
};

@group(0) @binding(0)
var<uniform> uniforms: SkyboxUniforms;

@group(0) @binding(1)
var env_cube: texture_cube<f32>;

@group(0) @binding(2)
var env_sampler: sampler;

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) view_dir: vec3<f32>,
};

@vertex
fn vs_main(@location(0) position: vec3<f32>) -> VertexOutput {
    var out: VertexOutput;
    out.view_dir = position;
    // Strip translation from view matrix so skybox stays centered around camera
    let view3 = mat3x3<f32>(
        uniforms.view[0].xyz,
        uniforms.view[1].xyz,
        uniforms.view[2].xyz
    );
    let view_pos = view3 * position;
    let clip_pos = uniforms.proj * vec4<f32>(view_pos, 1.0);
    // Setting z = w forces depth to 1.0 in WebGPU depth clip space [0, 1]
    out.clip_position = clip_pos.xyww;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let dir = normalize(in.view_dir);
    let sky_color = textureSample(env_cube, env_sampler, dir);
    return vec4<f32>(sky_color.rgb, 1.0);
}

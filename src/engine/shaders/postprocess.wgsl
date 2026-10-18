struct PostProcessUniforms {
    bloom_intensity: f32,
    exposure: f32,
    gamma: f32,
    bright_threshold: f32,
    texel_size: vec2<f32>,
    blur_dir: vec2<f32>,
};

@group(0) @binding(0)
var<uniform> uniforms: PostProcessUniforms;

@group(0) @binding(1)
var hdr_texture: texture_2d<f32>;

@group(0) @binding(2)
var post_sampler: sampler;

@group(0) @binding(3)
var bloom_texture: texture_2d<f32>;

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_fullscreen(@builtin(vertex_index) vertex_index: u32) -> VertexOutput {
    var out: VertexOutput;
    // Generates a large fullscreen triangle covering [-1, 1] in clip space
    // index 0: (-1, -1), uv (0, 1)
    // index 1: ( 3, -1), uv (2, 1)
    // index 2: (-1,  3), uv (0, -1)
    let uv = vec2<f32>(
        f32((vertex_index << 1u) & 2u),
        f32(vertex_index & 2u)
    );
    out.clip_position = vec4<f32>(uv * 2.0 - 1.0, 0.0, 1.0);
    // WebGPU UV Y is top-to-bottom
    out.uv = vec2<f32>(uv.x, 1.0 - uv.y);
    return out;
}

// 1. Bright Pass Filter: extracts HDR highlights above bright_threshold with soft knee
@fragment
fn fs_bright_pass(in: VertexOutput) -> @location(0) vec4<f32> {
    let color = textureSample(hdr_texture, post_sampler, in.uv).rgb;
    let brightness = dot(color, vec3<f32>(0.2126, 0.7152, 0.0722));
    let knee = 0.5;
    let soft = clamp(brightness - uniforms.bright_threshold + knee, 0.0, 2.0 * knee);
    let soft_weight = (soft * soft) / (4.0 * knee + 0.0001);
    let weight = max(brightness - uniforms.bright_threshold, soft_weight) / max(brightness, 0.0001);
    return vec4<f32>(color * clamp(weight, 0.0, 10.0), 1.0);
}

// 2. Separable Gaussian Blur Pass
@fragment
fn fs_blur(in: VertexOutput) -> @location(0) vec4<f32> {
    let offset = uniforms.texel_size * uniforms.blur_dir;
    var result = textureSample(hdr_texture, post_sampler, in.uv).rgb * 0.227027;

    result += textureSample(hdr_texture, post_sampler, in.uv + offset * 1.3846153846).rgb * 0.3162162162;
    result += textureSample(hdr_texture, post_sampler, in.uv - offset * 1.3846153846).rgb * 0.3162162162;

    result += textureSample(hdr_texture, post_sampler, in.uv + offset * 3.2307692308).rgb * 0.0702702703;
    result += textureSample(hdr_texture, post_sampler, in.uv - offset * 3.2307692308).rgb * 0.0702702703;

    return vec4<f32>(result, 1.0);
}

// ACES Filmic Tone Mapping Curve (Narkowicz 2015)
fn acesFilm(x: vec3<f32>) -> vec3<f32> {
    let a = 2.51;
    let b = 0.03;
    let c = 2.43;
    let d = 0.59;
    let e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), vec3<f32>(0.0), vec3<f32>(1.0));
}

// 3. Composition Pass: HDR Scene + Bloom + ACES Tonemapping + Gamma Correction
@fragment
fn fs_composite(in: VertexOutput) -> @location(0) vec4<f32> {
    let hdr_color = textureSample(hdr_texture, post_sampler, in.uv).rgb * uniforms.exposure;
    let bloom_color = textureSample(bloom_texture, post_sampler, in.uv).rgb * uniforms.bloom_intensity;

    let combined = hdr_color + bloom_color;

    // ACES Filmic Tone Mapping
    let ldr_color = acesFilm(combined);

    // Gamma correction
    let gamma_inv = 1.0 / uniforms.gamma;
    let final_color = pow(ldr_color, vec3<f32>(gamma_inv));

    return vec4<f32>(final_color, 1.0);
}

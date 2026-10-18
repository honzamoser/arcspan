struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) color: vec3<f32>,
    @location(3) uv: vec2<f32>,
    @location(4) material_params: vec4<f32>, // x = metallic, y = roughness, z = emissive_intensity, w = shading_model
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) world_pos: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) color: vec3<f32>,
    @location(3) uv: vec2<f32>,
    @location(4) material_params: vec4<f32>,
};

struct Uniforms {
    model_matrix: mat4x4<f32>,
    view_proj: mat4x4<f32>,
    camera_pos: vec3<f32>,
    time: f32,
    light_dir: vec3<f32>,
    light_intensity: f32,
    light_color: vec3<f32>,
    ambient_intensity: f32,
};

@group(0) @binding(0)
var<uniform> uniforms: Uniforms;

@group(0) @binding(1)
var diffuse_texture: texture_2d<f32>;

@group(0) @binding(2)
var diffuse_sampler: sampler;

const PI: f32 = 3.14159265359;

@vertex
fn vs_main(model: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    let world_pos = (uniforms.model_matrix * vec4<f32>(model.position, 1.0)).xyz;
    out.world_pos = world_pos;
    out.clip_position = uniforms.view_proj * vec4<f32>(world_pos, 1.0);
    out.normal = normalize((uniforms.model_matrix * vec4<f32>(model.normal, 0.0)).xyz);
    out.color = model.color;
    out.uv = model.uv;
    out.material_params = model.material_params;
    return out;
}

// GGX Normal Distribution Function
fn distributionGGX(N: vec3<f32>, H: vec3<f32>, roughness: f32) -> f32 {
    let a = roughness * roughness;
    let a2 = a * a;
    let NdotH = max(dot(N, H), 0.0);
    let NdotH2 = NdotH * NdotH;
    let num = a2;
    var denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;
    return num / max(denom, 0.0001);
}

// Schlick-GGX Geometry Function
fn geometrySchlickGGX(NdotV: f32, roughness: f32) -> f32 {
    let r = (roughness + 1.0);
    let k = (r * r) / 8.0;
    return NdotV / (NdotV * (1.0 - k) + k);
}

// Smith Geometry Function
fn geometrySmith(N: vec3<f32>, V: vec3<f32>, L: vec3<f32>, roughness: f32) -> f32 {
    let NdotV = max(dot(N, V), 0.0);
    let NdotL = max(dot(N, L), 0.0);
    let ggx2 = geometrySchlickGGX(NdotV, roughness);
    let ggx1 = geometrySchlickGGX(NdotL, roughness);
    return ggx1 * ggx2;
}

// Fresnel Schlick approximation
fn fresnelSchlick(cosTheta: f32, F0: vec3<f32>) -> vec3<f32> {
    return F0 + (vec3<f32>(1.0) - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let tex_sample = textureSample(diffuse_texture, diffuse_sampler, in.uv);
    let shading_model = u32(round(in.material_params.w));

    // 1. Unlit / Emissive Only Mode
    if (shading_model == 2u) {
        let emissive_boost = 1.0 + in.material_params.z;
        return vec4<f32>(in.color * tex_sample.rgb * emissive_boost, 1.0);
    }

    let albedo = in.color * tex_sample.rgb;
    let metallic = clamp(in.material_params.x, 0.0, 1.0);
    let roughness = clamp(in.material_params.y, 0.04, 1.0);
    let emissive_intensity = in.material_params.z;

    let N = normalize(in.normal);
    let V = normalize(uniforms.camera_pos - in.world_pos);
    let L = normalize(-uniforms.light_dir);
    let H = normalize(V + L);

    let NdotL = max(dot(N, L), 0.0);
    let NdotV = max(dot(N, V), 0.001);

    // 2. Blinn-Phong Mode
    if (shading_model == 1u) {
        let diff = NdotL;
        let spec = pow(max(dot(N, H), 0.0), 32.0 * (1.0 - roughness));
        let ambient = albedo * uniforms.ambient_intensity;
        let diffuse = albedo * uniforms.light_color * uniforms.light_intensity * diff;
        let specular = vec3<f32>(1.0) * spec * metallic;
        return vec4<f32>(ambient + diffuse + specular + albedo * emissive_intensity, 1.0);
    }

    // 3. Physically-Based Rendering (PBR / Cook-Torrance GGX)
    let F0 = mix(vec3<f32>(0.04), albedo, metallic);

    let NDF = distributionGGX(N, H, roughness);
    let G = geometrySmith(N, V, L, roughness);
    let F = fresnelSchlick(max(dot(H, V), 0.0), F0);

    let numerator = NDF * G * F;
    let denominator = 4.0 * NdotV * NdotL + 0.0001;
    let specular = numerator / denominator;

    let kS = F;
    let kD = (vec3<f32>(1.0) - kS) * (1.0 - metallic);

    let radiance = uniforms.light_color * uniforms.light_intensity;
    let Lo = (kD * albedo / PI + specular) * radiance * NdotL;

    // Hemispheric ambient lighting with subtle ground bounce
    let sky_ambient = uniforms.ambient_intensity * (0.65 + 0.35 * N.y);
    let ambient = albedo * sky_ambient;
    let emissive = albedo * emissive_intensity;

    let color = ambient + Lo + emissive;

    // Reinhard Tone Mapping & Gamma Correction
    let mapped = color / (color + vec3<f32>(1.0));
    let final_color = pow(mapped, vec3<f32>(1.0 / 2.2));

    return vec4<f32>(final_color, 1.0);
}

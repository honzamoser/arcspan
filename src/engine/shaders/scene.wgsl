//! PBR & Dynamic Multi-Lighting WGSL Shader
//! Supports 16 Point Lights, 8 Spot Lights, 1 Directional Light with 3-split CSM and IBL Cubemap reflections.

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

struct PointLight {
    position: vec3<f32>,
    radius: f32,
    color: vec3<f32>,
    intensity: f32,
};

struct SpotLight {
    position: vec3<f32>,
    inner_cone_cos: f32,
    direction: vec3<f32>,
    outer_cone_cos: f32,
    color: vec3<f32>,
    intensity: f32,
};

struct DirectionalLight {
    direction: vec3<f32>,
    intensity: f32,
    color: vec3<f32>,
    pad: f32,
};

struct LightingUniforms {
    model_matrix: mat4x4<f32>,
    view_proj: mat4x4<f32>,
    camera_pos: vec3<f32>,
    time: f32,
    dir_light: DirectionalLight,
    cascade_splits: vec4<f32>, // x: split0, y: split1, z: split2, w: shadow_bias
    cascade_view_proj: array<mat4x4<f32>, 3>,
    ambient_color: vec3<f32>,
    ambient_intensity: f32,
    light_counts: vec4<u32>, // x: point count, y: spot count, z: shadows enabled (1 or 0), w: cascade count
    point_lights: array<PointLight, 16>,
    spot_lights: array<SpotLight, 8>,
};

@group(0) @binding(0)
var<uniform> uniforms: LightingUniforms;

@group(0) @binding(1)
var diffuse_texture: texture_2d<f32>;

@group(0) @binding(2)
var diffuse_sampler: sampler;

@group(0) @binding(3)
var shadow_map: texture_depth_2d_array;

@group(0) @binding(4)
var shadow_sampler: sampler_comparison;

@group(0) @binding(5)
var env_cube: texture_cube<f32>;

@group(0) @binding(6)
var env_sampler: sampler;

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

// 3x3 PCF Cascaded Shadow Map Sampling
fn sampleShadowCSM(world_pos: vec3<f32>, N: vec3<f32>, L: vec3<f32>) -> f32 {
    if (uniforms.light_counts.z == 0u) {
        return 1.0;
    }

    let cam_dist = length(uniforms.camera_pos - world_pos);
    var cascade_idx: i32 = 0;
    if (cam_dist > uniforms.cascade_splits.y) {
        cascade_idx = 2;
    } else if (cam_dist > uniforms.cascade_splits.x) {
        cascade_idx = 1;
    }

    let light_clip = uniforms.cascade_view_proj[cascade_idx] * vec4<f32>(world_pos, 1.0);
    let proj = light_clip.xyz / light_clip.w;
    let shadow_uv = vec2<f32>(proj.x * 0.5 + 0.5, -proj.y * 0.5 + 0.5);
    let current_depth = proj.z;

    if (current_depth > 1.0 || shadow_uv.x < 0.0 || shadow_uv.x > 1.0 || shadow_uv.y < 0.0 || shadow_uv.y > 1.0) {
        return 1.0;
    }

    // Adaptive normal slope bias to eliminate shadow acne
    let normal_bias = max(0.002 * (1.0 - dot(N, L)), 0.0004);
    let bias = normal_bias + uniforms.cascade_splits.w;

    let texel_size = vec2<f32>(1.0 / 2048.0, 1.0 / 2048.0);
    var shadow: f32 = 0.0;

    for (var x: i32 = -1; x <= 1; x++) {
        for (var y: i32 = -1; y <= 1; y++) {
            let offset = vec2<f32>(f32(x), f32(y)) * texel_size;
            shadow += textureSampleCompare(
                shadow_map,
                shadow_sampler,
                shadow_uv + offset,
                cascade_idx,
                current_depth - bias
            );
        }
    }

    return shadow / 9.0;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let tex_sample = textureSample(diffuse_texture, diffuse_sampler, in.uv);
    let shading_model = u32(round(in.material_params.w));

    // 1. Unlit / Emissive Only Mode (Outputs directly in HDR space for Bloom extraction)
    if (shading_model == 2u) {
        let emissive_boost = 1.0 + in.material_params.z * 3.0;
        return vec4<f32>(in.color * tex_sample.rgb * emissive_boost, 1.0);
    }

    let albedo = in.color * tex_sample.rgb;
    let metallic = clamp(in.material_params.x, 0.0, 1.0);
    let roughness = clamp(in.material_params.y, 0.04, 1.0);
    let emissive_intensity = in.material_params.z;

    let N = normalize(in.normal);
    let V = normalize(uniforms.camera_pos - in.world_pos);
    let NdotV = max(dot(N, V), 0.001);

    // 2. Blinn-Phong Mode
    if (shading_model == 1u) {
        let L = normalize(-uniforms.dir_light.direction);
        let H = normalize(V + L);
        let diff = max(dot(N, L), 0.0);
        let shadow = sampleShadowCSM(in.world_pos, N, L);

        let spec = pow(max(dot(N, H), 0.0), 32.0 * (1.0 - roughness));
        let ambient = albedo * uniforms.ambient_intensity;
        let diffuse = albedo * uniforms.dir_light.color * uniforms.dir_light.intensity * diff * shadow;
        let specular = vec3<f32>(1.0) * spec * metallic * shadow;
        return vec4<f32>(ambient + diffuse + specular + albedo * emissive_intensity, 1.0);
    }

    // 3. Physically-Based Rendering (Cook-Torrance GGX PBR)
    let F0 = mix(vec3<f32>(0.04), albedo, metallic);

    var Lo = vec3<f32>(0.0);

    // --- Directional Light with CSM Shadows ---
    {
        let L = normalize(-uniforms.dir_light.direction);
        let H = normalize(V + L);
        let NdotL = max(dot(N, L), 0.0);

        if (NdotL > 0.0) {
            let shadow = sampleShadowCSM(in.world_pos, N, L);

            let NDF = distributionGGX(N, H, roughness);
            let G = geometrySmith(N, V, L, roughness);
            let F = fresnelSchlick(max(dot(H, V), 0.0), F0);

            let numerator = NDF * G * F;
            let denominator = 4.0 * NdotV * NdotL + 0.0001;
            let specular = numerator / denominator;

            let kS = F;
            let kD = (vec3<f32>(1.0) - kS) * (1.0 - metallic);

            let radiance = uniforms.dir_light.color * uniforms.dir_light.intensity;
            Lo += (kD * albedo / PI + specular) * radiance * NdotL * shadow;
        }
    }

    // --- Point Lights Loop ---
    let num_points = min(uniforms.light_counts.x, 16u);
    for (var i: u32 = 0u; i < num_points; i = i + 1u) {
        let light = uniforms.point_lights[i];
        let light_dir = light.position - in.world_pos;
        let distance = length(light_dir);

        if (distance < light.radius) {
            let L = normalize(light_dir);
            let H = normalize(V + L);
            let NdotL = max(dot(N, L), 0.0);

            if (NdotL > 0.0) {
                // Smooth windowing attenuation
                let norm_dist = distance / light.radius;
                let window = clamp(1.0 - norm_dist * norm_dist * norm_dist * norm_dist, 0.0, 1.0);
                let attenuation = (window * window) / (distance * distance + 1.0);

                let NDF = distributionGGX(N, H, roughness);
                let G = geometrySmith(N, V, L, roughness);
                let F = fresnelSchlick(max(dot(H, V), 0.0), F0);

                let specular = (NDF * G * F) / (4.0 * NdotV * NdotL + 0.0001);
                let kS = F;
                let kD = (vec3<f32>(1.0) - kS) * (1.0 - metallic);

                let radiance = light.color * light.intensity * attenuation;
                Lo += (kD * albedo / PI + specular) * radiance * NdotL;
            }
        }
    }

    // --- Spot Lights Loop ---
    let num_spots = min(uniforms.light_counts.y, 8u);
    for (var i: u32 = 0u; i < num_spots; i = i + 1u) {
        let light = uniforms.spot_lights[i];
        let light_dir = light.position - in.world_pos;
        let distance = length(light_dir);

        let L = normalize(light_dir);
        let theta = dot(-L, normalize(light.direction));

        if (theta > light.outer_cone_cos) {
            let epsilon = max(light.inner_cone_cos - light.outer_cone_cos, 0.0001);
            let spot_intensity = clamp((theta - light.outer_cone_cos) / epsilon, 0.0, 1.0);
            let attenuation = spot_intensity / (distance * distance + 1.0);

            let H = normalize(V + L);
            let NdotL = max(dot(N, L), 0.0);

            if (NdotL > 0.0) {
                let NDF = distributionGGX(N, H, roughness);
                let G = geometrySmith(N, V, L, roughness);
                let F = fresnelSchlick(max(dot(H, V), 0.0), F0);

                let specular = (NDF * G * F) / (4.0 * NdotV * NdotL + 0.0001);
                let kS = F;
                let kD = (vec3<f32>(1.0) - kS) * (1.0 - metallic);

                let radiance = light.color * light.intensity * attenuation;
                Lo += (kD * albedo / PI + specular) * radiance * NdotL;
            }
        }
    }

    // --- Image-Based Lighting (IBL) & Environment Reflections ---
    let R = reflect(-V, N);
    // Specular environment reflection with roughness
    let env_specular_color = textureSample(env_cube, env_sampler, R).rgb;
    let env_fresnel = F0 + (max(vec3<f32>(1.0 - roughness), F0) - F0) * pow(clamp(1.0 - NdotV, 0.0, 1.0), 5.0);
    let ibl_specular = env_specular_color * env_fresnel * (1.0 - roughness * 0.5);

    // Diffuse environment irradiance
    let env_diffuse_color = textureSample(env_cube, env_sampler, N).rgb;
    let kS_env = env_fresnel;
    let kD_env = (vec3<f32>(1.0) - kS_env) * (1.0 - metallic);
    let ibl_diffuse = env_diffuse_color * albedo * kD_env;

    let ambient = (ibl_diffuse + ibl_specular) * uniforms.ambient_intensity;
    let emissive = albedo * emissive_intensity;

    let hdr_color = ambient + Lo + emissive;

    // Output raw HDR floating point color (HDR pass tone-maps in post-processing pipeline)
    return vec4<f32>(hdr_color, 1.0);
}

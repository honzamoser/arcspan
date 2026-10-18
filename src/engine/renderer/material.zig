const std = @import("std");

pub const ShadingModel = enum(u32) {
    pbr = 0,         // Physically-Based Rendering (Cook-Torrance GGX microfacet BRDF)
    blinn_phong = 1, // Specular + Diffuse + Ambient
    unlit = 2,       // Emissive / Unlit (ignores lights, constant illumination)
};

pub const AlphaMode = enum(u32) {
    @"opaque" = 0,
    blend = 1,
    mask = 2,
};

pub const Material = extern struct {
    shading_model: ShadingModel = .pbr,
    base_color: [4]f32 = [_]f32{ 1.0, 1.0, 1.0, 1.0 },
    metallic: f32 = 0.0,            // 0.0 = dielectric (wood, plastic), 1.0 = metallic (gold, copper, chrome)
    roughness: f32 = 0.5,           // 0.0 = mirror-smooth, 1.0 = rough diffuse
    emissive: [3]f32 = [_]f32{ 0.0, 0.0, 0.0 }, // Emissive color
    emissive_intensity: f32 = 0.0,  // Multiplier for emissive glow
    alpha_mode: AlphaMode = .@"opaque",
    texture_id: u32 = 0,            // 0 = default procedural texture, >0 = loaded texture ID
    _pad: [2]f32 = [_]f32{ 0.0, 0.0 },

    pub fn default() Material {
        return .{};
    }

    pub fn pbr(color: [4]f32, metallic: f32, roughness: f32) Material {
        return .{
            .shading_model = .pbr,
            .base_color = color,
            .metallic = std.math.clamp(metallic, 0.0, 1.0),
            .roughness = std.math.clamp(roughness, 0.04, 1.0),
        };
    }

    pub fn unlit(color: [4]f32) Material {
        return .{
            .shading_model = .unlit,
            .base_color = color,
            .metallic = 0.0,
            .roughness = 1.0,
        };
    }

    pub fn emissiveGlow(color: [3]f32, intensity: f32) Material {
        return .{
            .shading_model = .unlit,
            .base_color = [_]f32{ color[0], color[1], color[2], 1.0 },
            .emissive = color,
            .emissive_intensity = intensity,
        };
    }

    pub fn matte(color: [4]f32) Material {
        return pbr(color, 0.0, 0.9);
    }

    pub fn plastic(color: [4]f32, roughness: f32) Material {
        return pbr(color, 0.0, roughness);
    }

    // Standard PBR Metal presets with real physical reflectance (F0)
    pub fn gold() Material {
        return .{
            .shading_model = .pbr,
            .base_color = [_]f32{ 1.00, 0.76, 0.33, 1.0 }, // Gold albedo
            .metallic = 1.0,
            .roughness = 0.22,
        };
    }

    pub fn copper() Material {
        return .{
            .shading_model = .pbr,
            .base_color = [_]f32{ 0.95, 0.64, 0.54, 1.0 }, // Copper albedo
            .metallic = 0.95,
            .roughness = 0.30,
        };
    }

    pub fn chrome() Material {
        return .{
            .shading_model = .pbr,
            .base_color = [_]f32{ 0.95, 0.95, 0.97, 1.0 }, // Polished silver / chrome
            .metallic = 1.0,
            .roughness = 0.08,
        };
    }

    pub fn ruby() Material {
        return .{
            .shading_model = .pbr,
            .base_color = [_]f32{ 0.95, 0.12, 0.24, 1.0 },
            .metallic = 0.05,
            .roughness = 0.12,
        };
    }

    pub fn emerald() Material {
        return .{
            .shading_model = .pbr,
            .base_color = [_]f32{ 0.12, 0.88, 0.42, 1.0 },
            .metallic = 0.05,
            .roughness = 0.15,
        };
    }
};

test "Material size and layout alignment" {
    try std.testing.expect(@sizeOf(Material) % 16 == 0);
    const gold_mat = Material.gold();
    try std.testing.expectEqual(@as(f32, 1.0), gold_mat.metallic);
    try std.testing.expectEqual(ShadingModel.pbr, gold_mat.shading_model);
}

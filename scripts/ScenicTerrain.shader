shader_type spatial;
render_mode shading_model_pbr, cull_back;

// 原有真实草/土/岩石颜色与法线贴图；无程序噪声、正弦岩层或纯色雪带。
uniform sampler2D grass_color : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D soil_color : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_color : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ground_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec3 grass_tint = vec3(0.92, 0.96, 0.90);
uniform vec3 earth_tint = vec3(0.96, 0.94, 0.90);
uniform vec3 stone_tint = vec3(0.96, 0.97, 0.95);
uniform vec4 biome = vec4(0.0, 0.0, 0.0, 0.0);

void fragment() {
    vec3 base = normalize(NORMAL);
    vec3 weights = pow(abs(base), vec3(4.0));
    weights /= max(weights.x + weights.y + weights.z, 0.001);
    vec2 ground_uv = VERTEX.xz * 0.38;
    vec3 grass_sample = texture(grass_color, ground_uv).rgb;
    vec3 earth_sample = texture(soil_color, VERTEX.xz * 0.31).rgb;
    vec3 sx = texture(rock_color, VERTEX.zy * 0.24).rgb;
    vec3 sy = texture(rock_color, VERTEX.xz * 0.24).rgb;
    vec3 sz = texture(rock_color, VERTEX.xy * 0.24).rgb;
    vec3 stone_sample = sx * weights.x + sy * weights.y + sz * weights.z;
    // 仅按真实坡度/海拔平滑选择已有纹理；不拿hash值把山涂成宏观色块。
    float slope = 1.0 - clamp(base.y, 0.0, 1.0);
    float rock_weight = smoothstep(0.14, 0.48, slope);
    rock_weight = max(rock_weight, biome.z * smoothstep(170.0, 330.0, VERTEX.y) * 0.65);
    float soil_weight = 0.10 + biome.y * 0.38 + biome.x * 0.70;
    soil_weight = max(soil_weight, biome.w * (1.0 - smoothstep(1.0, 12.0, VERTEX.y)));
    vec3 grass = grass_sample * grass_tint;
    vec3 earth = earth_sample * earth_tint;
    vec3 stone = stone_sample * stone_tint;
    ALBEDO = mix(mix(grass, earth, clamp(soil_weight, 0.0, 1.0)), stone, rock_weight);

    vec3 gn = texture(ground_normal, ground_uv).rgb * 2.0 - 1.0;
    vec3 nx = texture(rock_normal, VERTEX.zy * 0.24).rgb * 2.0 - 1.0;
    vec3 ny = texture(rock_normal, VERTEX.xz * 0.24).rgb * 2.0 - 1.0;
    vec3 nz = texture(rock_normal, VERTEX.xy * 0.24).rgb * 2.0 - 1.0;
    vec3 rock_detail = vec3(0.0, nx.y, nx.x) * weights.x
        + vec3(ny.x, 0.0, ny.y) * weights.y + vec3(nz.x, nz.y, 0.0) * weights.z;
    vec3 detail = mix(vec3(gn.x, 0.0, gn.y) * 0.36, rock_detail * 0.42, rock_weight);
    float fade = 1.0 - smoothstep(55.0, 190.0, length(CAMERA_POSITION_WORLD - VERTEX));
    NORMAL = normalize(base + (detail - base * dot(detail, base)) * fade);
    float surface_luma = dot(ALBEDO, vec3(0.2126, 0.7152, 0.0722));
    ROUGHNESS = clamp(0.96 - surface_luma * 0.08 - rock_weight * 0.03, 0.86, 0.98);
    SPECULAR = 0.16;
    METALLIC = 0.0;
    AO = 1.0;
}

shader_type spatial;
render_mode shading_model_pbr, cull_back;

// 五张共享纹理加环境反射，保持移动端六槽预算；坡面也使用连续混合材质。
uniform sampler2D grass_color : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D soil_color : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_color : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ground_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec3 grass_tint = vec3(0.62, 0.72, 0.47);
uniform vec3 earth_tint = vec3(0.68, 0.59, 0.45);
uniform vec3 stone_tint = vec3(0.72, 0.72, 0.68);
uniform vec4 biome = vec4(0.0, 0.0, 0.0, 0.0); // 干旱、林地、高山、海岸

float terrain_noise(vec2 p) {
    vec2 cell = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    vec4 h = fract(sin(vec4(dot(cell, vec2(127.1, 311.7)), dot(cell + vec2(1.0, 0.0), vec2(127.1, 311.7)),
        dot(cell + vec2(0.0, 1.0), vec2(127.1, 311.7)), dot(cell + vec2(1.0), vec2(127.1, 311.7)))) * 43758.5453);
    return mix(mix(h.x, h.y, f.x), mix(h.z, h.w, f.x), f.y);
}

void fragment() {
    vec3 base = normalize(NORMAL);
    vec3 weights = pow(abs(base), vec3(4.0));
    weights /= max(weights.x + weights.y + weights.z, 0.001);
    float distance_to_eye = length(CAMERA_POSITION_WORLD - VERTEX);
    float fine_fade = 1.0 - smoothstep(55.0, 190.0, distance_to_eye);
    float macro = terrain_noise(VERTEX.xz * 0.013);
    float patch = terrain_noise(VERTEX.xz * 0.085 + vec2(17.2, 8.1));
    vec2 ground_uv = VERTEX.xz * 0.45;
    vec3 grass_sample = texture(grass_color, ground_uv).rgb;
    vec3 earth_sample = texture(soil_color, VERTEX.xz * 0.31).rgb;
    vec3 broad_sample = texture(soil_color, VERTEX.xz * 0.037 + vec2(0.37, 0.19)).rgb;
    vec3 sx = texture(rock_color, VERTEX.zy * 0.24).rgb;
    vec3 sy = texture(rock_color, VERTEX.xz * 0.24).rgb;
    vec3 sz = texture(rock_color, VERTEX.xy * 0.24).rgb;
    vec3 stone_sample = sx * weights.x + sy * weights.y + sz * weights.z;
    float grass_luma = dot(grass_sample, vec3(0.2126, 0.7152, 0.0722));
    // 保留草叶对比，不让一张鲜绿贴图把整座山涂成同一颜色。
    vec3 grass = mix(vec3(grass_luma), grass_sample, 0.32) * grass_tint;
    grass *= mix(0.72, 1.22, macro) * mix(0.88, 1.12, patch);
    vec3 earth = earth_sample * earth_tint * mix(0.80, 1.18, macro);
    vec3 stone = stone_sample * stone_tint;
    // 米级岩理与十米级侵蚀条带：不是按单个三角形硬分色。
    float stratum = sin(VERTEX.y * 0.74 + macro * 3.8 + broad_sample.r * 1.5);
    stone *= mix(0.80, 1.16, smoothstep(-0.75, 0.65, stratum)) * mix(0.84, 1.10, patch);
    float slope = 1.0 - clamp(base.y, 0.0, 1.0);
    float rock_weight = smoothstep(0.11 + patch * 0.07, 0.42, slope);
    rock_weight = max(rock_weight, biome.z * smoothstep(135.0, 290.0, VERTEX.y) * 0.70);
    rock_weight = max(rock_weight, biome.x * smoothstep(0.15, 0.49, slope + patch * 0.13));
    float soil_weight = smoothstep(0.40, 0.73, patch + broad_sample.r * 0.27) * 0.56;
    soil_weight = max(soil_weight, biome.y * (0.42 + macro * 0.35));
    soil_weight = max(soil_weight, biome.x * 0.86);
    float beach = biome.w * (1.0 - smoothstep(1.0, 11.0, VERTEX.y));
    soil_weight = max(soil_weight, beach);
    vec3 mixed = mix(mix(grass, earth, soil_weight), stone, rock_weight);
    float snow = biome.z * smoothstep(265.0, 345.0, VERTEX.y + macro * 19.0)
        * (1.0 - smoothstep(0.26, 0.58, slope));
    ALBEDO = mix(mixed, vec3(0.68, 0.73, 0.75) * mix(0.88, 1.08, patch), snow);

    vec3 gn = texture(ground_normal, ground_uv).rgb * 2.0 - 1.0;
    vec3 nx = texture(rock_normal, VERTEX.zy * 0.24).rgb * 2.0 - 1.0;
    vec3 ny = texture(rock_normal, VERTEX.xz * 0.24).rgb * 2.0 - 1.0;
    vec3 nz = texture(rock_normal, VERTEX.xy * 0.24).rgb * 2.0 - 1.0;
    vec3 rock_detail = vec3(0.0, nx.y, nx.x) * weights.x
        + vec3(ny.x, 0.0, ny.y) * weights.y + vec3(nz.x, nz.y, 0.0) * weights.z;
    vec3 detail = mix(vec3(gn.x, 0.0, gn.y) * 0.42, rock_detail * 0.48, rock_weight);
    NORMAL = normalize(base + (detail - base * dot(detail, base)) * fine_fade * (1.0 - snow * 0.65));
    ROUGHNESS = clamp(0.90 + patch * 0.08 - rock_weight * 0.05, 0.84, 0.99);
    SPECULAR = 0.16;
    METALLIC = 0.0;
    AO = mix(0.79, 1.0, clamp(dot(broad_sample, vec3(0.333)) * 1.7, 0.0, 1.0));
}

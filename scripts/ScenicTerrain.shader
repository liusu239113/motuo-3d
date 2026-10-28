shader_type spatial;
render_mode shading_model_pbr, cull_back;

// 仅五张材质纹理，为移动前向环境反射保留槽位；全部复用现有资源。
uniform sampler2D grass_color : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D soil_color : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_color : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D ground_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_normal : hint_normal, filter_linear_mipmap, repeat_enable;

void fragment() {
    vec3 base_normal = normalize(NORMAL);
    vec3 weights = pow(abs(base_normal), vec3(4.0));
    weights /= max(weights.x + weights.y + weights.z, 0.001);
    float distance_to_eye = length(CAMERA_POSITION_WORLD - VERTEX);
    float near_detail = 1.0 - smoothstep(40.0, 100.0, distance_to_eye);
    // 草叶2米一张、土斑12.5米一张、宏观植被59米一张；三种尺度各司其职。
    vec2 ground_uv = VERTEX.xz * 0.50;
    vec3 grass_sample = texture(grass_color, ground_uv).rgb;
    vec3 broad_sample = texture(grass_color, VERTEX.xz * 0.017 + vec2(0.27, 0.63)).rgb;
    vec3 earth_patch = texture(soil_color, VERTEX.xz * 0.08 + vec2(0.19, 0.41)).rgb;
    vec3 earth = texture(soil_color, VERTEX.xz * 0.30).rgb;
    vec3 stone_x = texture(rock_color, VERTEX.zy * 0.15).rgb;
    vec3 stone_y = texture(rock_color, VERTEX.xz * 0.15).rgb;
    vec3 stone_z = texture(rock_color, VERTEX.xy * 0.15).rgb;
    vec3 stone = stone_x * weights.x + stone_y * weights.y + stone_z * weights.z;

    // 保留真实草叶细节，抑制原贴图过饱和的黄色花田观感。
    float blade = dot(grass_sample, vec3(0.2126, 0.7152, 0.0722));
    float broad = dot(broad_sample, vec3(0.2126, 0.7152, 0.0722));
    vec3 grass = mix(vec3(blade) * vec3(0.44, 0.59, 0.30), grass_sample * vec3(0.38, 0.48, 0.27), 0.22);
    grass *= mix(0.78, 1.22, clamp(broad * 1.8, 0.0, 1.0));
    earth = mix(vec3(dot(earth, vec3(0.3, 0.5, 0.2))), earth, 0.42) * vec3(0.62, 0.57, 0.48);
    stone = mix(vec3(dot(stone, vec3(0.3, 0.5, 0.2))), stone, 0.35) * vec3(0.67, 0.66, 0.62);

    float breakup = (earth.r - 0.18) * 0.12 + (broad - 0.3) * 0.06;
    float slope = 1.0 - base_normal.y;
    float rock_weight = smoothstep(0.13 + breakup, 0.42 + breakup, slope);
    rock_weight = max(rock_weight, smoothstep(180.0, 285.0, VERTEX.y) * 0.72);
    float patch_luma = dot(earth_patch, vec3(0.2126, 0.7152, 0.0722));
    float fine_luma = dot(earth, vec3(0.2126, 0.7152, 0.0722));
    // 真实土纹理决定破碎边界，不用随机色块；近景小范围露土，远处自然融回。
    float patch_mask = smoothstep(0.12, 0.30, patch_luma + fine_luma * 0.18);
    float soil_weight = smoothstep(0.025, 0.20, slope + breakup) * (1.0 - rock_weight) * 0.62;
    soil_weight = max(soil_weight, mix(0.035, 0.22, patch_mask) * near_detail * (1.0 - rock_weight));
    soil_weight = max(soil_weight, (1.0 - smoothstep(12.0, 17.0, VERTEX.y)) * 0.85);
    ALBEDO = mix(mix(grass, earth, soil_weight), stone, rock_weight);

    vec3 small_n = texture(ground_normal, ground_uv).rgb * 2.0 - 1.0;
    vec3 rock_n = texture(rock_normal, VERTEX.xz * 0.15).rgb * 2.0 - 1.0;
    vec2 detail = mix(small_n.xy * mix(0.12, 0.46, near_detail), rock_n.xy * 0.30, rock_weight);
    float distance_fade = 1.0 - smoothstep(90.0, 220.0, distance_to_eye);
    NORMAL = normalize(base_normal + vec3(detail.x, 0.0, detail.y) * distance_fade);
    ROUGHNESS = mix(0.95, 0.88, rock_weight);
    SPECULAR = 0.18;
    METALLIC = 0.0;
}

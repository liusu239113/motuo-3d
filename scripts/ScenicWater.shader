shader_type spatial;
render_mode shading_model_pbr, cull_back;

uniform sampler2D wave_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform samplerCube sky_environment : source_color, filter_linear_mipmap;
uniform float coast_water = 0.0;

void fragment() {
    vec2 uv_a = VERTEX.xz * 0.055 + TIME * vec2(0.012, 0.007);
    vec2 uv_b = VERTEX.zx * 0.089 + TIME * vec2(-0.008, 0.011);
    vec3 a = texture(wave_normal, uv_a).rgb * 2.0 - 1.0;
    vec3 b = texture(wave_normal, uv_b).rgb * 2.0 - 1.0;
    float distance_to_eye = length(CAMERA_POSITION_WORLD - VERTEX);
    float ripple = mix(0.12, 0.020, smoothstep(25.0, 220.0, distance_to_eye));
    vec3 water_normal = normalize(vec3((a.x + b.y) * ripple, 1.0, (a.y + b.x) * ripple));
    vec3 view_direction = normalize(CAMERA_POSITION_WORLD - VERTEX);
    float fresnel = 0.02 + 0.98 * pow(1.0 - clamp(dot(view_direction, water_normal), 0.0, 1.0), 5.0);
    vec3 reflection_direction = reflect(-view_direction, water_normal);
    vec3 environment = textureLod(sky_environment, reflection_direction, 2.5).rgb;
    float lake_radius = length((VERTEX.xz - vec2(-190.0, 190.0)) / vec2(160.0, 180.0));
    float lake_bank = max(0.0, (1.0 - lake_radius) * 160.0);
    float river_axis = -210.0 - 0.48 * (VERTEX.z - 200.0) + 24.0 * sin((VERTEX.z - 200.0) / 96.0);
    float river_bank = max(0.0, 11.0 + sin(VERTEX.z / 58.0) * 2.0 - abs(VERTEX.x - river_axis));
    float lake_water = 1.0 - step(325.0, VERTEX.z);
    float bank_distance = mix(river_bank, lake_bank, lake_water);
    // 岸线只影响水色与细小泡沫，不采屏幕深度、不增加透明排序和全屏开销。
    float coast_bank = max(0.0, -385.0 + 22.0 * sin(VERTEX.z / 170.0) - VERTEX.x);
    bank_distance = mix(bank_distance, coast_bank, coast_water);
    float shallow = 1.0 - smoothstep(0.6, 13.0, bank_distance);
    float wave = sin(bank_distance * 2.4 - TIME * 0.75 + sin(VERTEX.z * 0.13) * 0.6);
    float foam = (1.0 - smoothstep(0.2, 1.8, bank_distance)) * smoothstep(0.42, 0.95, wave);
    vec3 deep = mix(vec3(0.018, 0.073, 0.085), vec3(0.021, 0.098, 0.127), coast_water);
    vec3 near_bank = mix(vec3(0.065, 0.19, 0.16), vec3(0.09, 0.24, 0.23), coast_water);
    NORMAL = water_normal;
    ALBEDO = mix(mix(deep, near_bank, shallow * 0.72), vec3(0.39, 0.43, 0.39), foam * 0.35);
    RADIANCE = vec4(environment * mix(0.58, 0.92, fresnel), 1.0);
    METALLIC = 0.0;
    SPECULAR = 0.23;
    ROUGHNESS = mix(0.25, 0.38, smoothstep(35.0, 200.0, distance_to_eye)) + foam * 0.18;
}

shader_type spatial;
render_mode shading_model_pbr, cull_back;

uniform sampler2D wave_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform samplerCube sky_environment : source_color, filter_linear_mipmap;

void fragment() {
    vec2 uv_a = VERTEX.xz * 0.055 + TIME * vec2(0.012, 0.007);
    vec2 uv_b = VERTEX.zx * 0.089 + TIME * vec2(-0.008, 0.011);
    vec3 a = texture(wave_normal, uv_a).rgb * 2.0 - 1.0;
    vec3 b = texture(wave_normal, uv_b).rgb * 2.0 - 1.0;
    float distance_to_eye = length(CAMERA_POSITION_WORLD - VERTEX);
    float ripple = mix(0.14, 0.025, smoothstep(25.0, 220.0, distance_to_eye));
    vec3 water_normal = normalize(vec3((a.x + b.y) * ripple, 1.0, (a.y + b.x) * ripple));
    vec3 view_direction = normalize(CAMERA_POSITION_WORLD - VERTEX);
    float fresnel = 0.02 + 0.98 * pow(1.0 - clamp(dot(view_direction, water_normal), 0.0, 1.0), 5.0);
    vec3 reflection_direction = reflect(-view_direction, water_normal);
    vec3 environment = textureLod(sky_environment, reflection_direction, 2.0).rgb;

    NORMAL = water_normal;
    // 不透明浅水吸收色：不依赖屏幕抓取、SSR或延迟专属输入。
    ALBEDO = mix(vec3(0.018, 0.092, 0.103), vec3(0.045, 0.13, 0.14), 1.0 - fresnel);
    RADIANCE = vec4(environment * mix(0.7, 1.0, fresnel), 1.0);
    METALLIC = 0.0;
    SPECULAR = 0.25;
    // GGX粗糙度与远距法线衰减共同抑制亚像素密集闪点。
    ROUGHNESS = mix(0.24, 0.34, smoothstep(35.0, 200.0, distance_to_eye));
}

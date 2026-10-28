shader_type spatial;
render_mode shading_model_pbr, cull_back;

uniform sampler2D surface_color : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D surface_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 road_tint = vec3(0.26, 0.27, 0.28);
uniform float dirt_road = 0.0;

float road_noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = fract(sin(dot(i, vec2(127.1, 311.7))) * 43758.5453);
    float b = fract(sin(dot(i + vec2(1.0, 0.0), vec2(127.1, 311.7))) * 43758.5453);
    float c = fract(sin(dot(i + vec2(0.0, 1.0), vec2(127.1, 311.7))) * 43758.5453);
    float d = fract(sin(dot(i + vec2(1.0), vec2(127.1, 311.7))) * 43758.5453);
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void fragment() {
    vec3 base = normalize(NORMAL);
    vec2 uv = VERTEX.xz * mix(0.48, 0.62, dirt_road);
    vec3 texel = texture(surface_color, uv).rgb;
    float luma = dot(texel, vec3(0.2126, 0.7152, 0.0722));
    float macro = road_noise(VERTEX.xz * 0.075);
    float grain = road_noise(VERTEX.xz * 9.0);
    float repair = smoothstep(0.61, 0.79, road_noise(VERTEX.xz * 0.19 + vec2(7.4, 3.2)));
    float crack_field = road_noise(VERTEX.xz * 0.35);
    float crack = 1.0 - smoothstep(0.009, 0.022, abs(crack_field - 0.51));
    float fade = 1.0 - smoothstep(25.0, 100.0, length(CAMERA_POSITION_WORLD - VERTEX));
    vec3 aggregate = mix(vec3(luma), texel, dirt_road * 0.55);
    ALBEDO = aggregate * road_tint * mix(0.79, 1.14, macro)
        * mix(1.0, 0.77, repair) * mix(1.0, 0.60, crack * fade * (1.0 - dirt_road));
    ALBEDO *= 1.0 + (grain - 0.5) * fade * 0.16;
    vec3 n = texture(surface_normal, uv).rgb * 2.0 - 1.0;
    vec3 detail = vec3(n.x, 0.0, n.y);
    NORMAL = normalize(base + (detail - base * dot(detail, base)) * mix(0.28, 0.45, dirt_road) * fade);
    ROUGHNESS = clamp(0.87 + macro * 0.09 + grain * 0.03, 0.87, 0.99);
    METALLIC = 0.0;
    SPECULAR = mix(0.20, 0.12, dirt_road);
    AO = mix(1.0, 0.83, crack * fade);
}

shader_type spatial;
render_mode shading_model_pbr, cull_back;

uniform sampler2D surface_color : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D surface_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec3 tint = vec3(0.58, 0.51, 0.40);
uniform vec4 finish = vec4(0.93, 0.0, 0.20, 0.0); // 粗糙度、金属度、高光、木材

void fragment() {
    vec3 base = normalize(NORMAL);
    vec3 w = pow(abs(base), vec3(6.0));
    w /= max(w.x + w.y + w.z, 0.001);
    vec2 ux = VERTEX.zy * vec2(0.43, 0.43);
    vec2 uy = VERTEX.xz * vec2(0.43, 0.43);
    vec2 uz = VERTEX.xy * vec2(0.43, 0.43);
    vec3 texel = texture(surface_color, ux).rgb * w.x + texture(surface_color, uy).rgb * w.y
        + texture(surface_color, uz).rgb * w.z;
    float luma = dot(texel, vec3(0.2126, 0.7152, 0.0722));
    float weather = sin(VERTEX.x * 0.21 + sin(VERTEX.z * 0.17) + VERTEX.y * 0.31) * 0.5 + 0.5;
    float woodgrain = sin(VERTEX.y * 45.0 + sin(VERTEX.x * 9.0 + VERTEX.z * 11.0) * 2.0);
    ALBEDO = mix(vec3(luma), texel, 0.35) * tint * mix(0.82, 1.12, weather);
    ALBEDO *= 1.0 + woodgrain * finish.w * 0.055;
    vec3 nx = texture(surface_normal, ux).rgb * 2.0 - 1.0;
    vec3 ny = texture(surface_normal, uy).rgb * 2.0 - 1.0;
    vec3 nz = texture(surface_normal, uz).rgb * 2.0 - 1.0;
    vec3 detail = vec3(0.0, nx.y, nx.x) * w.x + vec3(ny.x, 0.0, ny.y) * w.y + vec3(nz.x, nz.y, 0.0) * w.z;
    float fade = 1.0 - smoothstep(35.0, 160.0, length(CAMERA_POSITION_WORLD - VERTEX));
    NORMAL = normalize(base + (detail - base * dot(detail, base)) * 0.30 * fade);
    ROUGHNESS = clamp(finish.x + (luma - 0.45) * 0.12, 0.55, 0.99);
    METALLIC = finish.y;
    SPECULAR = finish.z;
    AO = mix(0.86, 1.0, clamp(luma * 1.8, 0.0, 1.0));
}

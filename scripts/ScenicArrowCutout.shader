shader_type spatial;
render_mode shading_model_pbr, cull_back;

// 只兼容正式箭头原贴图；不生成几何、不替换颜色图或关闭阴影。
uniform sampler2D arrow_diffuse : source_color;
uniform sampler2D arrow_normal : hint_normal;
uniform vec4 arrow_tint = vec4(1.0);
uniform vec4 arrow_specular = vec4(0.0, 0.0, 0.0, 1.0);
uniform vec3 arrow_emission = vec3(0.0);
uniform float arrow_roughness = 0.5;
uniform float arrow_metallic = 0.0;

void fragment() {
    vec4 diffuse_sample = texture(arrow_diffuse, UV);
    vec2 rg = texture(arrow_normal, UV).rg;
    vec2 xy = rg * 2.0 - 1.0;
    float z = sqrt(max(1.0 - dot(xy, xy), 0.0));
    ALBEDO = diffuse_sample.rgb * arrow_tint.rgb;
    ALPHA = diffuse_sample.a;
    ALPHA_SCISSOR_THRESHOLD = 0.5;
    // 原PACKEDNORMAL以RG重建Z；SurfaceShader接收重新编码的RGB切线法线。
    NORMAL_MAP = vec3(rg, z * 0.5 + 0.5);
    ROUGHNESS = arrow_roughness;
    METALLIC = arrow_metallic;
    SPECULAR = max(arrow_specular.r, max(arrow_specular.g, arrow_specular.b));
    EMISSION = arrow_emission;
    AO = 1.0;
}

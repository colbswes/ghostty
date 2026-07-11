#include "common.glsl"

layout(location = 0) in vec2 center;
layout(location = 1) in vec2 size;
layout(location = 2) in float rotation;
layout(location = 3) in float alpha;
layout(location = 4) in uvec4 color;
layout(location = 5) in uint kind;
layout(location = 6) in float parameter;

out BackgroundEffectVertexOut {
    vec2 local;
    flat vec4 color;
    flat float alpha;
    flat uint kind;
    flat float parameter;
} out_data;

void main() {
    int vid = gl_VertexID;
    vec2 corner = vec2(
        (vid == 1 || vid == 3) ? 1.0 : -1.0,
        (vid == 2 || vid == 3) ? 1.0 : -1.0
    );
    float cs = cos(rotation);
    float sn = sin(rotation);
    vec2 local_pos = corner * size * 0.5;
    vec2 pixel_pos = center + vec2(
        local_pos.x * cs - local_pos.y * sn,
        local_pos.x * sn + local_pos.y * cs
    );

    gl_Position = vec4(
        pixel_pos.x / screen_size.x * 2.0 - 1.0,
        1.0 - pixel_pos.y / screen_size.y * 2.0,
        0.0,
        1.0
    );
    out_data.local = corner;
    out_data.color = load_color(
        color,
        (bools & USE_LINEAR_BLENDING) != 0
    );
    out_data.alpha = alpha;
    out_data.kind = kind;
    out_data.parameter = parameter;
}

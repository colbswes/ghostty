#include "common.glsl"

layout(binding = 0) uniform sampler2D effect_texture;
layout(location = 0) out vec4 out_FragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / screen_size;
    out_FragColor = texture(effect_texture, uv);
}

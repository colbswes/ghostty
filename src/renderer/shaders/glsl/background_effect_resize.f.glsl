#include "common.glsl"

layout(binding = 0) uniform sampler2D effect_texture;
layout(location = 0) out vec4 out_FragColor;

void main() {
    vec2 source_size = vec2(textureSize(effect_texture, 0));
    // OpenGL framebuffer coordinates start at the bottom. Offset Y so the
    // terminal's top-left stays fixed when the pane height changes.
    vec2 source_pixel = vec2(
        gl_FragCoord.x,
        gl_FragCoord.y + source_size.y - screen_size.y
    );
    if (any(lessThan(source_pixel, vec2(0.0))) ||
        any(greaterThanEqual(source_pixel, source_size))) {
        out_FragColor = vec4(0.0);
        return;
    }
    out_FragColor = texture(effect_texture, source_pixel / source_size);
}

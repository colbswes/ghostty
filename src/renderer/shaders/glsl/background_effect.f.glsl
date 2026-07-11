#version 430 core

in BackgroundEffectVertexOut {
    vec2 local;
    flat vec4 color;
    flat float alpha;
    flat uint kind;
    flat float parameter;
} in_data;

layout(location = 0) out vec4 out_FragColor;

void main() {
    float coverage = 0.0;
    if (in_data.kind == 0u || in_data.kind == 2u) {
        coverage = 1.0 - smoothstep(0.72, 1.0, length(in_data.local));
    } else if (in_data.kind == 1u) {
        coverage = (1.0 - smoothstep(0.55, 1.0, abs(in_data.local.y))) *
            smoothstep(-1.0, 1.0, in_data.local.x);
    } else if (in_data.kind == 3u) {
        float shape = sqrt(abs(in_data.local.x)) + sqrt(abs(in_data.local.y));
        coverage = 1.0 - smoothstep(0.92, 1.05, shape);
    } else if (in_data.kind == 4u) {
        float d = length(in_data.local);
        coverage = d < 0.4
            ? mix(1.0, 0.3, d / 0.4)
            : 0.3 * (1.0 - smoothstep(0.4, 1.0, d));
    } else if (in_data.kind == 5u) {
        float spacing = in_data.parameter;
        vec2 cell = mod(gl_FragCoord.xy, spacing);
        cell = min(cell, spacing - cell);
        coverage = 1.0 - smoothstep(0.75, 1.25, length(cell));
    } else if (in_data.kind == 6u) {
        float spacing = in_data.parameter;
        vec2 cell = mod(gl_FragCoord.xy, spacing);
        cell = min(cell, spacing - cell);
        coverage = 1.0 - smoothstep(0.5, 1.25, min(cell.x, cell.y));
    } else if (in_data.kind == 7u) {
        coverage = 1.0 - smoothstep(0.72, 1.0, length(in_data.local));
    }
    float alpha = in_data.alpha * coverage;
    // Ember glows and cores (kinds 4 and 7) blend additively, matching the
    // canvas `lighter` compositing in the reference implementation. With
    // premultiplied one/one-minus-src-alpha blending, writing zero alpha
    // leaves the destination intact so the color is purely added.
    float dst_alpha = (in_data.kind == 4u || in_data.kind == 7u) ? 0.0 : alpha;
    out_FragColor = vec4(in_data.color.rgb * alpha, dst_alpha);
}

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
        float d = length(in_data.local);
        float aa = fwidth(d);
        coverage = 1.0 - smoothstep(1.0 - aa, 1.0, d);
    } else if (in_data.kind == 1u) {
        float edge = abs(in_data.local.y);
        float cross_coverage = 1.0 - smoothstep(1.0 - fwidth(edge), 1.0, edge);
        coverage = cross_coverage * clamp((in_data.local.x + 1.0) * 0.5, 0.0, 1.0);
    } else if (in_data.kind == 3u) {
        float shape = sqrt(abs(in_data.local.x)) + sqrt(abs(in_data.local.y));
        coverage = 1.0 - smoothstep(0.92, 1.05, shape);
    } else if (in_data.kind == 4u) {
        float d = length(in_data.local);
        coverage = d < 0.4
            ? mix(1.0, 0.3, d / 0.4)
            : mix(0.3, 0.0, clamp((d - 0.4) / 0.6, 0.0, 1.0));
    } else if (in_data.kind == 5u) {
        float spacing = in_data.parameter;
        vec2 cell = mod(gl_FragCoord.xy, spacing);
        cell = min(cell, spacing - cell);
        float d = length(cell);
        float radius = spacing / 20.0;
        coverage = 1.0 - smoothstep(radius - fwidth(d), radius, d);
    } else if (in_data.kind == 6u) {
        float spacing = in_data.parameter;
        vec2 cell = mod(gl_FragCoord.xy, spacing);
        cell = min(cell, spacing - cell);
        float half_width = spacing / 48.0;
        float x_coverage = 1.0 - smoothstep(half_width - fwidth(cell.x), half_width, cell.x);
        float y_coverage = 1.0 - smoothstep(half_width - fwidth(cell.y), half_width, cell.y);
        coverage = x_coverage + y_coverage - in_data.alpha * x_coverage * y_coverage;
    } else if (in_data.kind == 7u) {
        float d = length(in_data.local);
        coverage = 1.0 - smoothstep(1.0 - fwidth(d), 1.0, d);
    } else if (in_data.kind == 8u) {
        float edge = abs(in_data.local.y);
        // A constellation link is one physical pixel at normal Retina scale.
        // Half a derivative gives the Canvas-style half-pixel edge ramp while
        // preserving full coverage at the center of that single-pixel quad.
        float aa = 0.5 * fwidth(edge);
        coverage = 1.0 - smoothstep(1.0 - aa, 1.0, edge);
    }
    float alpha = in_data.alpha * coverage;
    out_FragColor = vec4(in_data.color.rgb * alpha, alpha);
}

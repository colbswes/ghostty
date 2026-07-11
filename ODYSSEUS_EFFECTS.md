# Native Odysseus background effects

This fork ports the original canvas effects from
`~/workplace/odysseus/static/js/theme.js` into Ghostty's native renderer.
They are drawn after the base terminal background and before explicit cell
backgrounds, Kitty graphics, and text.

Choose one effect in the Ghostty config:

```ini
background-effect = perlin-flow
background-effect-color = #9cdef2
background-effect-intensity = 0.8
background-effect-size = 1
background-effect-fps = 60
```

Valid effects are:

```text
none
dots
synapse
rain
constellations
perlin-flow
petals
sparkles
embers
```

`background-effect-color` is optional and defaults to the terminal foreground.
Intensity is clamped to `0...1`, size to `0.2...3`, and FPS to `1...120`.

Unlike Ghostty custom shaders, the animated effects keep the original small
particle simulation as CPU state and upload analytic point/line/shape instances
in one draw call. They do not run an integration loop for every screen pixel.
Dots is static after its initial frame; the animated effects are independently
frame-capped even on a 120 Hz display.

The fork also bundles every theme defined by the original Odysseus theme
picker. Select one by name in the Ghostty config, for example:

```ini
theme = Odysseus Terminal
```

The bundled themes are Dark, Light, Midnight, Paper, Cyberpunk, Retrowave,
Forest, Ocean, Ume, Copper, Terminal, Organs, Lavender, GPT, Claude, and Cute.
Each theme keeps its original palette and default background effect.

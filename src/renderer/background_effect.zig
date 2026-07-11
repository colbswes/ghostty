const std = @import("std");

pub const Effect = enum {
    dots,
    synapse,
    rain,
    constellations,
    @"perlin-flow",
    petals,
    sparkles,
    embers,
};

pub const PrimitiveKind = enum(u8) {
    disc,
    line,
    ellipse,
    star,
    glow,
    dots,
    grid,
    /// Additively-blended disc, used for the white-hot ember cores. The
    /// reference implementation draws embers with canvas `lighter`
    /// compositing; `glow` and `core` reproduce that in the shader.
    core,
    /// Long, tapered, additive streak aligned opposite an ember's velocity.
    /// The retained radial stamps provide haze; this primitive makes the tail
    /// visibly read as a tail even at the reference's slow particle speeds.
    ember_trail,
};

/// One instanced quad. The fragment shader turns the quad into the requested
/// analytic shape, so none of these effects require a full-screen shader pass.
pub const Primitive = extern struct {
    center: [2]f32 align(8),
    size: [2]f32 align(8),
    rotation: f32 align(4),
    alpha: f32 align(4),
    color: [4]u8 align(4),
    kind: PrimitiveKind align(1),
    parameter: f32 align(4) = 0,
};

/// Native ports of the canvas effects in Odysseus `static/js/theme.js`.
/// Simulation values below intentionally mirror the original JS constants.
pub const State = struct {
    pub const max_primitives = 42_000;
    pub const frame_interval_ns = std.time.ns_per_s / 60;

    /// Trail lengths, in simulation steps. Embers reconstruct the reference
    /// canvas's short 18%-per-frame fade. Perlin flow intentionally keeps its
    /// entire retained window at full strength so Terminal develops the dense,
    /// persistent green field of the Odysseus presentation instead of looking
    /// like a handful of short comet tails.
    pub const ember_trail_len = 24;
    pub const flow_trail_len = 192;

    effect: Effect,
    primitives: [max_primitives]Primitive = undefined,
    primitive_count: usize = 0,
    width: f32 = 0,
    height: f32 = 0,
    pixel_scale: f32 = 1,
    tick: f32 = 0,
    step_counter: u32 = 0,
    last_step: ?std.time.Instant = null,
    last_draw: ?std.time.Instant = null,
    prng: std.Random.DefaultPrng,

    pulses: [20]Pulse = undefined,
    pulse_count: usize = 0,
    drops: [130]Drop = undefined,
    drop_count: usize = 0,
    stars: [50]Star = undefined,
    petals: [30]Petal = undefined,
    sparkles: [35]Sparkle = undefined,
    embers: [140]Ember = undefined,
    ember_count: usize = 0,
    ember_alive: usize = 0,
    ember_history: [140][ember_trail_len]TrailSample = undefined,
    ember_history_head: usize = 0,
    flow: [200]FlowParticle = undefined,
    flow_history: [200][flow_trail_len]TrailSample = undefined,
    flow_history_head: usize = 0,

    const Pulse = struct { pos: [2]f32, velocity: [2]f32 };
    const Drop = struct { x: f32, y: f32, len: f32, speed: f32, alpha: f32 };
    const Star = struct { pos: [2]f32, velocity: [2]f32, radius: f32, phase: f32 };
    const Petal = struct {
        pos: [2]f32,
        size: f32,
        rotation: f32,
        rotation_velocity: f32,
        velocity_y: f32,
        drift: f32,
        drift_speed: f32,
        wobble: f32,
    };
    const Sparkle = struct { pos: [2]f32, size: f32, phase: f32, speed: f32, life: f32 };
    const Ember = struct {
        pos: [2]f32,
        velocity: [2]f32,
        radius: f32,
        life: f32,
        max_life: f32,
        wobble: f32,
        spark: bool,
        /// Dead embers stop moving and recording, but their trail keeps
        /// rendering until it fades out, like the persistent canvas in
        /// the reference implementation.
        alive: bool,
    };
    const FlowParticle = struct { pos: [2]f32, life: f32 };
    /// One persisted trail stamp. `step` is the step_counter value at the
    /// time of recording (0 = never written); a sample is only valid while
    /// its ring position still matches its age, which lets stale entries
    /// from idle (dead) slots expire instead of re-rendering on wraparound.
    const TrailSample = struct { pos: [2]f32, strength: f32, radius: f32, step: u32 };

    pub fn create(alloc: std.mem.Allocator, effect: Effect) !*State {
        const self = try alloc.create(State);
        errdefer alloc.destroy(self);
        const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
        self.* = .{ .effect = effect, .prng = .init(seed) };
        return self;
    }

    pub fn destroy(self: *State, alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }

    pub fn animated(self: *const State) bool {
        return self.effect != .dots;
    }

    pub fn frameDue(self: *const State, now: std.time.Instant, fps: u8) bool {
        const last = self.last_draw orelse return true;
        if (!self.animated()) return false;
        const interval = std.time.ns_per_s / @max(@as(u64, fps), 1);
        const tolerance = @min(2 * std.time.ns_per_ms, interval / 10);
        return now.since(last) + tolerance >= interval;
    }

    pub fn current(self: *const State) []const Primitive {
        return self.primitives[0..self.primitive_count];
    }

    pub fn update(
        self: *State,
        now: std.time.Instant,
        width: usize,
        height: usize,
        pixel_scale: f32,
        rgb: [3]u8,
        intensity: f32,
        size: f32,
    ) []const Primitive {
        const w: f32 = @floatFromInt(width);
        const h: f32 = @floatFromInt(height);
        if (self.width != w or self.height != h or self.pixel_scale != pixel_scale) {
            self.reset(w, h, pixel_scale);
        }
        self.last_draw = now;

        const elapsed_ns = if (self.last_step) |last|
            @min(now.since(last), 4 * frame_interval_ns)
        else
            frame_interval_ns;
        self.last_step = now;
        const frame_scale = @as(f32, @floatFromInt(elapsed_ns)) /
            @as(f32, @floatFromInt(frame_interval_ns));
        self.tick += frame_scale;

        if (self.animated()) self.step(@max(frame_scale, 0.01), intensity);
        self.rebuild(.{ rgb[0], rgb[1], rgb[2], 255 }, intensity, size);
        return self.current();
    }

    fn reset(self: *State, width: f32, height: f32, pixel_scale: f32) void {
        self.width = width;
        self.height = height;
        self.pixel_scale = pixel_scale;
        self.primitive_count = 0;
        self.last_step = null;
        self.tick = 0;
        self.step_counter = 0;
        const random = self.prng.random();

        switch (self.effect) {
            .dots => {},
            .synapse => self.pulse_count = 0,
            .rain => self.drop_count = 0,
            .constellations => {
                for (&self.stars) |*s| s.* = .{
                    .pos = .{ random.float(f32) * width, random.float(f32) * height },
                    .velocity = .{ (random.float(f32) - 0.5) * 0.15 * pixel_scale, (random.float(f32) - 0.5) * 0.15 * pixel_scale },
                    .radius = (0.8 + random.float(f32) * 0.8) * pixel_scale,
                    .phase = random.float(f32) * std.math.pi * 2,
                };
            },
            .@"perlin-flow" => {
                self.flow_history_head = 0;
                for (&self.flow_history) |*trail| {
                    for (trail) |*sample| sample.step = 0;
                }
                for (&self.flow) |*p| p.* = .{
                    .pos = .{ random.float(f32) * width, random.float(f32) * height },
                    .life = random.float(f32),
                };
            },
            .petals => {
                for (&self.petals) |*p| {
                    p.* = self.makePetal(random);
                    p.pos[1] = random.float(f32) * height;
                }
            },
            .sparkles => {
                for (&self.sparkles) |*s| s.* = self.makeSparkle(random);
            },
            .embers => {
                // The browser version fluctuates above its 70-particle floor
                // as five-particle bursts overlap. Start at that denser visual
                // steady state so a fresh terminal doesn't look empty.
                self.ember_count = 90;
                self.ember_alive = 90;
                self.ember_history_head = 0;
                for (&self.ember_history) |*trail| {
                    for (trail) |*sample| sample.step = 0;
                }
                for (self.embers[0..self.ember_count]) |*e| {
                    e.* = self.makeEmber(random);
                    e.pos[1] = random.float(f32) * height;
                    e.life = random.float(f32) * e.max_life;
                }
            },
        }
    }

    fn step(self: *State, dt: f32, intensity: f32) void {
        switch (self.effect) {
            .dots => {},
            .synapse => self.stepSynapse(dt),
            .rain => self.stepRain(dt, intensity),
            .constellations => self.stepConstellations(dt),
            .@"perlin-flow" => self.stepPerlin(dt),
            .petals => self.stepPetals(dt),
            .sparkles => self.stepSparkles(dt),
            .embers => self.stepEmbers(dt),
        }
    }

    fn rebuild(self: *State, color: [4]u8, intensity: f32, size: f32) void {
        self.primitive_count = 0;
        switch (self.effect) {
            .dots => self.add(.{
                .center = .{ self.width / 2, self.height / 2 },
                .size = .{ self.width, self.height },
                .rotation = 0,
                .alpha = 0.05 * intensity,
                .color = color,
                .kind = .dots,
                .parameter = 20 * self.pixel_scale,
            }),
            .synapse => self.buildSynapse(color, intensity),
            .rain => self.buildRain(color, intensity, size),
            .constellations => self.buildConstellations(color, intensity, size),
            .@"perlin-flow" => self.buildPerlin(color, intensity, size),
            .petals => self.buildPetals(color, intensity, size),
            .sparkles => self.buildSparkles(color, intensity, size),
            .embers => self.buildEmbers(color, intensity, size),
        }
    }

    fn stepSynapse(self: *State, dt: f32) void {
        const random = self.prng.random();
        if (self.pulse_count < self.pulses.len and random.float(f32) < 0.12 * dt) {
            const grid = 24 * self.pixel_scale;
            const speed = (2 + random.float(f32) * 20) * self.pixel_scale;
            if (random.boolean()) {
                const rows = @ceil(self.height / grid);
                self.pulses[self.pulse_count] = .{
                    .pos = .{ -12 * self.pixel_scale, @floor(random.float(f32) * (rows + 1)) * grid },
                    .velocity = .{ speed, 0 },
                };
            } else {
                const cols = @ceil(self.width / grid);
                self.pulses[self.pulse_count] = .{
                    .pos = .{ @floor(random.float(f32) * (cols + 1)) * grid, -12 * self.pixel_scale },
                    .velocity = .{ 0, speed },
                };
            }
            self.pulse_count += 1;
        }

        var i: usize = 0;
        while (i < self.pulse_count) {
            self.pulses[i].pos[0] += self.pulses[i].velocity[0] * dt;
            self.pulses[i].pos[1] += self.pulses[i].velocity[1] * dt;
            if (self.pulses[i].pos[0] > self.width + 12 * self.pixel_scale or
                self.pulses[i].pos[1] > self.height + 12 * self.pixel_scale)
            {
                self.pulse_count -= 1;
                self.pulses[i] = self.pulses[self.pulse_count];
            } else i += 1;
        }
    }

    fn buildSynapse(self: *State, color: [4]u8, intensity: f32) void {
        self.add(.{
            .center = .{ self.width / 2, self.height / 2 },
            .size = .{ self.width, self.height },
            .rotation = 0,
            .alpha = 0.035 * intensity,
            .color = color,
            .kind = .grid,
            .parameter = 24 * self.pixel_scale,
        });
        const trail = 12 * self.pixel_scale;
        for (self.pulses[0..self.pulse_count]) |p| {
            const tail: [2]f32 = .{
                p.pos[0] - (if (p.velocity[0] > 0) trail else 0),
                p.pos[1] - (if (p.velocity[1] > 0) trail else 0),
            };
            self.addLine(tail, p.pos, self.pixel_scale, 0.35 * intensity, color);
            self.addDisc(p.pos, 1.2 * self.pixel_scale, 0.55 * intensity, color, .disc);
        }
    }

    fn stepRain(self: *State, dt: f32, intensity: f32) void {
        const random = self.prng.random();
        const max_drops: usize = @intFromFloat(@floor(@as(f32, 130) * std.math.clamp(intensity, 0, 1)));
        if (self.drop_count < max_drops and random.float(f32) < 0.6 * intensity * dt) {
            const len = (20 + random.float(f32) * 40) * self.pixel_scale;
            self.drops[self.drop_count] = .{
                .x = random.float(f32) * self.width,
                .y = -len,
                .len = len,
                .speed = (4 + random.float(f32) * 8) * self.pixel_scale,
                .alpha = 0.32 + random.float(f32) * 0.28,
            };
            self.drop_count += 1;
        }
        const speed_mult = 0.35 + intensity * 0.65;
        var i: usize = 0;
        while (i < self.drop_count) {
            self.drops[i].y += self.drops[i].speed * speed_mult * dt;
            if (self.drops[i].y > self.height + self.drops[i].len) {
                self.drop_count -= 1;
                self.drops[i] = self.drops[self.drop_count];
            } else i += 1;
        }
    }

    fn buildRain(self: *State, color: [4]u8, intensity: f32, size: f32) void {
        for (self.drops[0..self.drop_count]) |d| {
            const len = d.len * size;
            self.addLine(.{ d.x, d.y - len }, .{ d.x, d.y }, 1.3 * self.pixel_scale * std.math.clamp(size, 0.6, 2), d.alpha * intensity, color);
        }
    }

    fn stepConstellations(self: *State, dt: f32) void {
        for (&self.stars) |*s| {
            s.pos[0] += s.velocity[0] * dt;
            s.pos[1] += s.velocity[1] * dt;
            if (s.pos[0] < 0) s.pos[0] = self.width;
            if (s.pos[0] > self.width) s.pos[0] = 0;
            if (s.pos[1] < 0) s.pos[1] = self.height;
            if (s.pos[1] > self.height) s.pos[1] = 0;
        }
    }

    fn buildConstellations(self: *State, color: [4]u8, intensity: f32, size: f32) void {
        const connect_dist = 120 * self.pixel_scale * size;
        for (self.stars, 0..) |a, i| for (self.stars[i + 1 ..]) |b| {
            const dx = a.pos[0] - b.pos[0];
            const dy = a.pos[1] - b.pos[1];
            const dist = @sqrt(dx * dx + dy * dy);
            if (dist < connect_dist) self.addLine(a.pos, b.pos, 0.5 * self.pixel_scale, (1 - dist / connect_dist) * 0.15 * intensity, color);
        };
        for (self.stars) |s| {
            const twinkle = 0.5 + 0.5 * @sin(self.tick * 0.02 + s.phase);
            self.addDisc(s.pos, s.radius * size, (0.15 + twinkle * 0.25) * intensity, color, .disc);
        }
    }

    fn stepPerlin(self: *State, dt: f32) void {
        self.bumpStepCounter();
        self.flow_history_head = (self.flow_history_head + 1) % flow_trail_len;
        const random = self.prng.random();
        for (&self.flow, 0..) |*p, i| {
            const n = smoothNoise(p.pos[0] / self.pixel_scale * 0.004 + self.tick * 0.0008, p.pos[1] / self.pixel_scale * 0.004 + 100);
            const angle = n * std.math.pi * 6;
            const speed = (1 + smoothNoise(p.pos[0] / self.pixel_scale * 0.003, p.pos[1] / self.pixel_scale * 0.003 + 50) * 1.5) * self.pixel_scale;
            p.pos[0] += @cos(angle) * speed * dt;
            p.pos[1] += @sin(angle) * speed * dt;
            p.life -= 0.001 * dt;
            if (p.life <= 0 or p.pos[0] < 0 or p.pos[0] > self.width or p.pos[1] < 0 or p.pos[1] > self.height) {
                // The old trail samples stay in the ring and keep fading;
                // on the reference's persistent canvas a respawn does not
                // erase the trail left behind.
                p.pos = .{ random.float(f32) * self.width, random.float(f32) * self.height };
                p.life = 1;
            }
            self.flow_history[i][self.flow_history_head] = .{ .pos = p.pos, .strength = p.life * 0.15, .radius = self.pixel_scale, .step = self.step_counter };
        }
    }

    fn buildPerlin(self: *State, color: [4]u8, intensity: f32, size: f32) void {
        for (0..self.flow.len) |particle_i| {
            for (0..flow_trail_len) |age| {
                const sample = self.flow_history[particle_i][(self.flow_history_head + flow_trail_len - age) % flow_trail_len];
                if (self.sampleValid(sample, age)) {
                    self.addDisc(
                        sample.pos,
                        sample.radius * size,
                        sample.strength * intensity,
                        color,
                        .disc,
                    );
                }
            }
        }
    }

    fn makePetal(self: *State, random: std.Random) Petal {
        return .{
            .pos = .{ random.float(f32) * self.width, (-10 - random.float(f32) * 40) * self.pixel_scale },
            .size = (3 + random.float(f32) * 5) * self.pixel_scale,
            .rotation = random.float(f32) * std.math.pi * 2,
            .rotation_velocity = (random.float(f32) - 0.5) * 0.03,
            .velocity_y = (0.3 + random.float(f32) * 0.6) * self.pixel_scale,
            .drift = random.float(f32) * std.math.pi * 2,
            .drift_speed = 0.008 + random.float(f32) * 0.012,
            .wobble = (0.3 + random.float(f32) * 0.8) * self.pixel_scale,
        };
    }

    fn stepPetals(self: *State, dt: f32) void {
        const random = self.prng.random();
        for (&self.petals) |*p| {
            p.pos[1] += p.velocity_y * dt;
            p.rotation += p.rotation_velocity * dt;
            p.drift += p.drift_speed * dt;
            p.pos[0] += @sin(p.drift) * p.wobble * dt;
            if (p.pos[1] > self.height + 15 * self.pixel_scale) p.* = self.makePetal(random);
        }
    }

    fn buildPetals(self: *State, color: [4]u8, intensity: f32, size: f32) void {
        for (self.petals) |p| {
            const offset = rotate(.{ p.size * 0.2 * size, 0 }, p.rotation);
            self.addEllipse(.{ p.pos[0] - offset[0], p.pos[1] - offset[1] }, .{ p.size * 1.2 * size, p.size * 0.6 * size }, p.rotation + 0.3, 0.2 * intensity, color);
            self.addEllipse(.{ p.pos[0] + offset[0], p.pos[1] + offset[1] }, .{ p.size * 1.2 * size, p.size * 0.6 * size }, p.rotation - 0.3, 0.15 * intensity, color);
        }
    }

    fn makeSparkle(self: *State, random: std.Random) Sparkle {
        return .{
            .pos = .{ random.float(f32) * self.width, random.float(f32) * self.height },
            .size = (2 + random.float(f32) * 5) * self.pixel_scale,
            .phase = random.float(f32) * std.math.pi * 2,
            .speed = 0.015 + random.float(f32) * 0.03,
            .life = 0.5 + random.float(f32) * 0.5,
        };
    }

    fn stepSparkles(self: *State, dt: f32) void {
        const random = self.prng.random();
        for (&self.sparkles) |*s| {
            s.phase += s.speed * dt;
            if (s.phase > std.math.pi * 6) s.* = self.makeSparkle(random);
        }
    }

    fn buildSparkles(self: *State, color: [4]u8, intensity: f32, size: f32) void {
        for (self.sparkles) |s| {
            const twinkle = @sin(s.phase);
            const positive = @max(0, twinkle);
            const alpha = positive * 0.25 * s.life * intensity;
            if (alpha > 0.01) {
                const radius = s.size * (0.5 + positive * 0.5) * size;
                self.add(.{ .center = s.pos, .size = .{ radius * 2, radius * 2 }, .rotation = 0, .alpha = alpha, .color = color, .kind = .star });
            }
        }
    }

    fn makeEmber(self: *State, random: std.Random) Ember {
        return .{
            .pos = .{ random.float(f32) * self.width, self.height + random.float(f32) * 40 * self.pixel_scale },
            .velocity = .{ (random.float(f32) - 0.5) * 0.3 * self.pixel_scale, (-0.3 - random.float(f32) * 0.8) * self.pixel_scale },
            .radius = (0.3 + random.float(f32) * 0.6) * self.pixel_scale,
            .life = 0,
            .max_life = 220 + random.float(f32) * 220,
            .wobble = random.float(f32) * std.math.pi * 2,
            .spark = false,
            .alive = true,
        };
    }

    fn stepEmbers(self: *State, dt: f32) void {
        self.bumpStepCounter();
        self.ember_history_head = (self.ember_history_head + 1) % ember_trail_len;
        const random = self.prng.random();
        for (self.embers[0..self.ember_count], 0..) |*e, i| {
            if (!e.alive) continue;
            e.wobble += 0.03 * dt;
            e.pos[0] += (e.velocity[0] + @sin(e.wobble) * 0.5 * self.pixel_scale) * dt;
            e.pos[1] += e.velocity[1] * dt;
            e.life += dt;
            if (e.life > e.max_life or e.pos[1] < -20 * self.pixel_scale) {
                // Slots stay put so the dead ember's trail keeps fading
                // in place. Respawn in the same slot unless we're over
                // the steady-state population from a recent burst.
                if (self.ember_alive - 1 < 100) {
                    e.* = self.makeEmber(random);
                } else {
                    e.alive = false;
                    self.ember_alive -= 1;
                }
                continue;
            }
            if (!e.spark and random.float(f32) < 0.003 * dt) e.spark = true;
            const ratio = e.life / e.max_life;
            const fade = @min(1, @min(ratio * 4, (1 - ratio) * 3));
            const radius = e.radius * (if (e.spark) @as(f32, 2.4) else 1);
            const alpha = (if (e.spark) @as(f32, 0.9) else 0.55) * fade;
            self.ember_history[i][self.ember_history_head] = .{ .pos = e.pos, .strength = alpha, .radius = radius, .step = self.step_counter };
            e.spark = false;
        }
        if (random.float(f32) < 0.015 * dt) {
            const bx = random.float(f32) * self.width;
            var slot: usize = 0;
            for (0..5) |_| {
                const idx = idx: {
                    while (slot < self.ember_count) : (slot += 1) {
                        if (!self.embers[slot].alive) break :idx slot;
                    }
                    if (self.ember_count >= self.embers.len) return;
                    defer self.ember_count += 1;
                    break :idx self.ember_count;
                };
                var e = self.makeEmber(random);
                e.pos[0] = bx + (random.float(f32) - 0.5) * 40 * self.pixel_scale;
                e.pos[1] = self.height - 10 * self.pixel_scale;
                e.velocity[1] *= 1.5;
                self.embers[idx] = e;
                self.ember_alive += 1;
            }
        }
    }

    fn buildEmbers(self: *State, color: [4]u8, intensity: f32, size: f32) void {
        // Draw one explicit tapered streak per live ember. Reconstructing only
        // the browser's fading radial stamps makes slow embers look like dots,
        // because consecutive stamps overlap almost completely.
        for (self.embers[0..self.ember_count]) |e| {
            if (!e.alive) continue;

            const ratio = e.life / e.max_life;
            const life_fade = @min(1, @min(ratio * 4, (1 - ratio) * 3));
            if (life_fade <= 0) continue;

            const velocity = [2]f32{
                e.velocity[0] + @sin(e.wobble) * 0.5 * self.pixel_scale,
                e.velocity[1],
            };
            const speed = @sqrt(velocity[0] * velocity[0] + velocity[1] * velocity[1]);
            if (speed <= 0.001) continue;

            const direction = [2]f32{ velocity[0] / speed, velocity[1] / speed };
            const tail_length = (42 * self.pixel_scale + speed * 30) * size;
            const tail = [2]f32{
                e.pos[0] - direction[0] * tail_length,
                e.pos[1] - direction[1] * tail_length,
            };
            self.addLineKind(
                tail,
                e.pos,
                @max(e.radius * 6 * size, 1.5 * self.pixel_scale),
                0.7 * life_fade * intensity,
                color,
                .ember_trail,
            );
        }

        for (0..self.ember_count) |ember_i| {
            var fade: f32 = 1;
            for (0..ember_trail_len) |age| {
                const sample = self.ember_history[ember_i][(self.ember_history_head + ember_trail_len - age) % ember_trail_len];
                if (self.sampleValid(sample, age)) {
                    self.addDisc(sample.pos, sample.radius * 4.5 * size, sample.strength * 1.2 * fade * intensity, color, .glow);
                    self.addDisc(sample.pos, sample.radius * 0.6 * size, sample.strength * 0.8 * fade * intensity, .{ 255, 255, 255, 255 }, .core);
                }
                fade *= 0.82;
            }
        }
    }

    fn bumpStepCounter(self: *State) void {
        self.step_counter +%= 1;
        if (self.step_counter == 0) self.step_counter = 1;
    }

    /// A ring sample is valid while its recorded step still matches its
    /// position-implied age; slots that stopped recording (dead embers)
    /// hold stale samples that must not re-render once the head wraps.
    fn sampleValid(self: *const State, sample: TrailSample, age: usize) bool {
        return sample.step != 0 and
            sample.step +% @as(u32, @truncate(age)) == self.step_counter;
    }

    fn add(self: *State, primitive: Primitive) void {
        if (self.primitive_count >= self.primitives.len) return;
        self.primitives[self.primitive_count] = primitive;
        self.primitive_count += 1;
    }

    fn addDisc(self: *State, center: [2]f32, radius: f32, alpha: f32, color: [4]u8, kind: PrimitiveKind) void {
        self.add(.{ .center = center, .size = .{ radius * 2, radius * 2 }, .rotation = 0, .alpha = alpha, .color = color, .kind = kind });
    }

    fn addEllipse(self: *State, center: [2]f32, size: [2]f32, rotation: f32, alpha: f32, color: [4]u8) void {
        self.add(.{ .center = center, .size = size, .rotation = rotation, .alpha = alpha, .color = color, .kind = .ellipse });
    }

    fn addLine(self: *State, from: [2]f32, to: [2]f32, width: f32, alpha: f32, color: [4]u8) void {
        self.addLineKind(from, to, width, alpha, color, .line);
    }

    fn addLineKind(self: *State, from: [2]f32, to: [2]f32, width: f32, alpha: f32, color: [4]u8, kind: PrimitiveKind) void {
        const dx = to[0] - from[0];
        const dy = to[1] - from[1];
        self.add(.{
            .center = .{ (from[0] + to[0]) / 2, (from[1] + to[1]) / 2 },
            .size = .{ @sqrt(dx * dx + dy * dy), @max(width, 1) },
            .rotation = std.math.atan2(dy, dx),
            .alpha = alpha,
            .color = color,
            .kind = kind,
        });
    }
};

fn rotate(v: [2]f32, angle: f32) [2]f32 {
    const c = @cos(angle);
    const s = @sin(angle);
    return .{ v[0] * c - v[1] * s, v[0] * s + v[1] * c };
}

fn noise2d(x: f32, y: f32) f32 {
    const n = @sin(x * 12.9898 + y * 78.233) * 43758.5453;
    return n - @floor(n);
}

fn smoothNoise(x: f32, y: f32) f32 {
    const ix = @floor(x);
    const iy = @floor(y);
    const fx = x - ix;
    const fy = y - iy;
    const a = noise2d(ix, iy);
    const b = noise2d(ix + 1, iy);
    const c = noise2d(ix, iy + 1);
    const d = noise2d(ix + 1, iy + 1);
    const ux = fx * fx * (3 - 2 * fx);
    const uy = fy * fy * (3 - 2 * fy);
    return a + (b - a) * ux + (c - a) * uy + (a - b - c + d) * ux * uy;
}

test "all Odysseus effects produce bounded primitive counts" {
    inline for (std.meta.tags(Effect)) |effect| {
        var state = try State.create(std.testing.allocator, effect);
        defer state.destroy(std.testing.allocator);
        const now = try std.time.Instant.now();
        const primitives = state.update(now, 1600, 1200, 2, .{ 156, 222, 242 }, 1, 1);
        try std.testing.expect(primitives.len > 0 or effect == .rain);
        try std.testing.expect(primitives.len <= State.max_primitives);
    }
}

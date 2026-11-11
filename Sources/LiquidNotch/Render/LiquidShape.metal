// Liquid Notch: the whole liquid surface in one fragment pass.
//
// Coordinates are in points, origin at the panel's top-left, y pointing down.
// y = 0 is the top edge of the screen (the bezel). Everything above it is off-glass.
//
// The surface is a signed distance field built from:
//   notch   - rounded rect matching the physical notch (always present, it is hardware)
//   main    - rounded rect with superellipse corners; it extends above y = 0 so its
//             top corners are never on glass
//   drop    - ellipse, the second activity
//   neck    - capsule from the main blob to the drop: the liquid bridge
//   bezel   - the half-plane above the screen; merging into it makes the blob flare
//             out of the bezel instead of meeting it at a hard corner
//   card    - the open island card below the notch, joined only through its own bridge
//             (its merge k collapses with the bridge, so nothing webs across the gap)
// combined with polynomial smooth-min. The aura is drawn from the same distance value.
//
// Keep in sync with ShapeSDF.swift (CPU mirror used for hit testing).

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 view;    // size.x, size.y, backing scale, edge feather (px)
    float4 notch;   // half width, height, corner radius, unused
    float4 mainB;   // half width, height, corner radius, corner exponent
    float4 drop;    // center.x, center.y, radius.x, radius.y
    float4 merge;   // k notch/main, k drop, k bezel, neck radius
    float4 glow;    // intensity, falloff (pt), dither amount, unused
    float4 aura;    // rgb (sRGB-encoded), unused
    float4 fill;    // rgb (sRGB-encoded) of the liquid, unused. Always black in the app.
    float4 card;    // half width, top, height, radius
    float4 card2;   // card bridge radius, ear glow offset while open, card x offset, notch-liquid x offset
    float4 pulse;   // event pulse: rgb, amount (0.4 fading to 0)
    float4 hair;    // hairline: amount (white opacity), width (px)
    float4 extra1;  // the left ball: center.x, center.y, radius, merge k with the ears (0 once apart)
    float4 extra2;  // the +N ball: the same, merging with the right ball
};

struct VOut { float4 position [[position]]; };

vertex VOut liquid_vertex(uint vid [[vertex_id]]) {
    // One triangle that covers the whole viewport.
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.position = float4(p * float2(2, -2) + float2(-1, 1), 0, 1);
    return o;
}

// Polynomial smooth-min (quadratic). k is the width of the blend in points;
// two shapes stay joined while the gap between them is below k / 2.
static float smin(float a, float b, float k) {
    if (k <= 1e-4) return min(a, b);
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

// Rounded box whose corners are superellipses |x|^n + |y|^n = r^n.
// n = 2 is a circular corner; n > 2 has zero curvature where the corner meets the
// straight edge (curvature-continuous, the "continuous corner" look).
// Not an exact distance outside the corners, which is fine: AA uses fwidth, and the
// aura only needs a smooth monotonic falloff.
static float sdRoundBox(float2 p, float2 b, float r, float n) {
    r = min(r, min(b.x, b.y));
    float2 q = abs(p) - b + r;
    float2 m = max(q, 0.0);
    float outside = (n == 2.0) ? length(m) : powr(powr(m.x, n) + powr(m.y, n), 1.0 / n);
    return outside + min(max(q.x, q.y), 0.0) - r;
}

// Ellipse approximation (iq). Good to well under a point for the mild
// stretch the drop uses.
static float sdEllipse(float2 p, float2 r) {
    float k0 = length(p / r);
    float k1 = length(p / (r * r));
    return k1 > 1e-5 ? k0 * (k0 - 1.0) / k1 : -min(r.x, r.y);
}

static float sdSegment(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-5), 0.0, 1.0);
    return length(pa - ba * h);
}

// How far above y = 0 the top-anchored boxes extend, so their top corners stay off glass.
constant float kTopExtension = 64.0;

struct Field { float fill; float blob; float glow; };

static Field liquidField(float2 p, constant Uniforms &u) {
    float cx = u.view.x * 0.5;

    float nh = u.notch.y;
    float dNotch = sdRoundBox(p - float2(cx, (nh - kTopExtension) * 0.5),
                              float2(u.notch.x, (nh + kTopExtension) * 0.5),
                              u.notch.z, 2.0);

    float mh = u.mainB.y;
    float dMain = sdRoundBox(p - float2(cx + u.card2.w, (mh - kTopExtension) * 0.5),
                             float2(u.mainB.x, (mh + kTopExtension) * 0.5),
                             u.mainB.z, u.mainB.w);

    float d = smin(dNotch, dMain, u.merge.x);

    float2 dr = u.drop.zw;
    if (min(dr.x, dr.y) > 0.05) {
        float2 dc = u.drop.xy;
        d = smin(d, sdEllipse(p - dc, dr), u.merge.y);

        // The neck merges with a k that shrinks with it, so a vanishing neck
        // leaves no fillet behind (otherwise the shape would pop when it is removed).
        // The drop leaves sideways from the right ear, so the neck starts just inside
        // the ear's end, level with the drop.
        float neck = u.merge.w;
        if (neck > 0.05) {
            float2 a = float2(cx + u.mainB.x - neck, dc.y);
            float dNeck = sdSegment(p, a, dc) - neck;
            d = smin(d, dNeck, min(u.merge.y, neck * 3.0));
        }
    }

    // More balls (11-06): each blends with its neighbour only while they touch.
    for (int i = 0; i < 2; i++) {
        float4 e = i == 0 ? u.extra1 : u.extra2;
        if (e.z > 0.05) d = smin(d, length(p - e.xy) - e.z, e.w);
    }

    float glowD = d;
    if (u.card.x > 0.5 && u.card.z > 0.5) {
        float rest = d;
        float dCard = sdRoundBox(p - float2(cx + u.card2.z, u.card.y + u.card.z * 0.5),
                                 float2(u.card.x, u.card.z * 0.5), u.card.w, u.mainB.w);
        float cn = u.card2.x;
        // The card merges only through its bridge: the blend collapses with it, so once the
        // bridge has snapped nothing webs across the gap, whatever the droplet's k is.
        float kc = min(u.merge.y, cn * 3.0);
        if (cn > 0.05) {
            // Vertical bridge from the bottom of the notch to the top of the card.
            float dBridge = sdSegment(p, float2(cx + u.card2.w, mh - cn), float2(cx + u.card2.z, u.card.y + cn)) - cn;
            dCard = smin(dCard, dBridge, kc);
        }
        d = smin(d, dCard, kc);
        // While the card is open the light comes from it; the ears glow less.
        glowD = u.card2.y > 0.0 ? min(dCard, rest + u.card2.y) : d;
    }

    Field f;
    f.blob = d;
    f.glow = glowD;
    // The bezel is the half-plane y < 0, whose distance is simply y.
    f.fill = smin(d, p.y, u.merge.z);
    return f;
}

static float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

fragment float4 liquid_fragment(VOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float scale = u.view.z;
    float2 p = in.position.xy / scale;
    Field f = liquidField(p, u);

    // Analytic coverage: the field's screen-space derivative makes the edge exactly
    // `feather` pixels wide whatever the field's gradient is.
    float px = max(fwidth(f.fill), 1e-4) * max(u.view.w, 0.25);
    float coverage = saturate(0.5 - f.fill / px);

    // Aura: light falling off with distance from the liquid (not from the bezel,
    // or the whole top edge would glow). Dither breaks up 8-bit banding.
    float g = u.glow.x * exp(-max(f.glow, 0.0) / max(u.glow.y, 0.1));
    g += (hash12(in.position.xy) - 0.5) * u.glow.z * step(1e-3, u.glow.x);
    g = saturate(g) * (1.0 - coverage);
    // Event pulse: a colour flash on the bloom.
    float gp = u.pulse.w * exp(-max(f.glow, 0.0) / 34.0) * (1.0 - coverage);

    // Premultiplied output.
    float3 rgb = u.fill.rgb * coverage + u.aura.rgb * g + u.pulse.rgb * gp;
    float a = coverage + g + gp;
    if (u.hair.x > 0.0) {
        // A hairline centred on the edge, hair.y px wide.
        float line = u.hair.x * saturate(1.0 - abs(f.fill / px) / max(u.hair.y, 0.5)) * step(0.5, p.y);
        rgb += float3(line);
        a = max(a, line);
    }
    return float4(rgb, min(a, 1.0));
}

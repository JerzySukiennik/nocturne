// Nocturne: Metal Core Image kernels, compiled at runtime so the offline Metal toolchain is not needed.
import CoreImage

enum KernelSource {
    static let metal = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    static inline float nocLuma(float3 c) {
        return dot(c, float3(0.2290, 0.6917, 0.0793));
    }

    static inline float3 nocHue(float h) {
        float3 k = fract(float3(h) + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0;
        return clamp(abs(k) - 1.0, 0.0, 1.0);
    }

    static inline float nocCurve(float v, float k) {
        const float p = 0.46;
        if (v >= 1.0) { return v; }
        if (v < p) { return p * pow(max(v, 0.0) / p, k); }
        return 1.0 - (1.0 - p) * pow((1.0 - v) / (1.0 - p), k);
    }

    [[stitchable]] float4 nocLight(coreimage::sample_t s, coreimage::sample_t soft, float exposure, float contrast, float highlights, float shadows, float whites, float blacks) {
        float gain = exp2(exposure);
        float3 c = max(s.rgb, 0.0) * gain;
        float local = mix(nocLuma(c), nocLuma(max(soft.rgb, 0.0)) * gain, 0.7);
        float lg = pow(clamp(local, 0.0, 1.0), 1.0 / 2.2);
        float ms = pow(1.0 - lg, 2.5);
        float mh = lg * lg * lg;
        c *= exp2(shadows * 1.7 * ms + highlights * 1.5 * mh);
        float3 v = pow(max(c, 0.0), float3(1.0 / 2.2));
        float bp = -blacks * 0.12;
        float wp = 1.0 - whites * 0.25;
        v = (v - bp) / max(wp - bp, 0.05);
        float k = exp2(contrast);
        v = float3(nocCurve(v.r, k), nocCurve(v.g, k), nocCurve(v.b, k));
        return float4(pow(max(v, 0.0), float3(2.2)), s.a);
    }

    [[stitchable]] float4 nocColor(coreimage::sample_t s, float temperature, float tint, float vibrance, float saturation) {
        float3 c = max(s.rgb, 0.0);
        float3 g = float3(exp2(0.45 * temperature), exp2(-0.30 * tint), exp2(-0.45 * temperature));
        g /= nocLuma(g);
        c *= g;
        float l = nocLuma(c);
        float mx = max(c.r, max(c.g, c.b));
        float mn = min(c.r, min(c.g, c.b));
        float sat = mx > 0.00001 ? (mx - mn) / mx : 0.0;
        float vib = vibrance >= 0.0 ? vibrance * (1.0 - sat) : vibrance;
        float k = max(0.0, (1.0 + saturation) * (1.0 + vib));
        c = mix(float3(l), c, k);
        return float4(max(c, 0.0), s.a);
    }

    [[stitchable]] float4 nocGrade(coreimage::sample_t s, float shadowHue, float shadowAmount, float highlightHue, float highlightAmount, float balance) {
        float3 c = max(s.rgb, 0.0);
        float l = pow(clamp(nocLuma(c), 0.0, 1.0), 1.0 / 2.2);
        float pivot = 0.5 - balance * 0.3;
        float w = smoothstep(pivot - 0.35, pivot + 0.35, l);
        float3 gs = mix(float3(1.0), nocHue(shadowHue), shadowAmount * 0.6 * (1.0 - w));
        float3 gh = mix(float3(1.0), nocHue(highlightHue), highlightAmount * 0.6 * w);
        float3 g = gs * gh;
        g /= max(nocLuma(g), 0.0001);
        return float4(c * g, s.a);
    }

    [[stitchable]] float4 nocVignette(coreimage::sample_t s, float2 center, float2 halfSize, float amount, float size, coreimage::destination dest) {
        float2 d = (dest.coord() - center) / halfSize;
        float r = length(d) / 1.41421356;
        float inner = mix(0.10, 0.80, size);
        float m = smoothstep(inner, 1.05, r);
        return float4(s.rgb * exp2(amount * 2.2 * m), s.a);
    }

    [[stitchable]] float4 nocMist(coreimage::sample_t s, coreimage::sample_t soft, float amount) {
        float3 c = max(s.rgb, 0.0);
        float3 g = max(soft.rgb, 0.0);
        float3 o = mix(c, g, amount * 0.34) + max(g - 0.5, 0.0) * amount * 0.75;
        return float4(o, s.a);
    }

    [[stitchable]] float4 nocSplash(coreimage::sample_t s, float hue, float range, float amount) {
        float3 c = max(s.rgb, 0.0);
        float3 v = pow(min(c, 4.0), float3(1.0 / 2.2));
        float mx = max(v.r, max(v.g, v.b));
        float mn = min(v.r, min(v.g, v.b));
        float d = mx - mn;
        float sat = mx > 0.0001 ? d / mx : 0.0;
        float h = 0.0;
        if (d > 0.00001) {
            if (mx == v.r) { h = (v.g - v.b) / d; }
            else if (mx == v.g) { h = 2.0 + (v.b - v.r) / d; }
            else { h = 4.0 + (v.r - v.g) / d; }
            h = fract(h / 6.0);
        }
        float dist = abs(h - hue);
        dist = min(dist, 1.0 - dist);
        float keep = (1.0 - smoothstep(range * 0.5, range * 0.5 + 0.045, dist)) * smoothstep(0.06, 0.2, sat);
        float3 o = mix(float3(nocLuma(c)), c, keep);
        return float4(mix(c, o, amount), s.a);
    }

    [[stitchable]] float4 nocHigh(coreimage::sample_t s, float threshold) {
        float3 c = max(s.rgb, 0.0);
        float w = smoothstep(threshold, threshold + 0.35, nocLuma(c));
        return float4(min(c, 4.0) * w, 1.0);
    }

    [[stitchable]] float4 nocGlow(coreimage::sample_t s, coreimage::sample_t g, float4 tint, float amount) {
        return float4(max(s.rgb, 0.0) + max(g.rgb, 0.0) * tint.rgb * amount, s.a);
    }

    [[stitchable]] float4 nocFringe(coreimage::sample_t s, coreimage::sample_t r, coreimage::sample_t b) {
        return float4(r.r, s.g, b.b, s.a);
    }

    [[stitchable]] float4 nocFocus(coreimage::sample_t d, float focus, float range) {
        float m = smoothstep(range, range + 0.3, abs(d.r - focus));
        return float4(m, m, m, 1.0);
    }

    [[stitchable]] float4 nocRelight(coreimage::sample_t s, coreimage::sample_t light, float ambient) {
        float3 c = max(s.rgb, 0.0);
        return float4(c * (exp2(ambient) + max(light.rgb, 0.0)), s.a);
    }

    [[stitchable]] float4 nocLamp(coreimage::sampler depth, float2 light, float lz, float relief, float radius, float4 color, float intensity, float shadow, coreimage::destination dest) {
        float2 p = dest.coord();
        const float e = 1.5;
        float d0 = depth.sample(depth.transform(p)).r;
        float h = d0 * relief;
        float hl = depth.sample(depth.transform(p - float2(e, 0.0))).r * relief;
        float hr = depth.sample(depth.transform(p + float2(e, 0.0))).r * relief;
        float hd = depth.sample(depth.transform(p - float2(0.0, e))).r * relief;
        float hu = depth.sample(depth.transform(p + float2(0.0, e))).r * relief;
        float3 n = normalize(float3(hl - hr, hd - hu, 2.0 * e));
        float3 pos = float3(p, h);
        float3 v = float3(light, lz) - pos;
        float dist = length(v);
        float3 ld = v / max(dist, 0.001);
        float diffuse = clamp((dot(n, ld) + 0.25) / 1.25, 0.0, 1.0);
        float far = length(float3(v.xy, v.z * 2.5));
        float atten = 1.0 / (1.0 + (far * far) / (radius * radius));
        float occ = 0.0;
        float jitter = fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
        for (int i = 0; i < 28; i++) {
            float t = (float(i) + 0.3 + jitter) / 29.0;
            float3 q = pos + v * t;
            float dz = depth.sample(depth.transform(q.xy)).r * relief - q.z;
            float block = smoothstep(0.0, 0.05 * relief, dz) * (1.0 - smoothstep(0.07 * relief, 0.14 * relief, dz));
            occ = max(occ, block * (1.0 - t * 0.6));
        }
        float reach = smoothstep(0.004, 0.02, d0);
        float back = smoothstep(0.0, 0.08 * relief, -v.z);
        float rim = back * pow(clamp(1.0 - n.z, 0.0, 1.0), 1.4) * 2.2;
        float lit = intensity * (diffuse * (1.0 - occ * shadow) + rim) * atten * reach;
        return float4(color.rgb * lit, 1.0);
    }

    [[stitchable]] float4 nocMatch(coreimage::sample_t s, float4 luma, float4 ss, float4 st, float4 ms, float4 mt, float4 hs, float4 ht, float amount) {
        const float3 wgt = float3(0.2290, 0.6917, 0.0793);
        float3 c = max(s.rgb, 0.0);
        float3 v = pow(min(c, 4.0), float3(1.0 / 2.2));
        float y = dot(v, wgt);
        float2 ch = float2(v.b - y, v.r - y);
        float yc = clamp(y, 0.0, 1.0);
        float ws = 1.0 - smoothstep(0.15, 0.45, yc);
        float wh = smoothstep(0.55, 0.85, yc);
        float wm = 1.0 - ws - wh;
        float2 ks = mix(float2(1.0), clamp(st.zw / max(ss.zw, 0.004), 0.6, 1.8), 0.7);
        float2 km = mix(float2(1.0), clamp(mt.zw / max(ms.zw, 0.004), 0.6, 1.8), 0.7);
        float2 kh = mix(float2(1.0), clamp(ht.zw / max(hs.zw, 0.004), 0.6, 1.8), 0.7);
        float2 cc = ((ch - ss.xy) * ks + st.xy) * ws + ((ch - ms.xy) * km + mt.xy) * wm + ((ch - hs.xy) * kh + ht.xy) * wh;
        float ky = clamp(luma.w / max(luma.y, 0.02), 0.7, 1.4);
        float y2 = mix(y, (y - luma.x) * ky + luma.z, 0.6);
        float r = y2 + cc.y;
        float b = y2 + cc.x;
        float g = (y2 - wgt.r * r - wgt.b * b) / wgt.g;
        float3 o = pow(max(float3(r, g, b), 0.0), float3(2.2));
        return float4(mix(c, o, amount), s.a);
    }

    [[stitchable]] float4 nocStep(coreimage::sample_t d, float lo, float hi, float invert) {
        float m = smoothstep(lo, hi, d.r);
        m = mix(m, 1.0 - m, invert);
        return float4(m, m, m, 1.0);
    }

    [[stitchable]] float4 nocGrain(coreimage::sample_t s, coreimage::sample_t n, float amount) {
        float3 c = max(s.rgb, 0.0);
        float l = pow(clamp(nocLuma(c), 0.0, 1.0), 1.0 / 2.2);
        float w = 0.35 + 0.65 * (4.0 * l * (1.0 - l));
        float g = (n.r + n.g + n.b) / 3.0 - 0.5;
        float3 v = pow(c, float3(1.0 / 2.2)) + g * amount * 0.45 * w;
        return float4(pow(max(v, 0.0), float3(2.2)), s.a);
    }
    """
}

final class Kernels {
    let light: CIColorKernel
    let color: CIColorKernel
    let grade: CIColorKernel
    let vignette: CIColorKernel
    let mist: CIColorKernel
    let grain: CIColorKernel
    let match: CIColorKernel
    let splash: CIColorKernel
    let high: CIColorKernel
    let glow: CIColorKernel
    let fringe: CIColorKernel
    let focus: CIColorKernel
    let relight: CIColorKernel
    let lamp: CIKernel
    let step: CIColorKernel

    init() throws {
        let all = try CIKernel.kernels(withMetalString: KernelSource.metal)
        func pick(_ name: String) throws -> CIColorKernel {
            guard let k = all.first(where: { $0.name == name }) as? CIColorKernel else {
                throw EngineError.kernel(name)
            }
            return k
        }
        light = try pick("nocLight")
        color = try pick("nocColor")
        grade = try pick("nocGrade")
        vignette = try pick("nocVignette")
        mist = try pick("nocMist")
        grain = try pick("nocGrain")
        match = try pick("nocMatch")
        splash = try pick("nocSplash")
        high = try pick("nocHigh")
        glow = try pick("nocGlow")
        fringe = try pick("nocFringe")
        focus = try pick("nocFocus")
        relight = try pick("nocRelight")
        guard let lampKernel = all.first(where: { $0.name == "nocLamp" }) else { throw EngineError.kernel("nocLamp") }
        lamp = lampKernel
        step = try pick("nocStep")
    }
}

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
    }
}

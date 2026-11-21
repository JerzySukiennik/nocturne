// Nocturne: match a reference. Measures the look of an image (tone plus color per shadow, midtone and highlight zone) and builds a step that moves a photo toward it.
import CoreImage
import Foundation

extension Engine {
    public func lookStats(_ image: CIImage) -> [Double]? {
        let small = scaled(image, maxEdge: 160)
        let w = Int(small.extent.width)
        let h = Int(small.extent.height)
        guard w > 4, h > 4 else { return nil }
        var pixels = [Float](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { raw in
            context.render(small, toBitmap: raw.baseAddress!, rowBytes: w * 16,
                           bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: working)
        }
        var ySum = 0.0, y2Sum = 0.0
        var zw = [Double](repeating: 0, count: 3)
        var zcb = [Double](repeating: 0, count: 3), zcr = [Double](repeating: 0, count: 3)
        var zcb2 = [Double](repeating: 0, count: 3), zcr2 = [Double](repeating: 0, count: 3)
        let n = Double(w * h)
        func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
        for i in 0..<(w * h) {
            let r = pow(Double(min(max(pixels[i * 4], 0), 4)), 1 / 2.2)
            let g = pow(Double(min(max(pixels[i * 4 + 1], 0), 4)), 1 / 2.2)
            let b = pow(Double(min(max(pixels[i * 4 + 2], 0), 4)), 1 / 2.2)
            let y = 0.2290 * r + 0.6917 * g + 0.0793 * b
            let cb = b - y
            let cr = r - y
            ySum += y
            y2Sum += y * y
            let yc = min(max(y, 0), 1)
            let ws = 1 - smooth(0.15, 0.45, yc)
            let wh = smooth(0.55, 0.85, yc)
            let weights = [ws, 1 - ws - wh, wh]
            for z in 0..<3 {
                let k = weights[z]
                zw[z] += k
                zcb[z] += k * cb
                zcr[z] += k * cr
                zcb2[z] += k * cb * cb
                zcr2[z] += k * cr * cr
            }
        }
        let yMean = ySum / n
        let yStd = max(y2Sum / n - yMean * yMean, 0).squareRoot()
        let allW = zw.reduce(0, +)
        let gcb = zcb.reduce(0, +) / allW
        let gcr = zcr.reduce(0, +) / allW
        let gcbStd = max(zcb2.reduce(0, +) / allW - gcb * gcb, 0).squareRoot()
        let gcrStd = max(zcr2.reduce(0, +) / allW - gcr * gcr, 0).squareRoot()
        var out = [yMean, yStd]
        for z in 0..<3 {
            if zw[z] < n * 0.02 {
                out += [gcb, gcr, gcbStd, gcrStd]
            } else {
                let mcb = zcb[z] / zw[z]
                let mcr = zcr[z] / zw[z]
                out += [mcb, mcr, max(zcb2[z] / zw[z] - mcb * mcb, 0).squareRoot(), max(zcr2[z] / zw[z] - mcr * mcr, 0).squareRoot()]
            }
        }
        return out
    }

    public func matchStep(reference: CIImage, current: CIImage) -> Step? {
        guard let target = lookStats(reference), let source = lookStats(current) else { return nil }
        return Step(kind: .match, name: "Match Reference", data: source + target)
    }

    public func adapted(_ recipe: Recipe, to source: CIImage, masks: MaskSet?) -> Recipe {
        var out = Recipe()
        for step in recipe.steps where step.kind != .cleanup {
            var next = step.fresh()
            if next.kind == .match, let data = next.data, data.count == Step.matchCount {
                let before = render(source, recipe: out, masks: masks)
                if let stats = lookStats(before) {
                    next.data = stats + Array(data[14...])
                }
            }
            out.steps.append(next)
        }
        return out
    }
}

import Foundation

enum ChartYDomain {
    /// Returns a y-domain padded slightly above and below the data range,
    /// snapped to a "nice" interval for clean tick labels.
    /// Empty or flat data → 0...1 (Charts default-ish).
    static func niceDomain(for values: [Double], paddingFraction: Double = 0.1) -> ClosedRange<Double> {
        guard let lo = values.min(), let hi = values.max(), hi > lo else {
            return 0...max(1, values.first ?? 1)
        }
        let span = hi - lo
        let pad = max(span * paddingFraction, 1)
        let low = (lo - pad).rounded(.down)
        let high = (hi + pad).rounded(.up)
        return low...high
    }

    /// For metrics that anchor at zero (steps, active minutes, sleep duration).
    static func zeroAnchored(for values: [Double], paddingFraction: Double = 0.1) -> ClosedRange<Double> {
        guard let hi = values.max(), hi > 0 else { return 0...1 }
        let pad = hi * paddingFraction
        return 0...((hi + pad).rounded(.up))
    }
}

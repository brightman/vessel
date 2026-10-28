import SwiftUI

/// The production “Witness” icon, drawn as a vector so it can animate on Watch.
struct WiseLifeSpiral: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 649.240, y: 228.468))
        let curves: [(Double, Double, Double, Double, Double, Double)] = [
            (689.409,252.425,723.306,285.002,748.171,322.478),
            (773.036,359.954,788.853,402.269,794.805,445.037),
            (800.757,487.804,796.856,530.965,784.248,570.383),
            (771.640,609.802,750.361,645.431,723.149,674.189),
            (695.937,702.946,662.842,724.808,627.525,738.278),
            (592.207,751.748,554.721,756.827,518.843,753.778),
            (482.965,750.730,448.742,739.578,419.297,722.149),
            (389.852,704.720,365.215,681.054,347.282,654.036),
            (329.349,627.019,318.128,596.698,314.008,566.336),
            (309.889,535.975,312.856,505.618,321.855,478.203),
            (330.854,450.788,345.852,426.348,364.703,406.919),
            (383.553,387.491,406.215,373.088,430.005,364.510),
            (453.795,355.932,478.673,353.173,502.043,355.754),
            (525.413,358.336,547.243,366.234,565.566,377.930),
            (583.890,389.626,598.693,405.085,608.996,422.193),
            (619.299,439.300,625.105,458.019,626.527,476.173)
        ]
        for c in curves {
            path.addCurve(to: CGPoint(x: c.4, y: c.5),
                          control1: CGPoint(x: c.0, y: c.1), control2: CGPoint(x: c.2, y: c.3))
        }
        let scale = min(rect.width, rect.height) / 640
        return path.applying(CGAffineTransform(translationX: -234, y: -174)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.midX - 320 * scale, y: rect.midY - 320 * scale)))
    }
}

struct WiseLifeMark: View {
    var ink: Color = Color(red: 0.91, green: 0.95, blue: 0.94)
    var gold: Color = Color(red: 0.86, green: 0.75, blue: 0.49)
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            ZStack {
                WiseLifeSpiral().stroke(ink, style: StrokeStyle(lineWidth: size * 0.112, lineCap: .round))
                Circle().fill(gold).frame(width: size * 0.105, height: size * 0.105)
                    .position(x: geometry.size.width / 2 - size * 0.066,
                              y: geometry.size.height / 2 + size * 0.028)
            }
        }
        .accessibilityHidden(true)
    }
}

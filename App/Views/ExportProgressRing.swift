import SwiftUI

/// The toolbar's export progress: a thin ring that fills like a pie, in the same primary style as the toolbar
/// symbols. The native circular `ProgressView` draws in the accent color and at another size than those symbols.
struct ExportProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().strokeBorder(.primary, lineWidth: 1.5)
            ExportProgressPie(fraction: min(max(fraction, 0), 1))
                .fill(.primary)
                .padding(3)
        }
        .frame(width: 18, height: 18)
        .padding(.horizontal, 6)
        .animation(.linear(duration: 0.15), value: fraction)
    }
}

private struct ExportProgressPie: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: center)
        path.addArc(
            center: center, radius: min(rect.width, rect.height) / 2, startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        path.closeSubpath()
        return path
    }
}

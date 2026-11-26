import SwiftUI

/// Dew's mark: a blue drop and its soft reflection.
/// Static and simple on purpose, for the new tab page.
struct DewMark: View {
    /// Width of the drop; everything else scales from it.
    var size: CGFloat = 44

    static let top = Color(red: 0.38, green: 0.66, blue: 1.0)      // #62A8FF
    static let bottom = Color(red: 0.18, green: 0.37, blue: 0.92)  // #2D5FEA
    private var fill: LinearGradient { LinearGradient(colors: [Self.top, Self.bottom], startPoint: .top, endPoint: .bottom) }

    var body: some View {
        let dropHeight = size * 1.32
        VStack(spacing: size * 0.16) {
            DropShape()
                .fill(fill)
                .frame(width: size, height: dropHeight)
                .overlay(alignment: .topLeading) {
                    Capsule()
                        .fill(.white.opacity(0.5))
                        .frame(width: size * 0.14, height: size * 0.28)
                        .rotationEffect(.degrees(-24))
                        .offset(x: size * 0.24, y: dropHeight * 0.52)
                }
            DropShape()
                .fill(fill)
                .frame(width: size, height: dropHeight)
                .scaleEffect(x: 1, y: -1)
                .opacity(0.3)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.5)))
                .frame(height: dropHeight * 0.55, alignment: .top)
                .clipped()
        }
        .accessibilityHidden(true)
    }
}

/// A teardrop with its tip at the top, filling `rect` (round part at the bottom).
struct DropShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.width / 2
        let center = CGPoint(x: rect.midX, y: rect.maxY - radius)
        let tip = CGPoint(x: rect.midX, y: rect.minY)
        let shoulder = center.y - tip.y
        var path = Path()
        path.move(to: tip)
        path.addCurve(to: CGPoint(x: rect.maxX, y: center.y),
                      control1: CGPoint(x: center.x + radius * 0.3, y: tip.y + shoulder * 0.28),
                      control2: CGPoint(x: rect.maxX, y: center.y - shoulder * 0.38))
        path.addArc(center: center, radius: radius, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        path.addCurve(to: tip,
                      control1: CGPoint(x: rect.minX, y: center.y - shoulder * 0.38),
                      control2: CGPoint(x: center.x - radius * 0.3, y: tip.y + shoulder * 0.28))
        path.closeSubpath()
        return path
    }
}

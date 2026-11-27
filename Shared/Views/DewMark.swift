import SwiftUI

/// Dew's mark: a drop and its soft reflection, in the style of the chosen app icon. `lift` raises the drop off
/// the "water" and lowers its reflection by the same amount (a mirror), fading it as the gap grows.
struct DewMark: View {
    enum Style {
        case classic, ink, bead, halo

        /// The drop for an app icon choice (`AppIconChoice`'s raw value), so the widget can match the app icon too.
        init(appIcon: String) {
            switch appIcon {
            case "ink": self = .ink
            case "bead": self = .bead
            case "haloDark", "haloLight": self = .halo
            default: self = .classic
            }
        }
    }

    /// Width of the drop; everything else scales from it.
    var size: CGFloat = 44
    var style: Style = .classic
    var lift: CGFloat = 0

    static let top = Color(red: 0.38, green: 0.66, blue: 1.0)      // #62A8FF
    static let bottom = Color(red: 0.18, green: 0.37, blue: 0.92)  // #2D5FEA
    /// The Halo icons' rainbow, clockwise from the top (as in Tools/AppIcon-Halo*.svg).
    static let halo = AngularGradient(
        colors: [0xFF5E3A, 0xFFAA28, 0xD6DE3C, 0x50C878, 0x28AAE6, 0x466EF0, 0x965AF0, 0xF050AA, 0xFF5E3A].map { hex in
            Color(red: Double(hex >> 16) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        },
        center: UnitPoint(x: 0.5, y: 0.52), startAngle: .degrees(-90), endAngle: .degrees(270))

    var body: some View {
        let dropHeight = size * 1.32
        VStack(spacing: size * 0.16) {
            drop.frame(width: size, height: dropHeight)
                .offset(y: -lift)
            drop.frame(width: size, height: dropHeight)
                .scaleEffect(x: 1, y: -1)
                .opacity(0.3 * max(0, 1 - lift / (size * 1.4)))
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.5)))
                .offset(y: lift)
                .frame(height: dropHeight * 0.55, alignment: .top)
                .clipped()
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var drop: some View {
        switch style {
        case .classic:
            DropShape()
                .fill(LinearGradient(colors: [Self.top, Self.bottom], startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .topLeading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(.white.opacity(0.5))
                            .frame(width: proxy.size.width * 0.14, height: proxy.size.width * 0.28)
                            .rotationEffect(.degrees(-24))
                            .offset(x: proxy.size.width * 0.24, y: proxy.size.height * 0.52)
                    }
                }
        case .ink:
            DropShape().fill(.primary)
        case .halo:
            // The Halo icons: just the drop's rainbow outline, so it suits light and dark pages alike.
            // Drawn inside the shape, so the reflection's clip never cuts the outline.
            DropShape().strokeBorder(Self.halo, style: StrokeStyle(lineWidth: size * 0.17, lineJoin: .round))
        case .bead:
            // The Bead icon: the drop with a small bead cut out near the bottom left.
            DropShape().fill(.primary)
                .mask {
                    GeometryReader { proxy in
                        let r = proxy.size.width * 0.112
                        Rectangle()
                            .overlay {
                                Circle().frame(width: r * 2, height: r * 2)
                                    .position(x: proxy.size.width * 0.335, y: proxy.size.height * 0.846)
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                    }
                }
        }
    }
}

/// The mark dropping in with a subtle bounce (new tab page), its reflection following; pointing at it bounces it
/// again. Still when Reduce Motion is on.
struct BouncingDewMark: View {
    var size: CGFloat
    var style: DewMark.Style
    @State private var lift: CGFloat = 26
    @State private var bouncing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DewMark(size: size, style: style, lift: reduceMotion ? 0 : lift)
            .contentShape(Rectangle())
            .onAppear(perform: fall)
            .onHover { hovering in
                guard hovering, !bouncing else { return }
                bouncing = true
                withAnimation(.easeOut(duration: 0.16)) { lift = 26 } completion: { fall() }
            }
    }

    private func fall() {
        lift = 26
        withAnimation(.spring(duration: 0.75, bounce: 0.35)) { lift = 0 } completion: { bouncing = false }
    }
}

/// A teardrop with its tip at the top, filling `rect` (round part at the bottom).
struct DropShape: InsettableShape {
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> DropShape { DropShape(inset: inset + amount) }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
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

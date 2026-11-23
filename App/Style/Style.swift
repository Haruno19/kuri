import AppKit
import CoreText
import SwiftUI

// The visual language from docs/ui.md, tried in Sketches/Autumn.swift.

// MARK: - Timing

/// Every timing in one place, so motion can be tuned without hunting.
enum Tune {
    /// Things entering, leaving or moving across the window.
    static let move = Animation.spring(response: 0.42, dampingFraction: 0.88)
    /// Scrolling a sent message to the top.
    static let scroll = Animation.spring(response: 0.5, dampingFraction: 0.9)
    /// Status text swapping while the model works.
    static let status = Animation.spring(response: 0.35, dampingFraction: 0.9)
    /// Hover washes and highlights.
    static let hover = Animation.easeOut(duration: 0.14)
    /// A control becoming enabled or disabled.
    static let enable = Animation.easeInOut(duration: 0.28)
    /// Pressed buttons.
    static let press = Animation.spring(response: 0.22, dampingFraction: 0.65)
    /// Seconds for the shine to cross the logo.
    static let shine = 0.7
    /// Seconds for the light to cross the status text once.
    static let shimmer = 3.6
}

// MARK: - Palette

/// Quiet, warm neutrals with a muted chestnut accent; the logo alone keeps
/// the icon's own gradient.
struct Palette {
    let scheme: ColorScheme
    var dark: Bool { scheme == .dark }

    var background: Color { dark ? hex(0x1C1B1A) : hex(0xFAF9F5) }
    /// The composer sits a step darker than the background in both themes.
    var composer: Color { dark ? hex(0x141312) : hex(0xEFEDE6) }

    var ink: Color { dark ? hex(0xECEBE5) : hex(0x1F1E1D) }
    var secondary: Color { dark ? hex(0xA8A59C) : hex(0x6B6A64) }
    var faint: Color { dark ? hex(0x78766F) : hex(0x9C9A92) }

    var accent: Color { dark ? hex(0xC08452) : hex(0xA4693D) }
    var accentLight: Color { dark ? hex(0xD6A06F) : hex(0xC18A5B) }
    var accentFill: LinearGradient { LinearGradient(colors: [accentLight, accent], startPoint: .top, endPoint: .bottom) }

    var iconTop: Color { dark ? Color(.displayP3, red: 0.50, green: 0.31, blue: 0.14) : Color(.displayP3, red: 0.60, green: 0.345, blue: 0.165) }
    var iconBottom: Color { Color(red: 0.733, green: 0.58, blue: 0.341) }
    var iconGradient: LinearGradient { LinearGradient(colors: [iconTop, iconBottom], startPoint: .top, endPoint: .bottom) }

    /// User cards and other panels resting on the surface.
    var card: Color { dark ? hex(0x2F2B26) : hex(0xFFFDF8) }
    var shadow: Color { dark ? .black : hex(0x3A3226) }
    var wash: Color { ink.opacity(dark ? 0.08 : 0.06) }

    private func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette(scheme: .light)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Sets the palette for the current colour scheme on everything inside.
struct Themed: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.environment(\.palette, Palette(scheme: scheme))
    }
}

// MARK: - Type

/// The three faces, all bundled (decisions 0015 and 0018): Literata for the
/// model and accents, DM Sans for the interface, iA Writer Mono for code.
enum Typeface {
    static func serif(_ size: CGFloat) -> Font { .custom("Literata", size: size) }

    static func sans(_ size: CGFloat) -> Font { .custom("DM Sans", size: size) }

    /// Code is set smaller than the text around it (`monoScale`):
    /// monospaced faces look bigger at the same point size.
    static func mono(_ size: CGFloat) -> Font {
        FontLibrary.installed("iA Writer Mono S") ? .custom("iA Writer Mono S", size: size) : .system(size: size, design: .monospaced)
    }

    static let monoScale: CGFloat = 0.86
}

/// Registers the fonts in the app bundle for this process.
enum FontLibrary {
    static func prepare() {
        for ext in ["ttf", "otf"] {
            for url in Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [] {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    nonisolated static func installed(_ family: String) -> Bool {
        NSFontManager.shared.availableMembers(ofFontFamily: family) != nil
    }
}

// MARK: - Controls

/// A soft wash behind a control while the pointer is over it.
struct HoverWash<S: Shape>: ViewModifier {
    var shape: S
    @Environment(\.palette) private var palette
    @State private var hovering = false

    init(shape: S) { self.shape = shape }

    func body(content: Content) -> some View {
        content
            .background(shape.fill(palette.wash).opacity(hovering ? 1 : 0))
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(Tune.hover, value: hovering)
    }
}

extension HoverWash where S == RoundedRectangle {
    init() { self.init(shape: RoundedRectangle(cornerRadius: 7, style: .continuous)) }
}

/// Presses sink a little and spring back.
struct Squish: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(Tune.press, value: configuration.isPressed)
    }
}

/// A control that blends into the surface it sits on.
struct QuietButton: View {
    let glyph: Glyph
    var label: String? = nil
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                PencilIcon(glyph: glyph, size: 15, color: palette.secondary)
                if let label { Text(label).font(Typeface.sans(13)).foregroundStyle(palette.secondary) }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .modifier(HoverWash())
        }
        .buttonStyle(Squish())
    }
}

/// The one main action of a place, filled like the send button.
struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Filled(configuration: configuration)
    }

    private struct Filled: View {
        let configuration: Configuration
        @Environment(\.palette) private var palette
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            configuration.label
                .foregroundStyle(.white)
                .background {
                    ZStack {
                        shape.fill(palette.accentFill)
                        shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                    }
                    .shadow(color: palette.shadow.opacity(palette.dark ? 0.4 : 0.14), radius: 2, y: 1)
                }
                .brightness(configuration.isPressed ? -0.05 : hovering ? 0.04 : 0)
                .contentShape(shape)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { hovering = $0 }
                .animation(Tune.hover, value: hovering)
                .animation(Tune.press, value: configuration.isPressed)
        }
    }
}

/// A secondary action: outlined, washed on hover.
struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Outlined(configuration: configuration)
    }

    private struct Outlined: View {
        let configuration: Configuration
        @Environment(\.palette) private var palette
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            configuration.label
                .foregroundStyle(palette.ink)
                .background(shape.fill(palette.wash).opacity(hovering ? 1 : 0))
                .overlay(shape.strokeBorder(palette.faint.opacity(0.45), lineWidth: 1))
                .contentShape(shape)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { hovering = $0 }
                .animation(Tune.hover, value: hovering)
                .animation(Tune.press, value: configuration.isPressed)
        }
    }
}

/// A panel resting on the surface: a warm fill inside Liquid Glass, which
/// gives the edge light and depth; no drawn shadows.
struct Pane: ViewModifier {
    var radius: CGFloat = 9
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            // The glass alone turns grey on a light surface: the fill sets
            // the colour.
            .background(shape.fill(palette.card.opacity(palette.dark ? 0.85 : 0.92)))
            .glassEffect(.regular, in: shape)
            // Tones down the glass's bright rim on the top and bottom edges.
            .overlay(shape.strokeBorder(palette.card.opacity(0.55), lineWidth: 1.5))
    }
}

/// A shadow that only shows outside the shape, so translucent fills above
/// it stay clear.
struct OuterShadow<S: Shape>: View {
    let shape: S
    let color: Color
    let radius: CGFloat
    let y: CGFloat

    var body: some View {
        shape.fill(.black)
            .shadow(color: color, radius: radius, y: y)
            .mask {
                ZStack {
                    Rectangle().padding(-120)
                    shape.blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}

/// A single orb in the accent colour, slowly moving nearer and farther: the
/// working dots' depth, for a running conversation in the sidebar.
struct Orb: View {
    var size: CGFloat = 7
    @Environment(\.palette) private var palette

    var body: some View {
        TimelineView(.animation) { context in
            let depth = (sin(context.date.timeIntervalSinceReferenceDate * 2.4) + 1) / 2
            Circle()
                .fill(RadialGradient(colors: [palette.accentLight, palette.accent],
                                     center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.8))
                .frame(width: size, height: size)
                .scaleEffect(0.75 + 0.3 * depth)
                .opacity(0.55 + 0.45 * depth)
        }
        .frame(width: size * 1.2, height: size * 1.2)
    }
}

// MARK: - Pencil icons

/// Icons drawn as if with a pencil: strokes through slightly wobbly points,
/// round caps, and a second faint pass for the graphite.
enum Glyph {
    case sidebar, folder, arrowUp, chevron, plus, compose, xmark, retry, copy, check, sliders

    /// Strokes on a 24-point grid.
    nonisolated var strokes: [[CGPoint]] {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        switch self {
        case .sidebar:
            return [[p(4, 5.5), p(20, 5.5), p(20, 18.5), p(4, 18.5), p(4, 5.4)], [p(9.5, 5.9), p(9.5, 18.2)]]
        case .folder:
            return [[p(3.5, 18), p(3.5, 6), p(9.5, 6), p(11.5, 8.5), p(20.5, 8.5), p(20.5, 18), p(3.4, 18.1)]]
        case .arrowUp:
            return [[p(12, 19), p(12, 5.6)], [p(6.5, 11), p(12, 5.4), p(17.5, 11)]]
        case .chevron:
            return [[p(7, 9.5), p(12, 14.5), p(17, 9.5)]]
        case .plus:
            return [[p(12, 5.5), p(12, 18.5)], [p(5.5, 12), p(18.5, 12)]]
        case .compose:
            // A sheet open at the top right, and a pencil writing into it.
            return [[p(12, 4.5), p(6.5, 4.5), p(4.5, 6.5), p(4.5, 17.5), p(6.5, 19.5), p(17.5, 19.5), p(19.5, 17.5), p(19.5, 12)],
                    [p(10, 14), p(10.6, 11.2), p(17.8, 4), p(20, 6.2), p(12.8, 13.4), p(10, 14)]]
        case .xmark:
            return [[p(7, 7), p(17, 17)], [p(17, 7), p(7, 17)]]
        case .retry:
            // An open circle turning clockwise, its arrowhead at the top right.
            return [[p(17.4, 16.5), p(14.6, 18.5), p(11.3, 19.0), p(8.1, 17.8), p(5.8, 15.3), p(5.0, 12.0), p(5.8, 8.7),
                     p(8.1, 6.2), p(11.3, 5.0), p(14.6, 5.5), p(17.4, 7.5)],
                    [p(17.1, 4.1), p(17.4, 7.5), p(14.1, 6.6)]]
        case .copy:
            // Two sheets, the front one whole, the back one peeking out.
            return [[p(9, 8.5), p(19, 8.5), p(19, 19.5), p(9, 19.5), p(9, 8.4)],
                    [p(15, 5.5), p(15, 4.5), p(5, 4.5), p(5, 15.5), p(6.5, 15.5)]]
        case .check:
            return [[p(5.5, 12.5), p(10, 17), p(18.5, 7)]]
        case .sliders:
            // Two rails, each with its knob.
            func knob(_ x: CGFloat, _ y: CGFloat) -> [CGPoint] {
                (0...10).map { k in
                    let a = Double(k) / 10 * 2 * .pi - .pi / 2
                    return p(x + 2.3 * CGFloat(cos(a)), y + 2.3 * CGFloat(sin(a)))
                }
            }
            return [[p(4.5, 8), p(6.9, 8)], [p(11.5, 8), p(19.5, 8)], knob(9.2, 8),
                    [p(4.5, 16), p(12.5, 16)], [p(17.1, 16), p(19.5, 16)], knob(14.8, 16)]
        }
    }
}

nonisolated struct PencilShape: Shape {
    let glyph: Glyph
    var seed: Double = 0
    var wobble: CGFloat = 0.42

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * s, y: rect.midY - 12 * s)
        var path = Path()
        for (k, stroke) in glyph.strokes.enumerated() {
            let dense = densify(stroke, step: 2.4)
            let points = dense.enumerated().map { i, pt -> CGPoint in
                let amount = wobble * (i == 0 || i == dense.count - 1 ? 0.5 : 1)
                let jx = noise(Double(i) + Double(k) * 31 + seed) * amount
                let jy = noise(Double(i) * 1.7 + Double(k) * 17 + seed + 5) * amount
                return CGPoint(x: origin.x + (pt.x + jx) * s, y: origin.y + (pt.y + jy) * s)
            }
            guard points.count > 1 else { continue }
            path.move(to: points[0])
            if points.count > 2 {
                for i in 1..<(points.count - 1) {
                    let next = points[i + 1]
                    path.addQuadCurve(to: CGPoint(x: (points[i].x + next.x) / 2, y: (points[i].y + next.y) / 2), control: points[i])
                }
            }
            path.addLine(to: points[points.count - 1])
        }
        return path
    }

    /// Splits long segments, so straight lines wobble too, but keeps the corners.
    private func densify(_ points: [CGPoint], step: CGFloat) -> [CGPoint] {
        var out = [points[0]]
        for (a, b) in zip(points, points.dropFirst()) {
            let n = max(1, Int((hypot(b.x - a.x, b.y - a.y) / step).rounded()))
            for j in 1...n {
                let f = CGFloat(j) / CGFloat(n)
                out.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            }
        }
        return out
    }

    /// Deterministic noise in -1...1, so an icon looks the same every time.
    private func noise(_ x: Double) -> CGFloat {
        let v = sin(x * 12.9898 + 78.233) * 43758.5453
        return CGFloat((v - v.rounded(.down)) * 2 - 1)
    }
}

struct PencilIcon: View {
    let glyph: Glyph
    var size: CGFloat = 17
    var color: Color = .primary
    var weight: CGFloat = 1.5

    var body: some View {
        ZStack {
            PencilShape(glyph: glyph)
                .stroke(color.opacity(0.92), style: StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round))
            PencilShape(glyph: glyph, seed: 9, wobble: 0.6)
                .stroke(color.opacity(0.32), style: StrokeStyle(lineWidth: weight * 0.55, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}

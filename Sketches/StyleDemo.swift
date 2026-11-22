import SwiftUI
import AppKit

// Everything below is plain SwiftUI: shapes, gradients, blur, shadows, strokes.
// No bitmaps, no AppKit drawing. Rendered offscreen with ImageRenderer.

let W: CGFloat = 1000, H: CGFloat = 640

// MARK: - Wallpaper

struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.02, green: 0.16, blue: 0.40),
                                    Color(red: 0.00, green: 0.42, blue: 0.62),
                                    Color(red: 0.30, green: 0.72, blue: 0.52)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 0.3, green: 0.9, blue: 1).opacity(0.55))
                .frame(width: 420).blur(radius: 60).offset(x: -260, y: -160)
            Circle().fill(Color(red: 1, green: 0.55, blue: 0.2).opacity(0.5))
                .frame(width: 380).blur(radius: 70).offset(x: 320, y: 210)
            ForEach(0..<7) { i in
                Capsule().fill(.white.opacity(0.10))
                    .frame(width: 1300, height: CGFloat(10 + i * 3))
                    .rotationEffect(.degrees(-18))
                    .offset(y: CGFloat(i * 85 - 260))
                    .blur(radius: 5)
            }
        }
        .frame(width: W, height: H)
        .clipped()
    }
}

// MARK: - Aero

struct AeroCaptionButtons: View {
    var body: some View {
        HStack(spacing: 0) {
            seg(icon: "minus", fill: [.white.opacity(0.35), .white.opacity(0.08)], width: 28)
            seg(icon: "square", fill: [.white.opacity(0.35), .white.opacity(0.08)], width: 28)
            seg(icon: "xmark", fill: [Color(red: 0.95, green: 0.55, blue: 0.45),
                                      Color(red: 0.78, green: 0.18, blue: 0.10)], width: 46)
        }
        .frame(height: 19)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5))
        .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5)
            .strokeBorder(.black.opacity(0.55), lineWidth: 1))
    }

    func seg(icon: String, fill: [Color], width: CGFloat) -> some View {
        ZStack {
            LinearGradient(colors: fill, startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.0)], startPoint: .top, endPoint: .center)
            Image(systemName: icon).font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 1)
        }
        .frame(width: width)
        .overlay(alignment: .trailing) { Rectangle().fill(.black.opacity(0.35)).frame(width: 1) }
    }
}

struct AeroButton: View {
    var title: String
    var body: some View {
        Text(title)
            .font(.system(size: 12))
            .padding(.horizontal, 18).frame(height: 24)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(LinearGradient(
                        stops: [.init(color: Color(red: 0.92, green: 0.97, blue: 1.0), location: 0),
                                .init(color: Color(red: 0.85, green: 0.94, blue: 0.99), location: 0.49),
                                .init(color: Color(red: 0.74, green: 0.89, blue: 0.98), location: 0.5),
                                .init(color: Color(red: 0.65, green: 0.85, blue: 0.97), location: 1)],
                        startPoint: .top, endPoint: .bottom))
                    RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.8), lineWidth: 1).padding(1)
                    RoundedRectangle(cornerRadius: 3).strokeBorder(Color(red: 0.24, green: 0.48, blue: 0.68), lineWidth: 1)
                }
            }
            .shadow(color: Color(red: 0.3, green: 0.7, blue: 1).opacity(0.6), radius: 4)
    }
}

struct AeroWindow: View {
    let w: CGFloat = 450, h: CGFloat = 500
    var body: some View {
        ZStack(alignment: .top) {
            // glass tint, reflection streaks, gloss
            RoundedRectangle(cornerRadius: 9).fill(Color(red: 0.55, green: 0.75, blue: 0.95).opacity(0.25))
            ZStack {
                ForEach(0..<4) { i in
                    Rectangle().fill(.white.opacity(0.10))
                        .frame(width: CGFloat(30 + i * 14), height: 900)
                        .rotationEffect(.degrees(35))
                        .offset(x: CGFloat(i * 110 - 140))
                }
            }
            .frame(width: w, height: h).clipShape(RoundedRectangle(cornerRadius: 9))
            RoundedRectangle(cornerRadius: 9)
                .fill(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                .frame(height: 30)
                .frame(maxHeight: .infinity, alignment: .top)
            RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.55), lineWidth: 1).padding(1)
            RoundedRectangle(cornerRadius: 9).strokeBorder(.black.opacity(0.6), lineWidth: 1)

            // title + caption buttons
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.white)
                    .shadow(color: .blue, radius: 3)
                Text("Kuri — Aero")
                    .font(.system(size: 13))
                    .foregroundStyle(.black)
                    .shadow(color: .white, radius: 4).shadow(color: .white, radius: 8).shadow(color: .white, radius: 10)
                Spacer()
                AeroCaptionButtons().offset(y: -6)
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.top, 6)

            // client area
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Spacer()
                    Text("Can you summarize the build log?")
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(LinearGradient(
                            colors: [Color(red: 0.88, green: 0.95, blue: 1.0), Color(red: 0.74, green: 0.87, blue: 0.98)],
                            startPoint: .top, endPoint: .bottom)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(red: 0.5, green: 0.7, blue: 0.9)))
                }
                Text("Sure. The build failed in **KuriStore** — a missing migration for `items_fts`. Two warnings, both about Sendable conformance.")
                    .font(.system(size: 12.5)).foregroundStyle(Color(white: 0.15))
                Spacer()
                HStack(spacing: 8) {
                    Text("Message Kuri…").font(.system(size: 12)).foregroundStyle(.gray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(Color.white)
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color(red: 0.5, green: 0.6, blue: 0.7)))
                    AeroButton(title: "Send")
                }
            }
            .padding(14)
            .frame(width: w - 16, height: h - 30 - 8)
            .background(Color(red: 0.97, green: 0.98, blue: 0.99))
            .overlay(Rectangle().strokeBorder(.black.opacity(0.45), lineWidth: 1))
            .padding(.top, 30)
        }
        .frame(width: w, height: h)
    }
}

// MARK: - Aqua

struct Pinstripes: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.965)))
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(Color(white: 0.915)))
                y += 4
            }
        }
    }
}

struct TrafficLight: View {
    var color: Color
    var dark: Color
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [color.opacity(0.95), dark], center: UnitPoint(x: 0.5, y: 0.85),
                                         startRadius: 0, endRadius: 9))
            Ellipse().fill(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                .frame(width: 8, height: 5.5).offset(y: -3.2)
            Circle().strokeBorder(dark.opacity(0.9), lineWidth: 0.8)
        }
        .frame(width: 14, height: 14)
        .shadow(color: .black.opacity(0.3), radius: 0.5, y: 0.5)
    }
}

struct AquaGel: View {
    var top: Color, mid: Color, bottom: Color, border: Color
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack {
                Capsule().fill(LinearGradient(stops: [.init(color: top, location: 0),
                                                      .init(color: mid, location: 0.5),
                                                      .init(color: bottom, location: 1)],
                                              startPoint: .top, endPoint: .bottom))
                Capsule().fill(RadialGradient(colors: [.white.opacity(0.55), .clear], center: .bottom,
                                              startRadius: 0, endRadius: h * 0.9))
                Capsule().fill(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.2)], startPoint: .top, endPoint: .bottom))
                    .frame(height: h * 0.46).padding(.horizontal, h * 0.32)
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 1.5)
                Capsule().strokeBorder(border, lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1.5)
    }
}

struct AquaButton: View {
    var title: String
    var isDefault: Bool
    var body: some View {
        Text(title)
            .font(.system(size: 13))
            .foregroundStyle(.black)
            .shadow(color: .white.opacity(0.6), radius: 0, y: 1)
            .padding(.horizontal, 22).frame(height: 22)
            .background {
                if isDefault {
                    AquaGel(top: Color(red: 0.20, green: 0.45, blue: 0.88), mid: Color(red: 0.30, green: 0.60, blue: 0.96),
                            bottom: Color(red: 0.62, green: 0.88, blue: 1.0), border: Color(red: 0.10, green: 0.25, blue: 0.55))
                } else {
                    AquaGel(top: Color(white: 0.78), mid: Color(white: 0.86), bottom: Color(white: 0.99),
                            border: Color(white: 0.45))
                }
            }
    }
}

struct AquaProgress: View {
    var fraction: CGFloat
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: [Color(white: 0.80), Color(white: 0.97)], startPoint: .top, endPoint: .bottom))
                    .overlay(Capsule().strokeBorder(Color(white: 0.55)))
                ZStack {
                    AquaGel(top: Color(red: 0.20, green: 0.45, blue: 0.88), mid: Color(red: 0.30, green: 0.60, blue: 0.96),
                            bottom: Color(red: 0.62, green: 0.88, blue: 1.0), border: Color(red: 0.10, green: 0.25, blue: 0.55))
                    Canvas { ctx, size in
                        var x: CGFloat = -size.height
                        while x < size.width {
                            var p = Path()
                            p.move(to: CGPoint(x: x, y: size.height))
                            p.addLine(to: CGPoint(x: x + size.height, y: 0))
                            p.addLine(to: CGPoint(x: x + size.height + 7, y: 0))
                            p.addLine(to: CGPoint(x: x + 7, y: size.height))
                            ctx.fill(p, with: .color(.white.opacity(0.22)))
                            x += 16
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 14)
    }
}

struct AquaWindow: View {
    let w: CGFloat = 430, h: CGFloat = 500
    var body: some View {
        VStack(spacing: 0) {
            // title bar
            ZStack {
                LinearGradient(colors: [Color(white: 0.93), Color(white: 0.80)], startPoint: .top, endPoint: .bottom)
                Pinstripes().opacity(0.35).blendMode(.multiply)
                HStack(spacing: 7) {
                    TrafficLight(color: Color(red: 1, green: 0.45, blue: 0.40), dark: Color(red: 0.70, green: 0.10, blue: 0.08))
                    TrafficLight(color: Color(red: 1, green: 0.85, blue: 0.35), dark: Color(red: 0.72, green: 0.48, blue: 0.0))
                    TrafficLight(color: Color(red: 0.55, green: 0.92, blue: 0.40), dark: Color(red: 0.10, green: 0.50, blue: 0.05))
                    Spacer()
                }
                .padding(.leading, 9)
                Text("Kuri — Aqua").font(.system(size: 13)).foregroundStyle(Color(white: 0.15))
                    .shadow(color: .white, radius: 0, y: 1)
            }
            .frame(height: 24)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.55)).frame(height: 1) }

            // body
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Running in sandbox").font(.system(size: 12, weight: .bold))
                    AquaProgress(fraction: 0.62)
                    Text("swift build — compiling KuriAgent (14/23)")
                        .font(.system(size: 11)).foregroundStyle(Color(white: 0.3))
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.18)))

                Text("Tools").font(.system(size: 12, weight: .bold))
                VStack(alignment: .leading, spacing: 8) {
                    toolRow("checklist", "tasklist", on: true)
                    toolRow("questionmark.bubble", "clarify", on: true)
                    toolRow("brain", "memory", on: false)
                    toolRow("shippingbox", "sandbox", on: true)
                }

                Spacer()
                Text("Message Kuri…").font(.system(size: 12)).foregroundStyle(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 7).frame(height: 22)
                    .background(Color.white)
                    .overlay(Rectangle().strokeBorder(Color(white: 0.55)))
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [.black.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom).frame(height: 3)
                    }
                HStack(spacing: 12) {
                    Spacer()
                    AquaButton(title: "Cancel", isDefault: false)
                    AquaButton(title: "Send", isDefault: true)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Pinstripes())
        }
        .frame(width: w, height: h)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6).strokeBorder(.black.opacity(0.35)))
    }

    func toolRow(_ icon: String, _ name: String, on: Bool) -> some View {
        HStack(spacing: 9) {
            ZStack {
                if on {
                    AquaGel(top: Color(red: 0.20, green: 0.45, blue: 0.88), mid: Color(red: 0.30, green: 0.60, blue: 0.96),
                            bottom: Color(red: 0.62, green: 0.88, blue: 1.0), border: Color(red: 0.10, green: 0.25, blue: 0.55))
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .black)).foregroundStyle(.black.opacity(0.8))
                } else {
                    AquaGel(top: Color(white: 0.78), mid: Color(white: 0.86), bottom: Color(white: 0.99), border: Color(white: 0.45))
                }
            }
            .frame(width: 15, height: 15)
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Color(white: 0.3)).frame(width: 16)
            Text(name).font(.system(size: 12, design: .monospaced))
        }
    }
}

// MARK: - Canvas

struct Demo: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Wallpaper()

            // Aero: shadow, then real background blur masked to the window shape
            RoundedRectangle(cornerRadius: 9).fill(.black.opacity(0.5))
                .frame(width: 450, height: 500).blur(radius: 14).offset(x: 40, y: 58)
            Wallpaper().blur(radius: 14)
                .mask(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 9).frame(width: 450, height: 500).offset(x: 40, y: 50)
                }
            AeroWindow().offset(x: 40, y: 50)

            // Aqua: the famous big soft window shadow
            AquaWindow().compositingGroup()
                .shadow(color: .black.opacity(0.55), radius: 22, y: 14)
                .offset(x: 530, y: 50)

            Text("Rendered by SwiftUI: shapes, gradients, blur, shadows, SF Symbols. No image assets.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.6), radius: 2)
                .frame(width: W, alignment: .center)
                .offset(y: H - 34)
        }
        .frame(width: W, height: H)
    }
}

MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Demo())
    renderer.scale = 2
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "styledemo.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("wrote \(out)")
}

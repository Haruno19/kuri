import AppKit

// The disk image's background: the new chat page in a still frame, its dots
// and the meadow along the bottom, with an arrow from Kuri to Applications.
// The meadow is the app's own simulation (App/Views/Meadow.swift, compiled
// in by make-dmg.sh), stepped for a while so leaves are in the air and on
// the grass. Finder shows backgrounds as still images, so this is one frame.
//
//     Background <seed> <out.png> <scale>

/// The window, in points; make-dmg.sh places the icons on the same grid.
enum Layout {
    static let width = 640.0, height = 400.0
    static let appX = 170.0, applicationsX = 470.0, iconY = 150.0
    static let page = 0xFAF9F5, ink = 0x1F1E1D, accent = 0xA4693D
    /// As on the page (DotGrid in ChatView.swift).
    static let dotSpacing = 24.0, dotSize = 2.0, dotOpacity = 0.11
    static let dotCentre = (x: 0.5, y: 0.44), dotReach = 0.62
    static let arrowOpacity = 0.55
    /// Seconds simulated after the app's own warm-up.
    static let settle = 7.0
}

@main
struct Background {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4, let seed = UInt64(args[1]), let scale = Double(args[3]) else {
            FileHandle.standardError.write(Data("usage: Background <seed> <out.png> <scale>\n".utf8))
            exit(2)
        }
        let width = Int(Layout.width * scale), height = Int(Layout.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { exit(1) }
        // Points, from the top left.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.interpolationQuality = .none
        context.setShouldAntialias(false)

        func fill(_ rect: CGRect, _ hex: Int, _ alpha: Double = 1) {
            context.setFillColor(CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                                         blue: CGFloat(hex & 0xFF) / 255, alpha: alpha))
            context.fill(rect)
        }

        fill(CGRect(x: 0, y: 0, width: Layout.width, height: Layout.height), Layout.page)
        drawDots(fill)
        drawArrow(fill)
        drawMeadow(seed: seed, fill)

        guard let image = context.makeImage() else { exit(1) }
        let rep = NSBitmapImageRep(cgImage: image)
        // Finder sizes the background by its DPI: 72 for 1x, 144 for 2x.
        rep.size = NSSize(width: Layout.width, height: Layout.height)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
    }

    /// Faint square dots, clearest in the middle, gone by the edges.
    static func drawDots(_ fill: (CGRect, Int, Double) -> Void) {
        let s = Layout.dotSpacing, reach = max(Layout.width, Layout.height) * Layout.dotReach
        let cx = Layout.width * Layout.dotCentre.x, cy = Layout.height * Layout.dotCentre.y
        var y = Layout.height - s / 2
        while y > 0 {
            var x = s / 2
            while x < Layout.width {
                // The page's radial mask: full, 40% halfway, none at the rim.
                let t = min(1, ((x - cx) * (x - cx) + (y - cy) * (y - cy)).squareRoot() / reach)
                let mask = t < 0.5 ? 1 - 1.2 * t : 0.8 * (1 - t)
                fill(CGRect(x: x - Layout.dotSize / 2, y: y - Layout.dotSize / 2, width: Layout.dotSize, height: Layout.dotSize),
                     Layout.ink, Layout.dotOpacity * mask)
                x += s
            }
            y -= s
        }
    }

    /// A pixel arrow between the two icons, on the meadow's 4-point grid.
    static func drawArrow(_ fill: (CGRect, Int, Double) -> Void) {
        let shape = [
            "......X...",
            ".......X..",
            "XXXXXXXXX.",
            ".......X..",
            "......X...",
        ]
        let p = MeadowTune.pixel
        let left = ((Layout.appX + Layout.applicationsX) / 2 / p).rounded() * p - 5 * p
        let top = (Layout.iconY / p).rounded() * p - 2 * p
        for (row, line) in shape.enumerated() {
            for (col, mark) in line.enumerated() where mark == "X" {
                fill(CGRect(x: left + Double(col) * p, y: top + Double(row) * p, width: p, height: p), Layout.accent, Layout.arrowOpacity)
            }
        }
    }

    /// The meadow's strip along the bottom, faded in at its top, as
    /// `Meadowland` draws it in light mode.
    static func drawMeadow(seed: UInt64, _ fill: (CGRect, Int, Double) -> Void) {
        let p = MeadowTune.pixel, rows = MeadowTune.rows
        let cols = Int(Layout.width / p)
        let meadow = Meadow(seed: seed)
        meadow.resize(cols)
        let dt = 1 / MeadowTune.fps
        for _ in 0..<Int((MeadowTune.warmUp + Layout.settle) * MeadowTune.fps) { meadow.step(dt) }
        let pixels = meadow.pixels(MeadowColors(dark: false))
        let stripTop = Layout.height - Double(rows) * p
        for y in 0..<rows {
            let fade = min(1, (Double(y) + 0.5) / (Double(rows) * MeadowTune.fadeIn))
            for x in 0..<cols {
                let argb = pixels[y * cols + x]
                guard argb != 0 else { continue }
                let alpha = argb >> 24 == 0 ? 1 : Double(argb >> 24) / 255
                fill(CGRect(x: Double(x) * p, y: stripTop + Double(y) * p, width: p, height: p),
                     Int(argb & 0xFFFFFF), alpha * fade * MeadowTune.opacityLight)
            }
        }
    }
}

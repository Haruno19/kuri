import AppKit
import JavaScriptCore
import SwiftUI

/// LaTeX as images: MathJax (bundled in `App/MathJax`) turns TeX into SVG
/// inside JavaScriptCore, and AppKit draws the SVG natively, so formulas
/// stay vector and need no web view. MathJax loads the first time a reply
/// has maths (≈0.1 s, kept for the rest of the session) and each formula
/// takes a few milliseconds; both results are cached.
final class MathRenderer {
    static let shared = MathRenderer()

    /// A formula, ready to draw: `depth` is how far it hangs below the
    /// baseline.
    struct Rendered {
        let image: NSImage
        let depth: CGFloat
    }

    private var context: JSContext?
    private var failedToLoad = false
    private let images: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 400
        return cache
    }()

    private final class Box {
        let rendered: Rendered?
        init(_ rendered: Rendered?) { self.rendered = rendered }
    }

    /// Literata's x-height over MathJax's (0.442 em), so the maths matches
    /// the text around it, as MathJax does in a browser.
    private lazy var scale: CGFloat = {
        guard let font = NSFont(name: "Literata", size: 100) else { return 1 }
        return font.xHeight / 100 / 0.442
    }()

    /// `nil` when the TeX can't be rendered; the caller shows the source.
    func render(_ tex: String, display: Bool, size: CGFloat, color: Color) -> Rendered? {
        let hex = Self.hex(color)
        let key = "\(display ? 1 : 0)|\(size)|\(hex)|\(tex)" as NSString
        if let hit = images.object(forKey: key) { return hit.rendered }
        let rendered = svg(tex, display: display).flatMap { image(from: $0, size: size, color: hex) }
        images.setObject(Box(rendered), forKey: key)
        return rendered
    }

    private func svg(_ tex: String, display: Bool) -> String? {
        guard let context = loaded() else { return nil }
        let result = context.objectForKeyedSubscript("kuriTeX")?.call(withArguments: [tex, display])
        // A TeX error comes back as an `merror` box; the source reads better.
        guard let markup = result?.toString(), markup.hasPrefix("<svg"), !markup.contains("\"merror\"") else { return nil }
        return markup
    }

    /// MathJax sizes its SVG in ex and draws in `currentColor`; AppKit needs
    /// points and a real colour. The viewBox is in thousandths of an em,
    /// with the baseline at y = 0.
    private func image(from markup: String, size: CGFloat, color: String) -> Rendered? {
        guard let box = Self.viewBox(markup) else { return nil }
        let em = size * scale / 1000
        let width = box.width * em, height = box.height * em
        var svg = markup.replacingOccurrences(of: "currentColor", with: color)
        svg = Self.replacingAttribute("width", in: svg, with: "\(width)pt")
        svg = Self.replacingAttribute("height", in: svg, with: "\(height)pt")
        guard let image = NSImage(data: Data(svg.utf8)) else { return nil }
        image.size = NSSize(width: width, height: height)
        return Rendered(image: image, depth: (box.height + box.minY) * em)
    }

    private func loaded() -> JSContext? {
        if let context { return context }
        if failedToLoad { return nil }
        guard let main = Bundle.main.url(forResource: "tex-svg", withExtension: "js"),
              let lite = Bundle.main.url(forResource: "liteDOM", withExtension: "js"),
              let mainSource = try? String(contentsOf: main, encoding: .utf8),
              let liteSource = try? String(contentsOf: lite, encoding: .utf8),
              let context = JSContext() else {
            failedToLoad = true
            return nil
        }
        // No browser here: timers run as microtasks, and MathJax uses its
        // own lightweight DOM (liteDOM), loaded by hand before startup.
        context.evaluateScript("""
        var console = { log: function () {}, warn: function () {}, error: function () {} };
        var setTimeout = function (f) { Promise.resolve().then(f); return 0; };
        var clearTimeout = function () {};
        var MathJax = {
          loader: { load: ['adaptors/liteDOM'] },
          startup: { typeset: false, adaptor: 'liteAdaptor', ready: function () {} },
          svg: { fontCache: 'none' },
          tex: { packages: { '[+]': ['ams', 'newcommand', 'noerrors', 'noundefined'] } }
        };
        """)
        context.evaluateScript(mainSource)
        context.evaluateScript(liteSource)
        context.evaluateScript("""
        MathJax.loader.preLoad('adaptors/liteDOM');
        MathJax.startup.defaultReady();
        function kuriTeX(tex, display) {
          try {
            return MathJax.startup.adaptor.innerHTML(MathJax.tex2svg(tex, { display: display }));
          } catch (e) { return ''; }
        }
        """)
        guard context.objectForKeyedSubscript("MathJax")?.objectForKeyedSubscript("tex2svg")?.isObject == true else {
            failedToLoad = true
            return nil
        }
        self.context = context
        return context
    }

    private static func viewBox(_ svg: String) -> (minY: CGFloat, width: CGFloat, height: CGFloat)? {
        guard let start = svg.range(of: "viewBox=\""),
              let end = svg[start.upperBound...].firstIndex(of: "\"") else { return nil }
        let numbers = svg[start.upperBound..<end].split(separator: " ").compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return (CGFloat(numbers[1]), CGFloat(numbers[2]), CGFloat(numbers[3]))
    }

    /// Replaces an attribute of the root `<svg>` element only.
    private static func replacingAttribute(_ name: String, in svg: String, with value: String) -> String {
        guard let tagEnd = svg.firstIndex(of: ">"),
              let start = svg.range(of: " \(name)=\"", range: svg.startIndex..<tagEnd),
              let end = svg[start.upperBound...].firstIndex(of: "\"") else { return svg }
        return svg.replacingCharacters(in: start.upperBound..<end, with: value)
    }

    private static func hex(_ color: Color) -> String {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

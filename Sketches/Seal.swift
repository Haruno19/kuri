// Seal: 栗 (kuri, chestnut) as a hanko stamp signing the status line at the
// bottom left of the new chat page, the way old software signed its status
// bar. Three variants side by side, in both themes. It borrows the app's
// real styles by compiling App/Style/Style.swift alongside it.
//
//   swiftc -parse-as-library -default-isolation MainActor -O Sketches/Seal.swift App/Style/Style.swift -o /tmp/seal && /tmp/seal
//
// SEAL_RENDER=<folder> writes seal-light.png and seal-dark.png there and quits.

import AppKit
import CoreText
import SwiftUI

// MARK: - The seal

/// A square of chestnut ink with the character cut out of it, set a little
/// crooked as a hand would stamp it.
struct Seal: View {
    var size: CGFloat = 15
    /// Degrees; a stamp is never quite straight.
    var tilt: Double = -4
    /// The character's share of the square.
    var glyph: CGFloat = 0.78
    /// Filled square with the character in the paper's colour, or the
    /// character in ink inside a ruled border.
    var filled = true
    @Environment(\.palette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
        ZStack {
            if filled {
                shape.fill(palette.accent)
                Text("栗")
                    .font(.custom("HiraMinProN-W6", size: size * glyph))
                    .foregroundStyle(palette.background)
                    .offset(y: size * 0.02)
            } else {
                shape.strokeBorder(palette.accent, lineWidth: max(1, size * 0.08))
                Text("栗")
                    .font(.custom("HiraMinProN-W6", size: size * glyph * 0.9))
                    .foregroundStyle(palette.accent)
                    .offset(y: size * 0.02)
            }
        }
        .frame(width: size, height: size)
        // Ink isn't perfectly even.
        .opacity(0.92)
        .rotationEffect(.degrees(tilt))
    }
}

/// The status line as the app draws it, signed.
struct SignedStatus: View {
    let seal: Seal
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 7) {
            seal
            Text(text)
                .font(Typeface.mono(11))
                .foregroundStyle(palette.dim)
        }
    }
}

// MARK: - Board

struct Board: View {
    let scheme: ColorScheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        VStack(alignment: .leading, spacing: 26) {
            Text(scheme == .dark ? "Dark" : "Light")
                .font(Typeface.sans(13).weight(.medium))
                .foregroundStyle(palette.secondary)
            row("A · filled, 15 pt", Seal())
            row("B · filled, 13 pt, straight", Seal(size: 13, tilt: 0))
            row("C · outline, 15 pt", Seal(filled: false))
            HStack(spacing: 18) {
                Seal(size: 44, tilt: -4)
                Seal(size: 44, tilt: -4, filled: false)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 360, alignment: .leading)
        .background(palette.background)
        .environment(\.palette, palette)
        .environment(\.colorScheme, scheme)
    }

    private func row(_ title: String, _ seal: Seal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Typeface.sans(11.5)).foregroundStyle(Palette(scheme: scheme).dim)
            SignedStatus(seal: seal, text: "Pronto")
            SignedStatus(seal: seal, text: "Al lavoro in 2 chat")
        }
    }
}

// MARK: - App

@main struct SealSketch: App {
    init() {
        // The app's bundled faces, from the repository.
        let fonts = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "App/Fonts")
        for url in (try? FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil)) ?? []
        where ["ttf", "otf"].contains(url.pathExtension) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        if let folder = ProcessInfo.processInfo.environment["SEAL_RENDER"] {
            for scheme in [ColorScheme.light, .dark] {
                let renderer = ImageRenderer(content: Board(scheme: scheme))
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(filePath: folder).appending(path: "seal-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Seal") {
            HStack(spacing: 0) {
                Board(scheme: .light)
                Board(scheme: .dark)
            }
        }
        .windowResizability(.contentSize)
    }
}

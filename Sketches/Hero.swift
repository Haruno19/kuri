// Hero: the drawing at the left of kuri's header, where a frame holds its
// place today. A chestnut burr, stylized: spiky and green like the burrs
// that fall from the meadow's tree (its colours), with the brown nut
// showing through. Each option is printed as the header would show it, on
// the terminal's own background and on a light one.
//
//   swift Sketches/Hero.swift        all of them
//   swift Sketches/Hero.swift 2      one
//
// Needs a terminal with 24-bit colour (Ghostty, iTerm, Terminal).
//
// Pixel art in half blocks: two pixels a cell, one above the other, so they
// come out about square. 10 by 10 pixels: ten columns, five rows. Tried and
// dropped: braille (too faint at this size), box-drawing lines (too thin, a
// sun more than a burr), and burrs drawn from a formula (blobby: the nut
// took over and it read as a donut).

import Foundation

// MARK: - Colours

/// The meadow's burr and nut (App/Views/Meadow.swift), plus a highlight.
let palette: [Character: (Int, Int, Int)] = [
    "G": (0xA4, 0xAE, 0x58),  // burr, light
    "g": (0x7E, 0x8A, 0x3C),  // burr, dark
    "N": (0xB0, 0x70, 0x3F),  // nut, light
    "n": (0x8A, 0x4F, 0x2A),  // nut, dark
    "h": (0xD9, 0xA0, 0x6F),  // nut, highlight
    "c": (0xE6, 0xD3, 0xA3),  // the nut's pale base
]

func fg(_ c: (Int, Int, Int)) -> String { "\u{1B}[38;2;\(c.0);\(c.1);\(c.2)m" }
func bg(_ c: (Int, Int, Int)) -> String { "\u{1B}[48;2;\(c.0);\(c.1);\(c.2)m" }
let reset = "\u{1B}[0m"
let bold = "\u{1B}[1m", dim = "\u{1B}[2m"

// MARK: - Drawing

/// One hero: rows of terminal text, already coloured, and how wide it is.
struct Art {
    let name: String
    let note: String
    let rows: [String]
    let width: Int
}

/// Pixel art drawn with half blocks: two pixels a cell, one above the other,
/// so pixels come out about square. `.` is empty.
func pixels(_ name: String, _ note: String, _ grid: [String], on background: (Int, Int, Int)?) -> Art {
    let grid = grid.count % 2 == 0 ? grid : grid + [String(repeating: ".", count: grid[0].count)]
    let width = grid.map(\.count).max() ?? 0
    var rows: [String] = []
    for pair in stride(from: 0, to: grid.count, by: 2) {
        let top = Array(grid[pair].padding(toLength: width, withPad: ".", startingAt: 0))
        let bottom = Array(grid[pair + 1].padding(toLength: width, withPad: ".", startingAt: 0))
        var row = ""
        for x in 0..<width {
            let t = palette[top[x]], b = palette[bottom[x]]
            let base = background.map(bg) ?? ""
            switch (t, b) {
            case (nil, nil): row += base + " " + reset
            case (let t?, nil): row += base + fg(t) + "▀" + reset
            case (nil, let b?): row += base + fg(b) + "▄" + reset
            case (let t?, let b?): row += fg(t) + bg(b) + "▀" + reset
            }
        }
        rows.append(row)
    }
    return Art(name: name, note: note, rows: rows, width: width)
}

// MARK: - The options

func options(on background: (Int, Int, Int)?) -> [Art] {
    [
        pixels("1 · Burr", "closed and round, the nut glimpsed through a split", [
            "...g..g...",
            ".g..GG..g.",
            "..GGGGGg..",
            "g.GGGGgg.g",
            ".GGGhNggg.",
            ".GGGNnggg.",
            "g.GGgggg.g",
            "..Gggggg..",
            ".g..gg..g.",
            "...g..g...",
        ], on: background),
        pixels("2 · Open", "the burr split open, the nut rising out of it", [
            "....hN....",
            "...hNNn...",
            "..NNNNNn..",
            ".gnNNNNng.",
            "gGGccccggg",
            ".GGGGgggg.",
            "gGGGgggggg",
            ".GGgggggg.",
            "..g.gg.g..",
            ".g......g.",
        ], on: background),
        pixels("3 · Star", "long spikes all round, a mark more than a picture", [
            "....gg....",
            ".g..Gg..g.",
            "..gGGGgg..",
            "..GGGGgg..",
            "gGGGhNgggg",
            "gGGGNngggg",
            "..GGgggg..",
            "..ggggggg.",
            ".g..gg..g.",
            "....gg....",
        ], on: background),
        pixels("4 · Swirl", "four spikes sweeping round, like a spiral", [
            "......gg..",
            ".....G....",
            "g..GGGG...",
            "g.GGGGGg..",
            ".gGGhNgg..",
            "..GGNnggg.",
            "..GGgggg.g",
            "...Gggg..g",
            "....g.....",
            "..gg......",
        ], on: background),
    ]
}

// MARK: - Showing them

/// As kuri's header shows it: two columns in, the hero, three spaces, the lines.
func header(_ art: Art, on background: (Int, Int, Int)?) {
    let base = background.map(bg) ?? ""
    let ink = background == nil ? "" : fg((0x3A, 0x30, 0x28))
    let lines = [
        base + ink + bold + "Kuri" + reset + base + ink + dim + " 0.2.0" + reset,
        base + ink + "ollama/qwen3.5:2b" + dim + " · " + reset + base + ink + "~/Code/Swift/Kuri" + reset,
        base + bold + fg((0xB2, 0x77, 0x48)) + "/help" + reset + base + ink + dim + " for commands · Ctrl-C stops a turn" + reset,
    ]
    let height = max(art.rows.count, lines.count)
    // The text sits level with the middle of a taller drawing.
    let textTop = (height - lines.count) / 2
    print(dim + "  " + art.name + reset + dim + " — " + art.note + reset)
    print(base + String(repeating: " ", count: 62) + reset)
    for row in 0..<height {
        let drawing = row < art.rows.count ? art.rows[row] : base + String(repeating: " ", count: art.width) + reset
        let text = (textTop..<textTop + lines.count).contains(row) ? lines[row - textTop] : ""
        let used = 2 + art.width + 3 + (text.isEmpty ? 0 : visibleCount(text))
        print(base + "  " + reset + drawing + base + "   " + reset + text + base + String(repeating: " ", count: max(0, 62 - used)) + reset)
    }
    print(base + String(repeating: " ", count: 62) + reset)
    print()
}

func visibleCount(_ s: String) -> Int {
    s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).count
}

let light = (0xF7, 0xF3, 0xEC)
let which = CommandLine.arguments.dropFirst().first
for (dark, lit) in zip(options(on: nil), options(on: light)) {
    if which == nil || dark.name.hasPrefix(which!) {
        header(dark, on: nil)
        header(lit, on: light)
    }
}

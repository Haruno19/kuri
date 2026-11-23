import AppKit
import SwiftUI

// The meadow along the bottom of the new chat page (decision 0023): a round
// chestnut tree on the right, short autumn grass to the left edge, wind that
// carries leaves across it at three depths, and now and then a burr that
// drops, rolls and splits. Procedural, in square pixels: each frame is a
// bitmap the size of the grid, scaled up by Core Animation without
// smoothing. The sketch it came from is Sketches/Meadow.swift.

// MARK: - Tuning

/// Everything we'd adjust back and forth.
enum MeadowTune {
    /// Low on purpose: it reads as old software, and costs little.
    static let fps = 12.0
    /// Points per pixel.
    static let pixel: CGFloat = 4
    /// The strip's height, in pixels: room for the tree; the grass is short.
    static let rows = 36
    /// How much of the strip, from its top, fades in from nothing.
    static let fadeIn = 0.12
    static let opacityDark = 0.75
    static let opacityLight = 0.95

    /// Wind, 0...1. Gusts roll in from the tree's side, right to left.
    static let calm = 0.12
    static let gustWidth = 2.4      // gusts per strip width, roughly
    static let gustSpeed = 0.9      // radians a second
    static let gustSwell = 0.11     // how fast gusty spells come and go

    /// Leaves a second that come loose, in still air and in a full gust.
    static let leafRate = 0.4
    static let gustLeafRate = 3.0
    static let maxLeaves = 90
    /// Leaves fall at three depths, a parallax: far ones drift slower and
    /// dimmer behind the tree and the grass, near ones faster and brighter
    /// in front of everything. Shares of leaves, speeds and opacities.
    static let depthShare = [0.35, 0.4, 0.25]
    static let depthSpeed = [0.55, 1.0, 1.5]
    static let depthOpacity = [0.55, 1.0, 1.0]
    /// Seconds a leaf lies on the grass before it fades.
    static let leafRest: ClosedRange<Double> = 20...45
    /// Seconds between burrs dropping.
    static let burrEvery: ClosedRange<Double> = 8...18
    /// How fast a burr pops out sideways as it drops, pixels a second: it
    /// lands and rolls well clear of the trunk.
    static let burrToss: ClosedRange<Double> = 4...12
    /// Seconds an opened burr stays.
    static let burrRest: ClosedRange<Double> = 50...90

    /// A click on the tree: a damped sway, the top following the trunk a
    /// beat late, and leaves coming loose over it.
    static let shakeLength = 1.8          // seconds
    static let shakeSway = 2.6            // pixels, at the crown's top
    static let shakeFrequency = 1.5       // sways a second
    static let shakeDamping = 2.4         // per second
    static let shakeLeaves = 10...16
    /// Frames a second while the tree sways: the sway needs them, the
    /// meadow at rest doesn't.
    static let shakeFPS = 30.0
    static let fadeOut = 4.0
    /// Seconds simulated before the first frame, so leaves already lie in
    /// the grass.
    static let warmUp = 40.0
}


/// The meadow's colours, a little muted against the page.
struct MeadowColors: Equatable {
    var dark: Bool

    /// Each hue as highlight, middle, shadow: gold, orange, rust, yellow.
    var leaves: [[UInt32]] {
        dark ? [[0xF0C75E, 0xD9A441, 0xA77A2C], [0xEE9F4E, 0xD27F35, 0x9E5A25],
                [0xD0703F, 0xB2552F, 0x7F3A22], [0xF2D77A, 0xDDBB55, 0xA88B3A]]
             : [[0xE2B04A, 0xC8902E, 0x95681F], [0xE08A3A, 0xC06A26, 0x8C4A1C],
                [0xC25E32, 0xA14526, 0x70301B], [0xE8C860, 0xCFA942, 0x977A2C]]
    }
    var grass: [UInt32] { [0x8A9148, 0x6F7A3E, 0xA39A55, 0x5E6836] }
    var earth: [UInt32] { dark ? [0x5E4A3A, 0x473829] : [0xB09A7C, 0x9C8468] }
    /// Highlight, middle, shadow.
    var bark: [UInt32] { [0x9A7656, 0x7A5A40, 0x5C4230] }
    var burr: [UInt32] { [0xA4AE58, 0x7E8A3C] }
    var nut: [UInt32] { [0xB0703F, 0x8A4F2A] }

    /// A near leaf catching the light: a quarter of the way to white on a
    /// dark page; on a light one the highlight is bright enough.
    func lit(_ color: UInt32) -> UInt32 {
        guard dark else { return color }
        func channel(_ shift: UInt32) -> UInt32 {
            let c = Double(color >> shift & 0xFF)
            return UInt32(c + (255 - c) * 0.25) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }
}

// MARK: - Noise

/// Stable pseudo-random numbers from grid positions, so the same column
/// always grows the same grass.
private func noise(_ a: Int, _ b: Int = 0, _ c: Int = 0) -> Double {
    var h = UInt64(bitPattern: Int64(a &* 374_761_393 &+ b &* 668_265_263 &+ c &* 2_147_483_647))
    h = (h ^ (h >> 13)) &* 1_274_126_177
    h ^= h >> 16
    return Double(h & 0xFFFF) / 65_536
}

// MARK: - Scene

/// A small seeded generator: the same seed grows the same tree.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The simulation. A class its view steps in place: it's drawn every
/// frame and nothing else observes it.
final class Meadow {
    struct Leaf {
        var x, y, vx, phase: Double
        var hue: Int
        /// 0 far, 1 middle, 2 near.
        var depth: Int
        var landed: Double?
        var rest: Double
    }

    struct Burr {
        var x, y, vx, vy: Double
        var landed: Double?
        var rest: Double
    }

    /// One cluster of the crown, relative to its centre, in its own colour.
    struct Blob {
        var x, y, radius: Double
        var hue: Int
    }

    var cols = 0
    var time = 0.0
    var leaves: [Leaf] = []
    var burrs: [Burr] = []
    var nextBurr = 6.0
    var shakeStart = -10.0
    /// Leaves a click shakes loose, and when each lets go.
    var loosening: [(at: Double, x: Double, y: Double)] = []
    var rng = SystemRandomNumberGenerator()
    /// The tree grown from the seed: its clusters, and the flecks and gaps
    /// in them.
    let blobs: [Blob]
    let seed: Int

    init(seed: UInt64) {
        var grower = SplitMix(seed: seed)
        blobs = Self.growCrown(using: &grower)
        self.seed = Int(seed % 100_000)
    }

    var isShaking: Bool { time - shakeStart < MeadowTune.shakeLength }

    /// The first of the two earth rows; grass grows above it.
    var ground: Int { MeadowTune.rows - 2 }
    /// The trunk's centre: the tree stands near the right edge.
    var trunkX: Int { cols - max(36, cols / 7) }
    var crownY: Double { 15 }
    /// The crown fits this box around its centre whatever its clusters:
    /// round, a little wider than tall.
    static let crownBox = (left: -15.5, right: 15.5, top: -13.0, bottom: 12.0)

    /// A round crown of overlapping clusters: a big one in the middle,
    /// smaller ones around its top and sides, one underneath; then scaled
    /// and moved to fill `crownBox`, so every tree is about the same size.
    static func growCrown(using rng: inout some RandomNumberGenerator) -> [Blob] {
        func random(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &rng) }
        var blobs = [Blob(x: random(-1...1), y: random(-2...0), radius: random(9.5...11), hue: 0)]
        let count = Int.random(in: 4...6, using: &rng)
        for i in 0..<count {
            // Spread over the upper half and the sides, a little jittered.
            let angle = -.pi - 0.15 + (.pi + 0.3) * (Double(i) + random(0.25...0.75)) / Double(count)
            let distance = random(6.5...9)
            blobs.append(Blob(x: cos(angle) * distance * 1.15, y: sin(angle) * distance * 0.85, radius: random(5.5...8), hue: 0))
        }
        blobs.append(Blob(x: random(-2...2), y: random(3...5), radius: random(7...8.5), hue: 0))

        let left = blobs.map { $0.x - $0.radius }.min()!, right = blobs.map { $0.x + $0.radius }.max()!
        let top = blobs.map { $0.y - $0.radius }.min()!, bottom = blobs.map { $0.y + $0.radius }.max()!
        let box = crownBox
        let scale = min((box.right - box.left) / (right - left), (box.bottom - box.top) / (bottom - top))
        // Neighbours differ in colour, so the clusters read as clusters.
        var hues = Array(0..<4).shuffled(using: &rng)
        return blobs.enumerated().map { i, blob in
            if i % 4 == 0 { hues.shuffle(using: &rng) }
            return Blob(x: (blob.x - (left + right) / 2) * scale, y: (blob.y - bottom) * scale + box.bottom,
                        radius: blob.radius * scale, hue: hues[i % 4])
        }
    }

    func resize(_ cols: Int) {
        guard cols != self.cols else { return }
        let first = self.cols == 0
        self.cols = cols
        if first { scatter() }
    }

    /// A few burrs already lying open around the tree.
    private func scatter() {
        for dx in [-24.0, -15.0, 13.0, 22.0] {
            burrs.append(Burr(x: Double(trunkX) + dx + Double.random(in: -3...3, using: &rng), y: Double(ground - 1), vx: 0, vy: 0,
                              landed: -10, rest: Double.random(in: 200...400, using: &rng)))
        }
    }

    /// Wind, 0...1, at a column.
    func wind(_ x: Double) -> Double {
        let swell = 0.4 + 0.6 * pow(0.5 + 0.5 * sin(time * MeadowTune.gustSwell + 1.3), 2)
        let wave = 0.5 + 0.5 * sin(x / Double(max(cols, 1)) * MeadowTune.gustWidth * .pi + time * MeadowTune.gustSpeed)
        return min(1, MeadowTune.calm + pow(wave, 4) * swell)
    }

    /// Blades above the ground: often none, now and then a taller tuft.
    func grassHeight(_ x: Int) -> Int {
        let k = noise(x, 7)
        return k < 0.25 ? 0 : k < 0.7 ? 1 : k < 0.93 ? 2 : 3
    }

    /// How deep a point is inside the crown (0 at the edge), and the blob
    /// it's deepest in; nil outside.
    func crown(_ x: Double, _ y: Double) -> (depth: Double, blob: Blob)? {
        let cx = Double(trunkX), cy = crownY
        var best: (depth: Double, blob: Blob)?
        for blob in blobs {
            let dx = x - (cx + blob.x), dy = y - (cy + blob.y)
            let depth = blob.radius - (dx * dx + dy * dy).squareRoot()
            if depth > 0, depth > (best?.depth ?? 0) { best = (depth, blob) }
        }
        return best
    }

    /// How far a crown row is pushed sideways: leaning with a gust (more
    /// towards the top), and swaying after a click, the top a beat behind.
    func sway(_ y: Double, gust: Double) -> Double {
        let height = max(0, min(1, (crownY + Self.crownBox.bottom - y) / (Self.crownBox.bottom - Self.crownBox.top)))
        var shift = -gust * 2.2 * height * height
        let t = time - shakeStart
        if t >= 0, t < MeadowTune.shakeLength {
            let lag = height * 0.5
            shift += MeadowTune.shakeSway * height * exp(-MeadowTune.shakeDamping * t) * sin(2 * .pi * MeadowTune.shakeFrequency * t - lag)
        }
        return shift
    }

    // MARK: Stepping

    func step(_ dt: Double) {
        time += dt
        let gust = wind(Double(trunkX))
        let rate = MeadowTune.leafRate + MeadowTune.gustLeafRate * pow(gust, 2)
        if leaves.count < MeadowTune.maxLeaves, Double.random(in: 0..<1, using: &rng) < rate * dt { dropLeaf() }
        if time > nextBurr {
            dropBurr()
            nextBurr = time + Double.random(in: MeadowTune.burrEvery, using: &rng)
        }
        // Leaves a click shook loose let go a few at a time.
        while let first = loosening.first, first.at <= time {
            loosening.removeFirst()
            if leaves.count < MeadowTune.maxLeaves + 20 { dropLeaf(near: (first.x, first.y)) }
        }
        for i in leaves.indices { stepLeaf(&leaves[i], dt) }
        leaves.removeAll { leaf in leaf.x < -2 || leaf.x > Double(cols) + 2 || (leaf.landed.map { time - $0 > leaf.rest + MeadowTune.fadeOut } ?? false) }
        for i in burrs.indices { stepBurr(&burrs[i], dt) }
        burrs.removeAll { burr in burr.x < -3 || burr.x > Double(cols) + 3 || (burr.landed.map { time - $0 > burr.rest + MeadowTune.fadeOut } ?? false) }
    }

    private func dropLeaf(near point: (Double, Double)? = nil) {
        var x = 0.0, y = 0.0
        if let point {
            x = point.0 + Double.random(in: -6...6, using: &rng)
            y = point.1 + Double.random(in: -3...3, using: &rng)
        } else {
            // From the crown's rim, mostly its lower half.
            let angle = Double.random(in: -0.4 ... .pi + 0.4, using: &rng)
            x = Double(trunkX) + cos(angle) * 15
            y = crownY + 2 + sin(angle) * 8
        }
        // Shaken leaves come from the front of the crown, never far back.
        let pick = Double.random(in: point == nil ? 0..<1 : MeadowTune.depthShare[0]..<1, using: &rng)
        let depth = pick < MeadowTune.depthShare[0] ? 0 : pick < MeadowTune.depthShare[0] + MeadowTune.depthShare[1] ? 1 : 2
        leaves.append(Leaf(x: x, y: max(0, y), vx: 0, phase: Double.random(in: 0..<(2 * .pi), using: &rng),
                           hue: Int.random(in: 0..<4, using: &rng), depth: depth, landed: nil,
                           rest: Double.random(in: MeadowTune.leafRest, using: &rng)))
    }

    /// From under the crown, tossed outwards: the further out it starts,
    /// the harder it's thrown.
    private func dropBurr() {
        let offset = Double.random(in: -12...12, using: &rng)
        let toss = Double.random(in: MeadowTune.burrToss, using: &rng) * (offset < 0 ? -1 : 1)
        burrs.append(Burr(x: Double(trunkX) + offset, y: crownY + 5, vx: toss, vy: Double.random(in: -6 ... -2, using: &rng),
                          landed: nil, rest: Double.random(in: MeadowTune.burrRest, using: &rng)))
    }

    private func stepLeaf(_ leaf: inout Leaf, _ dt: Double) {
        let w = wind(leaf.x)
        if let landed = leaf.landed {
            // A strong gust picks a resting leaf up again and tumbles it on.
            if w > 0.65, time - landed > 1, Double.random(in: 0..<1, using: &rng) < dt * 0.6 {
                leaf.landed = nil
                leaf.y -= 3
            }
            return
        }
        let speed = MeadowTune.depthSpeed[leaf.depth]
        let target = (-w * 22 - 1) * speed
        leaf.vx += (target - leaf.vx) * min(1, dt * 1.5)
        let fall = (3.2 + 2 * sin(time * 2.7 + leaf.phase) - w * 2) * speed
        leaf.x += (leaf.vx + sin(time * 3.1 + leaf.phase) * 3 * speed) * dt
        leaf.y += fall * dt
        // Far leaves settle further back (higher up, behind the grass), near
        // ones on the front edge; the middle ones on the ground or the grass.
        let rest = switch leaf.depth {
        case 0: Double(ground - 2)
        case 1: Double(ground - 1 - (noise(Int(leaf.x), 7) < 0.7 ? 0 : 1))
        default: Double(ground)
        }
        if leaf.y >= rest {
            leaf.y = rest
            leaf.landed = time
        }
    }

    /// Falls, bounces once, rolls to a stop, and only then splits open.
    private func stepBurr(_ burr: inout Burr, _ dt: Double) {
        guard burr.landed == nil else { return }
        let rest = Double(ground - 1)
        if burr.y < rest || burr.vy < 0 {
            burr.vy += 45 * dt
            burr.y += burr.vy * dt
            burr.x += (burr.vx - wind(burr.x) * 2) * dt
            if burr.y >= rest {
                burr.y = rest
                burr.vy = burr.vy > 18 ? -burr.vy * 0.3 : 0  // One small bounce.
                burr.vx *= 0.7
            }
        } else {
            // Rolling, slowing down on the grass.
            burr.x += burr.vx * dt
            let friction = 9 * dt
            burr.vx = abs(burr.vx) <= friction ? 0 : burr.vx - friction * (burr.vx > 0 ? 1 : -1)
            if burr.vx == 0 { burr.landed = time }
        }
    }

    /// A click on the tree shakes some leaves loose, and sometimes a burr.
    /// The crown or the trunk, in grid pixels.
    func isTree(_ x: Double, _ y: Double) -> Bool {
        crown(x, y) != nil || (abs(x - Double(trunkX)) < 3 && y > crownY && y < Double(ground))
    }

    func shake(at point: (Double, Double)) {
        guard isTree(point.0, point.1) else { return }
        // A click during a sway adds to it rather than starting over hard.
        shakeStart = isShaking ? max(shakeStart, time - 0.15) : time
        for _ in MeadowTune.shakeLeaves.randomElement(using: &rng).map({ 0..<$0 })! {
            loosening.append((at: time + Double.random(in: 0.05...0.9, using: &rng), x: point.0, y: point.1))
        }
        loosening.sort { $0.at < $1.at }
        if Double.random(in: 0..<1, using: &rng) < 0.5 { dropBurr() }
    }

    // MARK: Drawing

    /// The frame's pixels, 0xAARRGGBB (0 is empty), row by row.
    func pixels(_ palette: MeadowColors) -> [UInt32] {
        var pixels = [UInt32](repeating: 0, count: cols * MeadowTune.rows)
        func put(_ x: Int, _ y: Int, _ color: UInt32, _ alpha: Double = 1) {
            guard x >= 0, x < cols, y >= 0, y < MeadowTune.rows else { return }
            let a = UInt32(max(1, min(255, (alpha * 255).rounded())))
            pixels[y * cols + x] = (a == 255 ? 0 : a << 24) | color
        }

        // Earth, two rows of it, speckled.
        for x in 0..<cols {
            put(x, ground, noise(x, 21) < 0.15 ? palette.earth[1] : palette.earth[0])
            put(x, ground + 1, noise(x, 22) < 0.2 ? palette.earth[0] : palette.earth[1])
        }

        drawLeaves(depth: 0, palette, put)

        // Grass, short, all the way to the left edge. A gust bends a blade's
        // tip away from the tree.
        for x in 0..<cols {
            let height = grassHeight(x)
            guard height > 0 else { continue }
            let lean = wind(Double(x)) + 0.12 * sin(time * 2.3 + Double(x) * 0.7)
            let color = palette.grass[Int(noise(x, 3) * 4)]
            for level in 1...height {
                let tip = level == height && height > 1
                let bend = tip && lean > 0.8 ? -2 : tip && lean > 0.45 ? -1 : 0
                put(x + bend, ground - level, color)
            }
        }

        // The trunk, with a highlit left side, a shaded right one, roots.
        let t = trunkX
        for y in Int(crownY) ..< ground {
            put(t - 2, y, palette.bark[0])
            put(t - 1, y, palette.bark[1]); put(t, y, palette.bark[1])
            put(t + 1, y, palette.bark[2])
        }
        put(t - 3, ground - 1, palette.bark[1]); put(t + 2, ground - 1, palette.bark[2])
        // Two branches, seen through the gaps low in the crown.
        for i in 0..<5 {
            put(t - 3 - i, Int(crownY) + 3 - i / 2, palette.bark[1])
            put(t + 2 + i, Int(crownY) + 2 - i / 2, palette.bark[2])
        }

        // The crown: round, lit from the top left, in patches of autumn
        // hues; its top leans with a gust and its rim flickers.
        let gust = wind(Double(t))
        let flicker = Int(time * (2 + gust * 6))
        let top = Int(crownY + Self.crownBox.top) - 1, bottom = Int(crownY + Self.crownBox.bottom) + 1
        for y in max(0, top)...bottom {
            let shift = sway(Double(y), gust: gust).rounded()
            for x in (t - 22)...(t + 22) {
                let sx = Double(x) - shift, sy = Double(y)
                guard let (depth, blob) = crown(sx, sy) else { continue }
                if depth < 1.2, noise(x, y, flicker) < 0.3 * gust { continue }
                // Gaps low in the crown, dark with the branches behind.
                if sy > crownY + 1, depth > 2, noise(x - Int(shift), y, seed) < 0.1 {
                    put(x, y, palette.bark[2])
                    continue
                }
                // The cluster's hue, flecked with the others.
                let fleck = noise(x - Int(shift), y, seed + 1)
                let hue = fleck < 0.1 ? Int(fleck * 40) : blob.hue
                // Light from the top left of each blob, and the crown's
                // underside in shade; a checker blends the bands.
                let bx = Double(t) + blob.x, by = crownY + blob.y
                let light = (-(sx - bx) * 0.55 - (sy - by) * 0.85) / blob.radius - (sy > crownY + 5 ? 0.5 : 0)
                let checker = (x + y) % 2 == 0 ? 0.08 : -0.08
                let tone = light + checker > 0.35 ? 0 : light + checker < -0.25 ? 2 : 1
                put(x, y, palette.leaves[hue][tone])
            }
        }

        // Burrs: falling closed and spiky, lying split with the nut showing.
        for burr in burrs {
            let x = Int(burr.x.rounded()), y = Int(burr.y.rounded())
            let alpha = fade(burr.landed, burr.rest)
            if let landed = burr.landed, time - landed > 1.5 {
                put(x - 2, y, palette.burr[1], alpha); put(x - 2, y - 1, palette.burr[0], alpha)
                put(x, y, palette.nut[1], alpha); put(x - 1, y, palette.nut[1], alpha)
                put(x - 1, y - 1, palette.nut[0], alpha); put(x, y - 1, palette.nut[1], alpha)
                put(x + 1, y, palette.burr[1], alpha); put(x + 1, y - 1, palette.burr[0], alpha)
            } else {
                for (dx, dy) in [(0, 0), (-1, 0), (0, -1), (-1, -1)] { put(x + dx, y + dy, palette.burr[0]) }
                for (dx, dy) in [(-2, -1), (1, 0), (0, -2), (-1, 1)] { put(x + dx, y + dy, palette.burr[1]) }
            }
        }

        drawLeaves(depth: 1, palette, put)
        drawLeaves(depth: 2, palette, put)
        return pixels
    }

    /// A leaf is a pixel that flutters into two as it turns, or lies still;
    /// near ones are wider and brighter, far ones dim.
    private func drawLeaves(depth: Int, _ palette: MeadowColors, _ put: (Int, Int, UInt32, Double) -> Void) {
        let opacity = MeadowTune.depthOpacity[depth]
        for leaf in leaves where leaf.depth == depth {
            let x = Int(leaf.x.rounded()), y = Int(leaf.y.rounded())
            let tones = palette.leaves[leaf.hue]
            // Far leaves in their shadow tone, near ones lit.
            let body = depth == 0 ? tones[2] : depth == 1 ? tones[1] : palette.lit(tones[0])
            let edge = depth == 0 ? tones[2] : depth == 1 ? tones[0] : tones[1]
            let alpha = opacity * fade(leaf.landed, leaf.rest)
            if leaf.landed != nil {
                put(x, y, body, alpha)
                if depth == 2 || noise(x, Int(leaf.phase * 100)) < 0.5 { put(x - 1, y, edge, alpha) }
            } else {
                put(x, y, depth == 1 ? edge : body, alpha)
                if depth == 2 { put(x + 1, y, edge, alpha) }
                switch Int(time * 5 + leaf.phase) % 4 {
                case 0: put(x - 1, y, depth == 1 ? body : edge, alpha)
                case 2: put(x, y + 1, depth == 1 ? body : edge, alpha)
                default: break
                }
            }
        }
    }

    private func fade(_ landed: Double?, _ rest: Double) -> Double {
        guard let landed else { return 1 }
        return max(0, min(1, 1 - (time - landed - rest) / MeadowTune.fadeOut))
    }
}

// MARK: - The strip

/// The meadow in a layer of its own: each frame is a bitmap the size of the
/// grid, which Core Animation scales up without smoothing. No SwiftUI
/// update per frame, and the timer stops while the window can't be seen.
final class MeadowView: NSView {
    let meadow: Meadow
    var colors = MeadowColors(dark: true) { didSet { if colors != oldValue { render() } } }
    private var timer: Timer?
    private var rate = 0.0
    private var last = Date.now

    init(seed: UInt64) {
        meadow = Meadow(seed: seed)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.magnificationFilter = .nearest
        layer?.contentsGravity = .resize
        meadow.resize(260)
        for _ in 0..<Int(MeadowTune.warmUp * MeadowTune.fps) { meadow.step(1 / MeadowTune.fps) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        schedule()
    }

    @objc private func occlusionChanged() { schedule() }

    private func schedule() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let wanted = visible && !still ? (meadow.isShaking || !meadow.loosening.isEmpty ? MeadowTune.shakeFPS : MeadowTune.fps) : 0
        guard wanted != rate else { return }
        timer?.invalidate()
        timer = nil
        if timer == nil, rate == 0 { last = .now }
        rate = wanted
        if wanted > 0 {
            let timer = Timer(timeInterval: 1 / wanted, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 0.2 / wanted
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        render()
    }

    private func tick() {
        let now = Date.now
        // A long gap (asleep, hidden) skips ahead in one modest step.
        meadow.step(min(now.timeIntervalSince(last), 0.25))
        last = now
        render()
        schedule()  // Back to the resting rate once a sway is over.
    }

    override func layout() {
        super.layout()
        render()
    }

    private func render() {
        let cols = Int(bounds.width / MeadowTune.pixel) + 1, rows = MeadowTune.rows
        guard bounds.width > 0 else { return }
        meadow.resize(cols)
        let pixels = meadow.pixels(colors)
        var bytes = [UInt8](repeating: 0, count: cols * rows * 4)
        for (i, argb) in pixels.enumerated() where argb != 0 {
            let alpha = argb >> 24 == 0 ? 255 : argb >> 24
            // Premultiplied RGBA.
            bytes[i * 4] = UInt8((argb >> 16 & 0xFF) * alpha / 255)
            bytes[i * 4 + 1] = UInt8((argb >> 8 & 0xFF) * alpha / 255)
            bytes[i * 4 + 2] = UInt8((argb & 0xFF) * alpha / 255)
            bytes[i * 4 + 3] = UInt8(alpha)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The bitmap covers whole pixels, a little past the right edge.
        layer?.contentsGravity = .topLeft
        layer?.contentsScale = 1 / MeadowTune.pixel
        layer?.contents = image
        CATransaction.commit()
    }

    /// Only the tree takes clicks; the rest of the strip lets them through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return meadow.isTree(Double(local.x / MeadowTune.pixel), Double(local.y / MeadowTune.pixel)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        meadow.shake(at: (Double(point.x / MeadowTune.pixel), Double(point.y / MeadowTune.pixel)))
        schedule()
    }
}

struct MeadowStrip: NSViewRepresentable {
    let seed: UInt64
    @Environment(\.palette) private var palette

    func makeNSView(context: Context) -> MeadowView { MeadowView(seed: seed) }

    func updateNSView(_ view: MeadowView, context: Context) {
        view.colors = MeadowColors(dark: palette.dark)
    }
}

/// The strip with its fade at the top, sitting on the window's bottom edge.
struct Meadowland: View {
    /// The tree it grows: one per window, so it stays the same tree for as
    /// long as the window is open.
    let seed: UInt64
    @Environment(\.palette) private var palette

    var body: some View {
        MeadowStrip(seed: seed)
            .frame(height: CGFloat(MeadowTune.rows) * MeadowTune.pixel)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: MeadowTune.fadeIn), .init(color: .black, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .opacity(palette.dark ? MeadowTune.opacityDark : MeadowTune.opacityLight)
    }
}

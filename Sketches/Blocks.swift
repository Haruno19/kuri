// Blocks: KPI tiles and charts the model writes as fenced blocks of JSON
// (```kpi, ```chart) and the chat draws natively, with Swift Charts. A reply
// is split around those fences; the text in between goes through the app's
// own Markdown renderer, compiled alongside. Shown: the reply as the app
// would draw it, KPI tiles in two styles, the placeholder while a block is
// still streaming, and the fallback when the JSON doesn't fit the schema.
//
//   K=App; swiftc -parse-as-library -default-isolation MainActor -O Sketches/Blocks.swift $K/Views/Markdown.swift $K/Views/CodeBlock.swift $K/Style/*.swift -o /tmp/blocks && /tmp/blocks
//
// BLOCKS_RENDER=<folder> writes blocks-light.png and blocks-dark.png there and quits.
// In the window, "Riproduci" streams the reply in again, to tune the motion.

import AppKit
import Charts
import CoreText
import SwiftUI

// MARK: - Timing

/// The blocks' motion, in one place to tune.
enum BlockTune {
    /// Seconds for a placeholder to breathe in and out once.
    static let breathe = 1.6
    /// A finished block taking the placeholder's place.
    static let reveal = Animation.spring(response: 0.45, dampingFraction: 0.9)
    /// Bars and lines growing from the baseline once the block is in.
    static let grow = Animation.spring(response: 0.7, dampingFraction: 0.86)
    /// Delay before growing, so the panel has settled first.
    static let growDelay = 0.08
    /// The tooltip following the pointer.
    static let hover = Animation.easeOut(duration: 0.12)
    /// Streaming in the window: characters per tick, and the tick.
    static let streamChunk = 9
    static let streamTick = 0.025
}

enum Sketch {
    /// Set while writing PNGs: everything in its final state, no motion.
    static var rendering = false
}

// MARK: - Schema

/// One tile: what the model fills in. Values are strings so the model
/// formats them for the reader (currency, units, its own locale).
struct KPI: Decodable {
    let label: String
    let value: String
    var delta: String?
    /// Which way is good: `up` (the default) or `down`, for costs, returns…
    var good: String?
    /// What the delta compares against: "vs ottobre".
    var note: String?
    /// A dozen points or fewer, oldest first.
    var spark: [Double]?

    enum CodingKeys: String, CodingKey { case label, value, delta, good, note, spark }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        // A bare number is fine too.
        if let s = try? c.decode(String.self, forKey: .value) { value = s }
        else { value = try c.decode(Double.self, forKey: .value).formatted() }
        delta = try c.decodeIfPresent(String.self, forKey: .delta)
        good = try c.decodeIfPresent(String.self, forKey: .good)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        spark = try c.decodeIfPresent([Double].self, forKey: .spark)
    }

    enum Trend { case up, down, flat }

    /// Read from the delta's sign, so the model can't contradict itself.
    var trend: Trend {
        guard let first = delta?.trimmingCharacters(in: .whitespaces).first else { return .flat }
        if "+↑▲".contains(first) { return .up }
        if "-−↓▼".contains(first) { return .down }
        return .flat
    }

    /// Whether the change is good news: colour follows meaning, not sign.
    var isGood: Bool? {
        switch trend {
        case .flat: nil
        case .up: good != "down"
        case .down: good == "down"
        }
    }
}

struct ChartSpec: Decodable {
    enum Kind: String, Decodable { case bar, line, area, pie }
    let type: Kind
    var title: String?
    /// The axes' names.
    var x: String?
    var y: String?
    /// Appended to values in the tooltip and the table: "€", "%", "k".
    var unit: String?
    let data: [Row]

    struct Row: Decodable, Identifiable {
        let id = UUID()
        let x: String
        let y: Double
        var series: String?

        enum CodingKeys: String, CodingKey { case x, y, series }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let s = try? c.decode(String.self, forKey: .x) { x = s }
            else { x = try c.decode(Double.self, forKey: .x).formatted() }
            y = try c.decode(Double.self, forKey: .y)
            series = try c.decodeIfPresent(String.self, forKey: .series)
        }

        var name: String { series ?? "" }
    }

    /// Series in the order they first appear: colour follows the series.
    var series: [String] {
        var seen: [String] = []
        for row in data where !seen.contains(row.name) { seen.append(row.name) }
        return seen
    }

    var categories: [String] {
        var seen: [String] = []
        for row in data where !seen.contains(row.x) { seen.append(row.x) }
        return seen
    }

    func value(_ v: Double) -> String {
        let n = v.formatted(.number.precision(.fractionLength(0...1)))
        guard let unit else { return n }
        return ["€", "$", "£"].contains(unit) ? "\(unit) \(n)" : "\(n) \(unit)"
    }
}

// MARK: - Splitting a reply

enum Block {
    case text(String)
    case kpi([KPI])
    case chart(ChartSpec)
    /// A block fence that hasn't closed yet: the model is still writing it.
    case pending(String)
}

/// A reply cut into text and blocks. In the app this would happen in
/// `Markdown.blocks`, on the parser's own code blocks (so a fence inside a
/// longer fence stays code); a line scan is enough for the sketch.
enum Blocks {
    static let kinds: Set<String> = ["kpi", "chart"]
    /// More series than the palette has colours: the block shows as code.
    static let maxSeries = 5

    static func split(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var out: [Block] = []
        var buffer: [String] = []
        func flush() {
            let s = buffer.joined(separator: "\n")
            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(s)) }
            buffer = []
        }
        var i = 0
        while i < lines.count {
            let fence = lines[i].trimmingCharacters(in: .whitespaces)
            let kind = fence.hasPrefix("```") ? String(fence.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased() : ""
            guard kinds.contains(kind) else { buffer.append(lines[i]); i += 1; continue }
            var j = i + 1
            while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces) != "```" { j += 1 }
            if j == lines.count {
                flush()
                out.append(.pending(kind))
                return out
            }
            if let block = decode(kind, lines[(i + 1)..<j].joined(separator: "\n")) {
                flush()
                out.append(block)
            } else {
                // Not what the schema says: left as the code block it is.
                buffer += lines[i...j]
            }
            i = j + 1
        }
        flush()
        return out
    }

    static func decode(_ kind: String, _ json: String) -> Block? {
        let decoder = JSONDecoder()
        // Trailing commas and unquoted keys shouldn't cost the reader the chart.
        decoder.allowsJSON5 = true
        let data = Data(json.utf8)
        switch kind {
        case "kpi":
            if let list = try? decoder.decode([KPI].self, from: data), !list.isEmpty { return .kpi(list) }
            if let one = try? decoder.decode(KPI.self, from: data) { return .kpi([one]) }
            return nil
        case "chart":
            guard let spec = try? decoder.decode(ChartSpec.self, from: data), !spec.data.isEmpty,
                  spec.series.count <= maxSeries else { return nil }
            return .chart(spec)
        default:
            return nil
        }
    }
}

// MARK: - Colours

/// Series colours from the palette's own warm family, chestnut first.
/// Checked for colour-blind separation between neighbours in both themes;
/// the first two also hold for every pair (pies, scatter), the third not
/// quite in dark mode, where ochre sits close to chestnut.
enum SeriesColors {
    static let light: [UInt32] = [0xA65C20, 0x337AB0, 0xD29922, 0x29885E, 0xAF5594]
    static let dark: [UInt32] = [0xC0743B, 0x5492C5, 0xC08A11, 0x308E63, 0xC36DA8]

    static func all(dark: Bool) -> [Color] { (dark ? Self.dark : light).map { Color(hex: $0) } }
}

extension Palette {
    /// Good and bad news, as text: always beside an arrow, never colour alone.
    var good: Color { dark ? Color(hex: 0x8DBF94) : Color(hex: 0x2E7A4C) }
    var bad: Color { dark ? Color(hex: 0xE39478) : Color(hex: 0xA8452C) }
    /// The panel a block sits in: the code block's sibling, in the palette's neutrals.
    var blockFill: Color { dark ? Color(hex: 0x242220) : Color(hex: 0xFFFDF8) }
    var blockBorder: Color { dark ? Color(hex: 0x34312D) : Color(hex: 0xECE6D6) }
}

struct BlockPanel: ViewModifier {
    var padding: CGFloat = 14
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(palette.blockFill))
            .overlay(shape.strokeBorder(palette.blockBorder, lineWidth: 1))
    }
}

// MARK: - KPI

/// A: each figure in its own tile, the value in the interface's sans.
struct KPITiles: View {
    let items: [KPI]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, kpi in
                KPITile(kpi: kpi)
            }
        }
    }
}

struct KPITile: View {
    let kpi: KPI
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(kpi.label)
                .font(Typeface.sans(11.5))
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
            Text(kpi.value)
                .font(Typeface.sans(23).weight(.semibold))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            DeltaLine(kpi: kpi)
            if let spark = kpi.spark, spark.count > 1 {
                Sparkline(values: spark, good: kpi.isGood)
                    .frame(height: 22)
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(BlockPanel(padding: 12))
        .accessibilityElement(children: .combine)
    }
}

/// B: the figures straight on the surface, between rules, the value in the
/// model's serif: the reply's own voice rather than a dashboard dropped in.
struct KPIRuled: View {
    let items: [KPI]
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, kpi in
                if index > 0 {
                    Rectangle().fill(palette.faint.opacity(0.4)).frame(width: 1).padding(.horizontal, 16)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(kpi.label)
                        .font(Typeface.sans(11.5))
                        .foregroundStyle(palette.secondary)
                    Text(kpi.value)
                        .font(Typeface.serif(26).weight(.medium))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    DeltaLine(kpi: kpi)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }
}

struct DeltaLine: View {
    let kpi: KPI
    @Environment(\.palette) private var palette

    var body: some View {
        if let delta = kpi.delta {
            let color = kpi.isGood.map { $0 ? palette.good : palette.bad } ?? palette.secondary
            let arrow = switch kpi.trend { case .up: "↑"; case .down: "↓"; case .flat: "→" }
            // The model's own sign is dropped: the arrow says it.
            let number = delta.trimmingCharacters(in: CharacterSet(charactersIn: "+-−↑↓▲▼ "))
            HStack(spacing: 5) {
                Text("\(arrow) \(number)")
                    .font(Typeface.sans(11.5).weight(.medium))
                    .foregroundStyle(color)
                if let note = kpi.note {
                    Text(note).font(Typeface.sans(11.5)).foregroundStyle(palette.dim)
                }
            }
            .lineLimit(1)
        }
    }
}

/// The recent past in the quiet ink, the latest point in the colour of its news.
struct Sparkline: View {
    let values: [Double]
    let good: Bool?
    @Environment(\.palette) private var palette

    var body: some View {
        let last = values.count - 1
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("i", i), y: .value("v", v))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .foregroundStyle(palette.faint)
            }
            PointMark(x: .value("i", last), y: .value("v", values[last]))
                .symbolSize(22)
                .foregroundStyle(good.map { $0 ? palette.good : palette.bad } ?? palette.accent)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartLegend(.hidden)
        .accessibilityHidden(true)
    }
}

// MARK: - Charts

struct ChartBlock: View {
    let spec: ChartSpec
    @State private var showsTable = false
    @State private var selected: String?
    @State private var grown = Sketch.rendering
    @Environment(\.palette) private var palette

    static let height: CGFloat = 190

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Group {
                if showsTable {
                    DataTable(spec: spec)
                } else if spec.type == .pie {
                    PieChart(spec: spec, grown: grown)
                } else {
                    plot.frame(height: Self.height)
                }
            }
            if spec.type != .pie, spec.series.count > 1, !showsTable {
                Legend(names: spec.series)
            }
        }
        .modifier(BlockPanel())
        .onAppear {
            guard !grown else { return }
            withAnimation(BlockTune.grow.delay(BlockTune.growDelay)) { grown = true }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let title = spec.title {
                    Text(title).font(Typeface.sans(13).weight(.medium)).foregroundStyle(palette.ink)
                }
                if let y = spec.y, spec.type != .pie {
                    Text(y).font(Typeface.sans(11.5)).foregroundStyle(palette.dim)
                }
            }
            Spacer(minLength: 8)
            Button { withAnimation(Tune.snap) { showsTable.toggle() } } label: {
                Text(showsTable ? "Grafico" : "Tabella")
                    .font(Typeface.sans(11.5))
                    .foregroundStyle(palette.dim)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .modifier(HoverWash(shape: RoundedRectangle(cornerRadius: 6, style: .continuous)))
            }
            .buttonStyle(Squish())
        }
    }

    private var colors: [Color] { SeriesColors.all(dark: palette.dark) }
    private var multi: Bool { spec.series.count > 1 }

    private var plot: some View {
        let xName = spec.x ?? "x", yName = spec.y ?? "y"
        return Chart {
            ForEach(spec.data) { row in
                let y = grown ? row.y : 0
                switch spec.type {
                case .bar:
                    BarMark(x: .value(xName, row.x), y: .value(yName, y), width: .ratio(multi ? 0.78 : 0.56))
                        .foregroundStyle(by: .value("Serie", row.name))
                        .position(by: .value("Serie", row.name), axis: .horizontal, span: .ratio(0.92))
                        // Rounded at the value's end, flat on the baseline.
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3, style: .continuous))
                        .opacity(selected == nil || selected == row.x ? 1 : 0.4)
                case .line:
                    LineMark(x: .value(xName, row.x), y: .value(yName, y))
                        .foregroundStyle(by: .value("Serie", row.name))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                case .area:
                    AreaMark(x: .value(xName, row.x), y: .value(yName, y), stacking: multi ? .standard : .unstacked)
                        .foregroundStyle(by: .value("Serie", row.name))
                        .interpolationMethod(.monotone)
                        .opacity(0.22)
                    LineMark(x: .value(xName, row.x), y: .value(yName, y))
                        .foregroundStyle(by: .value("Serie", row.name))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                case .pie:
                    BarMark(x: .value(xName, row.x), y: .value(yName, y))
                }
            }
            if let selected {
                RuleMark(x: .value(xName, selected))
                    .foregroundStyle(spec.type == .bar ? .clear : palette.faint.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Tooltip(spec: spec, x: selected)
                    }
                if spec.type != .bar {
                    ForEach(spec.data.filter { $0.x == selected }) { row in
                        PointMark(x: .value(xName, row.x), y: .value(yName, row.y))
                            .foregroundStyle(by: .value("Serie", row.name))
                            .symbolSize(48)
                    }
                }
            }
        }
        .chartForegroundStyleScale(domain: spec.series, range: colors)
        .chartLegend(.hidden)
        .chartXSelection(value: $selected)
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel().font(Typeface.sans(11)).foregroundStyle(palette.dim)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(palette.faint.opacity(0.22))
                AxisValueLabel().font(Typeface.sans(11)).foregroundStyle(palette.dim)
            }
        }
        .animation(BlockTune.hover, value: selected)
    }
}

/// What the pointer is over: the category, then each series' value.
struct Tooltip: View {
    let spec: ChartSpec
    let x: String
    @Environment(\.palette) private var palette

    var body: some View {
        let colors = SeriesColors.all(dark: palette.dark)
        let rows = spec.data.filter { $0.x == x }
        VStack(alignment: .leading, spacing: 4) {
            Text(x).font(Typeface.sans(11)).foregroundStyle(palette.dim)
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    if spec.series.count > 1 {
                        Circle().fill(colors[spec.series.firstIndex(of: row.name) ?? 0]).frame(width: 7, height: 7)
                        Text(row.name).font(Typeface.sans(12)).foregroundStyle(palette.secondary)
                    }
                    Spacer(minLength: 10)
                    Text(spec.value(row.y)).font(Typeface.sans(12).weight(.medium)).foregroundStyle(palette.ink)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(minWidth: 96)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.card))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(palette.blockBorder, lineWidth: 1))
        .shadow(color: palette.shadow.opacity(palette.dark ? 0.35 : 0.1), radius: 6, y: 2)
    }
}

struct Legend: View {
    let names: [String]
    @Environment(\.palette) private var palette

    var body: some View {
        let colors = SeriesColors.all(dark: palette.dark)
        HStack(spacing: 14) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(colors[i]).frame(width: 9, height: 9)
                    Text(name).font(Typeface.sans(11.5)).foregroundStyle(palette.secondary)
                }
            }
        }
    }
}

/// A ring rather than a pie, every slice named beside it with its share:
/// identity never rests on colour alone.
struct PieChart: View {
    let spec: ChartSpec
    let grown: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        let colors = SeriesColors.all(dark: palette.dark)
        let total = spec.data.reduce(0) { $0 + $1.y }
        HStack(alignment: .center, spacing: 22) {
            Chart(spec.data) { row in
                SectorMark(angle: .value(spec.y ?? "y", row.y), innerRadius: .ratio(0.64), angularInset: 1.2)
                    .cornerRadius(3)
                    .foregroundStyle(by: .value("Voce", row.x))
            }
            .chartForegroundStyleScale(domain: spec.categories, range: colors)
            .chartLegend(.hidden)
            .chartBackground { _ in
                VStack(spacing: 0) {
                    Text(spec.value(total)).font(Typeface.sans(15).weight(.semibold)).foregroundStyle(palette.ink)
                    Text("totale").font(Typeface.sans(10.5)).foregroundStyle(palette.dim)
                }
            }
            .frame(width: 140, height: 140)
            .scaleEffect(grown ? 1 : 0.86)
            .opacity(grown ? 1 : 0)
            .rotationEffect(.degrees(grown ? 0 : -24))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                ForEach(Array(spec.data.enumerated()), id: \.offset) { i, row in
                    GridRow {
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2).fill(colors[i % colors.count]).frame(width: 9, height: 9)
                            Text(row.x).font(Typeface.sans(12.5)).foregroundStyle(palette.ink)
                        }
                        Text(spec.value(row.y)).font(Typeface.sans(12.5)).foregroundStyle(palette.secondary)
                            .gridColumnAlignment(.trailing)
                        Text((row.y / total).formatted(.percent.precision(.fractionLength(0))))
                            .font(Typeface.sans(12.5).weight(.medium)).foregroundStyle(palette.ink)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
        }
    }
}

/// The same data as numbers: for reading exact values, and for anyone the
/// chart doesn't reach.
struct DataTable: View {
    let spec: ChartSpec
    @Environment(\.palette) private var palette

    var body: some View {
        let series = spec.series
        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 6) {
            GridRow {
                Text(spec.x ?? "").gridColumnAlignment(.leading)
                ForEach(series, id: \.self) { name in
                    Text(name.isEmpty ? (spec.y ?? "") : name).gridColumnAlignment(.trailing)
                }
            }
            .font(Typeface.sans(11.5).weight(.medium))
            .foregroundStyle(palette.dim)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(spec.categories, id: \.self) { x in
                GridRow {
                    Text(x).font(Typeface.sans(12.5)).foregroundStyle(palette.ink)
                    ForEach(series, id: \.self) { name in
                        let v = spec.data.first { $0.x == x && $0.name == name }?.y
                        Text(v.map(spec.value) ?? "–")
                            .font(Typeface.mono(12 * 0.95))
                            .monospacedDigit()
                            .foregroundStyle(palette.secondary)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }
}

// MARK: - Streaming

/// Where a block will be, while its JSON is still arriving: its shape, breathing.
struct Placeholder: View {
    let kind: String
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        TimelineView(.animation(paused: still || Sketch.rendering)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = still || Sketch.rendering ? 0.5 : (sin(t * 2 * .pi / BlockTune.breathe) + 1) / 2
            let fill = palette.ink.opacity(palette.dark ? 0.06 + 0.04 * pulse : 0.045 + 0.035 * pulse)
            if kind == "kpi" {
                HStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            Capsule().fill(fill).frame(width: 54, height: 8)
                            Capsule().fill(fill).frame(width: 86, height: 18)
                            Capsule().fill(fill).frame(width: 64, height: 8)
                        }
                        .modifier(BlockPanel(padding: 12))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Capsule().fill(fill).frame(width: 120, height: 9)
                    HStack(alignment: .bottom, spacing: 14) {
                        ForEach([0.45, 0.62, 0.5, 0.78, 0.66, 0.9, 0.72], id: \.self) { h in
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(fill)
                                .frame(maxWidth: .infinity)
                                .frame(height: ChartBlock.height * 0.8 * h)
                        }
                    }
                    .frame(height: ChartBlock.height, alignment: .bottom)
                }
                .modifier(BlockPanel())
            }
        }
        .accessibilityLabel(kind == "kpi" ? "Indicatori in arrivo" : "Grafico in arrivo")
    }
}

// MARK: - A reply

enum KPIStyle { case tiles, ruled }

struct Reply: View {
    let text: String
    var kpiStyle: KPIStyle = .tiles

    var body: some View {
        let blocks = Blocks.split(text)
        VStack(alignment: .leading, spacing: 15 * 0.9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let markdown):
                    MarkdownView(text: markdown)
                case .kpi(let items):
                    Group {
                        switch kpiStyle {
                        case .tiles: KPITiles(items: items)
                        case .ruled: KPIRuled(items: items)
                        }
                    }
                    .transition(.opacity.combined(with: .scale(0.985, anchor: .top)))
                case .chart(let spec):
                    ChartBlock(spec: spec)
                        .transition(.opacity.combined(with: .scale(0.985, anchor: .top)))
                case .pending(let kind):
                    Placeholder(kind: kind).transition(.opacity)
                }
            }
        }
        .animation(BlockTune.reveal, value: blocks.map(\.shape))
    }
}

extension Block {
    /// What changes between streaming states, for animating the swap.
    var shape: String {
        switch self {
        case .text: "text"
        case .kpi: "kpi"
        case .chart: "chart"
        case .pending(let kind): "pending-\(kind)"
        }
    }
}

// MARK: - Samples

enum Samples {
    static let reply = """
        Ecco com'è andato **novembre** per il negozio: crescono ricavi e ordini, lo scontrino medio cala appena.

        ```kpi
        [
          {"label": "Ricavi", "value": "€ 18,4k", "delta": "+12%", "note": "vs ottobre", "spark": [12.1, 13.4, 13.0, 14.8, 15.2, 16.4, 18.4]},
          {"label": "Ordini", "value": "412", "delta": "+38", "note": "vs ottobre", "spark": [290, 310, 305, 340, 352, 374, 412]},
          {"label": "Resi", "value": "3,1%", "delta": "-0,4 pt", "good": "down", "note": "vs ottobre"},
          {"label": "Scontrino medio", "value": "€ 44,70", "delta": "-1,2%", "note": "vs ottobre"},
        ]
        ```

        Mese per mese, quest'anno contro l'anno scorso:

        ```chart
        {"type": "bar", "title": "Ricavi mensili", "x": "Mese", "y": "Migliaia di euro", "unit": "k€",
         "data": [
          {"x": "Giu", "y": 11.2, "series": "2025"}, {"x": "Giu", "y": 12.9, "series": "2026"},
          {"x": "Lug", "y": 10.4, "series": "2025"}, {"x": "Lug", "y": 12.1, "series": "2026"},
          {"x": "Ago", "y": 8.9, "series": "2025"}, {"x": "Ago", "y": 9.6, "series": "2026"},
          {"x": "Set", "y": 12.6, "series": "2025"}, {"x": "Set", "y": 14.8, "series": "2026"},
          {"x": "Ott", "y": 14.1, "series": "2025"}, {"x": "Ott", "y": 16.4, "series": "2026"},
          {"x": "Nov", "y": 15.3, "series": "2025"}, {"x": "Nov", "y": 18.4, "series": "2026"}
         ]}
        ```

        Le visite al sito sono salite soprattutto nelle ultime due settimane, con il Black Friday:

        ```chart
        {"type": "area", "title": "Visite per settimana", "x": "Settimana", "y": "Visite",
         "data": [{"x": "S40", "y": 3120}, {"x": "S41", "y": 3340}, {"x": "S42", "y": 3010}, {"x": "S43", "y": 3580},
                  {"x": "S44", "y": 3720}, {"x": "S45", "y": 3650}, {"x": "S46", "y": 4210}, {"x": "S47", "y": 5480}]}
        ```

        E da dove arrivano gli ordini:

        ```chart
        {"type": "pie", "title": "Ordini per canale", "y": "Ordini",
         "data": [{"x": "Sito", "y": 214}, {"x": "Instagram", "y": 102}, {"x": "Newsletter", "y": 61}, {"x": "Marketplace", "y": 35}]}
        ```

        Se vuoi, preparo un confronto per categoria di prodotto.
        """

    static let kpiOnly = """
        ```kpi
        [
          {"label": "Ricavi", "value": "€ 18,4k", "delta": "+12%", "note": "vs ottobre"},
          {"label": "Ordini", "value": "412", "delta": "+38", "note": "vs ottobre"},
          {"label": "Resi", "value": "3,1%", "delta": "-0,4 pt", "good": "down", "note": "vs ottobre"},
        ]
        ```
        """

    static let streaming = """
        Mese per mese, quest'anno contro l'anno scorso:

        ```chart
        {"type": "bar", "title": "Ricavi mensili", "x": "Mese", "y": "Migli
        """

    static let broken = """
        Un blocco che non rispetta lo schema resta codice:

        ```chart
        {"type": "radar", "data": [{"axis": "Prezzo", "value": 4}]}
        ```
        """
}

// MARK: - Board

struct Board: View {
    let scheme: ColorScheme
    @State private var shown = Samples.reply.count

    static let width: CGFloat = 640

    var body: some View {
        let palette = Palette(scheme: scheme)
        VStack(alignment: .leading, spacing: 30) {
            HStack {
                Text(scheme == .dark ? "Dark" : "Light")
                    .font(Typeface.sans(13).weight(.medium))
                    .foregroundStyle(palette.secondary)
                Spacer()
                if !Sketch.rendering {
                    Button(action: replay) {
                        Text("Riproduci").font(Typeface.sans(12)).padding(.horizontal, 10).padding(.vertical, 4)
                    }
                    .buttonStyle(SecondaryButton())
                }
            }
            section("A · la risposta, con le tessere") {
                Reply(text: String(Samples.reply.prefix(shown)))
            }
            section("B · le stesse cifre sulla superficie, in serif") {
                Reply(text: Samples.kpiOnly, kpiStyle: .ruled)
            }
            section("Mentre il blocco arriva") {
                Reply(text: Samples.streaming)
            }
            section("Se il JSON non torna") {
                Reply(text: Samples.broken)
            }
        }
        .padding(28)
        .frame(width: Self.width, alignment: .topLeading)
        .background(palette.background)
        .environment(\.palette, palette)
        .environment(\.colorScheme, scheme)
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Typeface.sans(11.5)).foregroundStyle(Palette(scheme: scheme).dim)
            content()
        }
    }

    private func replay() {
        shown = 0
        Task {
            while shown < Samples.reply.count {
                try? await Task.sleep(for: .seconds(BlockTune.streamTick))
                shown = min(Samples.reply.count, shown + BlockTune.streamChunk)
            }
        }
    }
}

// MARK: - App

@main struct BlocksSketch: App {
    init() {
        // The app's bundled faces, from the repository.
        let fonts = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "App/Fonts")
        for url in (try? FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil)) ?? []
        where ["ttf", "otf"].contains(url.pathExtension) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        if let folder = ProcessInfo.processInfo.environment["BLOCKS_RENDER"] {
            Sketch.rendering = true
            for scheme in [ColorScheme.light, .dark] {
                let renderer = ImageRenderer(content: Board(scheme: scheme))
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(filePath: folder).appending(path: "blocks-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Blocks") {
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    Board(scheme: .light)
                    Board(scheme: .dark)
                }
            }
            .frame(minWidth: Board.width * 2, minHeight: 760)
        }
    }
}

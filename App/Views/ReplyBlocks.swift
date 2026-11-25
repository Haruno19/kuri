import Charts
import KuriAgent
import SwiftUI

// Key figures and charts a model writes as fenced blocks of JSON (```kpi,
// ```chart) and the chat draws natively (decision 0026, tried in
// Sketches/Blocks.swift). The engine describes the schema in the
// instructions; here it's read back. A block that doesn't fit the schema
// stays the code block it is.

// MARK: - Schema

/// One key figure. Values are strings so the model formats them for the
/// reader: currency, units, its own locale.
struct KPI: Decodable {
    let label: String
    let value: String
    var delta: String?
    /// Which way is good news: `up` (the default) or `down`, for costs, returns…
    var good: String?
    /// What the delta compares against: "vs October".
    var note: String?
    /// A few recent values, oldest first.
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
    /// Put beside values in the tooltip, the table and the ring's legend.
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
    var series: [String] { Self.ordered(data.map(\.name)) }
    var categories: [String] { Self.ordered(data.map(\.x)) }

    private static func ordered(_ names: [String]) -> [String] {
        var seen: [String] = []
        for name in names where !seen.contains(name) { seen.append(name) }
        return seen
    }

    func value(_ v: Double) -> String {
        let n = v.formatted(.number.precision(.fractionLength(0...1)))
        guard let unit else { return n }
        return ["€", "$", "£", "¥"].contains(unit) ? "\(unit) \(n)" : "\(n) \(unit)"
    }
}

/// A block drawn from a fence, or why it isn't.
enum ReplyBlock {
    case kpi([KPI])
    case chart(ChartSpec)

    /// More series than there are colours: the block stays code.
    static let maxSeries = SeriesColors.light.count

    /// The block a fence holds, or nil when it isn't one or its JSON doesn't fit.
    static func decode(language: String?, _ source: String) -> ReplyBlock? {
        guard let kind = language.flatMap({ ReplyBlockKind(rawValue: $0.lowercased()) }) else { return nil }
        let decoder = JSONDecoder()
        // Trailing commas and unquoted keys shouldn't cost the reader the chart.
        decoder.allowsJSON5 = true
        let data = Data(source.utf8)
        if kind == .kpi {
            if let list = try? decoder.decode([KPI].self, from: data), !list.isEmpty { return .kpi(list) }
            return (try? decoder.decode(KPI.self, from: data)).map { .kpi([$0]) }
        }
        guard let spec = try? decoder.decode(ChartSpec.self, from: data), !spec.data.isEmpty,
              spec.series.count <= maxSeries, spec.type != .pie || spec.data.count <= maxSeries else { return nil }
        return .chart(spec)
    }
}

extension EnvironmentValues {
    /// On the reply that is still streaming: an unclosed block shows its
    /// placeholder, and finished ones grow in.
    @Entry var replyStreaming = false
}

// MARK: - Colours

/// Series colours from the palette's warm family, chestnut first. Checked
/// for colour-blind separation between neighbours in both themes; in dark
/// mode ochre sits close to chestnut when they aren't neighbours, which is
/// why the ring names every slice beside it.
enum SeriesColors {
    static let light: [UInt32] = [0xA65C20, 0x337AB0, 0xD29922, 0x29885E, 0xAF5594]
    static let dark: [UInt32] = [0xC0743B, 0x5492C5, 0xC08A11, 0x308E63, 0xC36DA8]

    static func all(dark: Bool) -> [Color] { (dark ? Self.dark : light).map { Color(hex: $0) } }
}

extension Palette {
    /// Good and bad news as text, at 4.5:1: always beside an arrow, never colour alone.
    var good: Color { dark ? Color(hex: 0x8DBF94) : Color(hex: 0x2E7A4C) }
    var bad: Color { dark ? Color(hex: 0xE39478) : Color(hex: 0xA8452C) }
    /// The panel a block sits in: the code block's sibling, in the palette's neutrals.
    var blockFill: Color { dark ? Color(hex: 0x242220) : Color(hex: 0xFFFDF8) }
    var blockBorder: Color { dark ? Color(hex: 0x34312D) : Color(hex: 0xECE6D6) }
}

private struct BlockPanel: ViewModifier {
    var padding: CGFloat = 14
    @Environment(\.palette) private var palette
    @Environment(\.chatScale) private var scale

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        content
            .padding(padding * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(palette.blockFill))
            .overlay(shape.strokeBorder(palette.blockBorder, lineWidth: 1))
    }
}

// MARK: - Views

/// A block in a reply, growing in when it arrives while the reply streams.
struct ReplyBlockView: View {
    let block: ReplyBlock

    var body: some View {
        switch block {
        case .kpi(let items): KPITiles(items: items)
        case .chart(let spec): ChartBlock(spec: spec)
        }
    }
}

/// Key figures, each in its own tile, sharing the reply's width.
private struct KPITiles: View {
    let items: [KPI]
    @Environment(\.chatScale) private var scale

    /// The narrowest a tile gets before the row wraps.
    static let minWidth: CGFloat = 132

    var body: some View {
        FlexRows(minWidth: Self.minWidth * scale, spacing: 10 * scale) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, kpi in
                KPITile(kpi: kpi)
            }
        }
    }
}

/// Like CSS flex with wrapping and grow: as many views in a row as fit at
/// `minWidth`, the rows balanced (five go 3 + 2, not 4 + 1), and each row's
/// views sharing its whole width at the height of the tallest.
private struct FlexRows: Layout {
    var minWidth: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? CGFloat(subviews.count) * (minWidth + spacing) - spacing
        let rows = rows(subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.range {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: row.itemWidth, height: row.height))
                x += row.itemWidth + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        let range: Range<Int>
        let itemWidth: CGFloat
        let height: CGFloat
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        let count = subviews.count
        guard count > 0 else { return [] }
        let fit = max(1, Int((width + spacing) / (minWidth + spacing)))
        let rowCount = (count + min(count, fit) - 1) / min(count, fit)
        let perRow = (count + rowCount - 1) / rowCount
        return stride(from: 0, to: count, by: perRow).map { start in
            let range = start..<min(count, start + perRow)
            let itemWidth = (width - spacing * CGFloat(range.count - 1)) / CGFloat(range.count)
            let height = range.map { subviews[$0].sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height }.max() ?? 0
            return Row(range: range, itemWidth: itemWidth, height: height)
        }
    }
}

private struct KPITile: View {
    let kpi: KPI
    @Environment(\.palette) private var palette
    @Environment(\.chatScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * scale) {
            Text(kpi.label)
                .font(Typeface.sans(11.5 * scale))
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
            Text(kpi.value)
                .font(Typeface.sans(23 * scale).weight(.semibold))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            DeltaLine(kpi: kpi)
            if let spark = kpi.spark, spark.count > 1 {
                Sparkline(values: spark, good: kpi.isGood)
                    .frame(height: 22 * scale)
                    .padding(.top, 3 * scale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(BlockPanel(padding: 12))
        .accessibilityElement(children: .combine)
    }
}

private struct DeltaLine: View {
    let kpi: KPI
    @Environment(\.palette) private var palette
    @Environment(\.chatScale) private var scale

    var body: some View {
        if let delta = kpi.delta {
            let color = kpi.isGood.map { $0 ? palette.good : palette.bad } ?? palette.secondary
            let arrow = switch kpi.trend { case .up: "↑"; case .down: "↓"; case .flat: "→" }
            // The model's own sign is dropped: the arrow says it.
            let number = delta.trimmingCharacters(in: CharacterSet(charactersIn: "+-−↑↓▲▼ "))
            HStack(spacing: 5 * scale) {
                Text(verbatim: "\(arrow) \(number)")
                    .font(Typeface.sans(11.5 * scale).weight(.medium))
                    .foregroundStyle(color)
                if let note = kpi.note {
                    Text(note).font(Typeface.sans(11.5 * scale)).foregroundStyle(palette.dim)
                }
            }
            .lineLimit(1)
        }
    }
}

/// The recent past in the quiet ink, the latest point in the colour of its news.
private struct Sparkline: View {
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

private struct ChartBlock: View {
    let spec: ChartSpec
    @State private var showsTable = false
    @State private var selected: String?
    @State private var grown = false
    @Environment(\.palette) private var palette
    @Environment(\.chatScale) private var scale

    /// The plot's height, which the placeholder keeps while the block streams.
    static let height: CGFloat = 190

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            header
            Group {
                if showsTable {
                    DataTable(spec: spec)
                } else if spec.type == .pie {
                    RingChart(spec: spec, grown: grown)
                } else {
                    plot.frame(height: Self.height * scale)
                }
            }
            if spec.type != .pie, spec.series.count > 1, !showsTable {
                Legend(names: spec.series)
            }
        }
        .modifier(BlockPanel())
        .modifier(GrowsIn(grown: $grown))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let title = spec.title {
                    Text(title).font(Typeface.sans(13 * scale).weight(.medium)).foregroundStyle(palette.ink)
                }
                if let y = spec.y, spec.type != .pie {
                    Text(y).font(Typeface.sans(11.5 * scale)).foregroundStyle(palette.dim)
                }
            }
            Spacer(minLength: 8)
            Button { withAnimation(Tune.snap) { showsTable.toggle() } } label: {
                Text(showsTable ? "Chart" : "Table")
                    .font(Typeface.sans(11.5 * scale))
                    .foregroundStyle(palette.dim)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .modifier(HoverWash(shape: RoundedRectangle(cornerRadius: 6, style: .continuous)))
            }
            .buttonStyle(Squish())
        }
    }

    private var multi: Bool { spec.series.count > 1 }

    private var plot: some View {
        let xName = spec.x ?? "x", yName = spec.y ?? "y"
        return Chart {
            ForEach(spec.data) { row in
                let y = grown ? row.y : 0
                switch spec.type {
                case .bar:
                    BarMark(x: .value(xName, row.x), y: .value(yName, y), width: .ratio(multi ? 0.78 : 0.56))
                        .foregroundStyle(by: .value("Series", row.name))
                        .position(by: .value("Series", row.name), axis: .horizontal, span: .ratio(0.92))
                        // Rounded at the value's end, flat on the baseline.
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3, style: .continuous))
                        .opacity(selected == nil || selected == row.x ? 1 : 0.4)
                case .line:
                    LineMark(x: .value(xName, row.x), y: .value(yName, y))
                        .foregroundStyle(by: .value("Series", row.name))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                case .area:
                    AreaMark(x: .value(xName, row.x), y: .value(yName, y), stacking: multi ? .standard : .unstacked)
                        .foregroundStyle(by: .value("Series", row.name))
                        .interpolationMethod(.monotone)
                        .opacity(0.22)
                    LineMark(x: .value(xName, row.x), y: .value(yName, y))
                        .foregroundStyle(by: .value("Series", row.name))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                case .pie:
                    // Drawn by `RingChart`.
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
                            .foregroundStyle(by: .value("Series", row.name))
                            .symbolSize(48)
                    }
                }
            }
        }
        .chartForegroundStyleScale(domain: spec.series, range: SeriesColors.all(dark: palette.dark))
        .chartLegend(.hidden)
        .chartXSelection(value: $selected)
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel().font(Typeface.sans(11 * scale)).foregroundStyle(palette.dim)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(palette.faint.opacity(0.22))
                AxisValueLabel().font(Typeface.sans(11 * scale)).foregroundStyle(palette.dim)
            }
        }
        .animation(Tune.hover, value: selected)
    }
}

/// Marks grow from the baseline when a block arrives in the streaming
/// reply; anywhere else (scrolling back, a finished reply) they're drawn
/// in place.
private struct GrowsIn: ViewModifier {
    @Binding var grown: Bool
    @Environment(\.replyStreaming) private var streaming
    @Environment(\.accessibilityReduceMotion) private var still

    func body(content: Content) -> some View {
        content.onAppear {
            guard !grown else { return }
            if streaming && !still {
                withAnimation(Tune.grow.delay(Tune.growDelay)) { grown = true }
            } else {
                grown = true
            }
        }
    }
}

/// What the pointer is over: the category, then each series' value.
private struct Tooltip: View {
    let spec: ChartSpec
    let x: String
    @Environment(\.palette) private var palette
    @Environment(\.chatScale) private var scale

    var body: some View {
        let colors = SeriesColors.all(dark: palette.dark)
        VStack(alignment: .leading, spacing: 4) {
            Text(x).font(Typeface.sans(11 * scale)).foregroundStyle(palette.dim)
            ForEach(spec.data.filter { $0.x == x }) { row in
                HStack(spacing: 6) {
                    if spec.series.count > 1 {
                        Circle().fill(colors[spec.series.firstIndex(of: row.name) ?? 0]).frame(width: 7, height: 7)
                        Text(row.name).font(Typeface.sans(12 * scale)).foregroundStyle(palette.secondary)
                    }
                    Spacer(minLength: 10)
                    Text(spec.value(row.y)).font(Typeface.sans(12 * scale).weight(.medium)).foregroundStyle(palette.ink)
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

private struct Legend: View {
    let names: [String]
    @Environment(\.palette) private var palette
    @Environment(\.chatScale) private var scale

    var body: some View {
        let colors = SeriesColors.all(dark: palette.dark)
        HStack(spacing: 14) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(colors[i]).frame(width: 9, height: 9)
                    Text(name).font(Typeface.sans(11.5 * scale)).foregroundStyle(palette.secondary)
                }
            }
        }
    }
}

/// A ring rather than a pie, every slice named beside it with its share:
/// identity never rests on colour alone.
private struct RingChart: View {
    let spec: ChartSpec
    let grown: Bool
    @Environment(\.palette) private var palette
    @Environment(\.chatScale) private var scale

    var body: some View {
        let colors = SeriesColors.all(dark: palette.dark)
        let total = spec.data.reduce(0) { $0 + $1.y }
        HStack(alignment: .center, spacing: 22 * scale) {
            Chart(spec.data) { row in
                SectorMark(angle: .value(spec.y ?? "y", row.y), innerRadius: .ratio(0.64), angularInset: 1.2)
                    .cornerRadius(3)
                    .foregroundStyle(by: .value("Slice", row.x))
            }
            .chartForegroundStyleScale(domain: spec.categories, range: colors)
            .chartLegend(.hidden)
            .chartBackground { _ in
                VStack(spacing: 0) {
                    Text(spec.value(total)).font(Typeface.sans(15 * scale).weight(.semibold)).foregroundStyle(palette.ink)
                    Text("total").font(Typeface.sans(10.5 * scale)).foregroundStyle(palette.dim)
                }
            }
            .frame(width: 140 * scale, height: 140 * scale)
            .scaleEffect(grown ? 1 : 0.86)
            .opacity(grown ? 1 : 0)
            .rotationEffect(.degrees(grown ? 0 : -24))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7 * scale) {
                ForEach(Array(spec.data.enumerated()), id: \.offset) { i, row in
                    GridRow {
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2).fill(colors[i % colors.count]).frame(width: 9, height: 9)
                            Text(row.x).font(Typeface.sans(12.5 * scale)).foregroundStyle(palette.ink)
                        }
                        Text(spec.value(row.y)).font(Typeface.sans(12.5 * scale)).foregroundStyle(palette.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(total > 0 ? (row.y / total).formatted(.percent.precision(.fractionLength(0))) : "–")
                            .font(Typeface.sans(12.5 * scale).weight(.medium)).foregroundStyle(palette.ink)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
        }
    }
}

/// The same data as numbers: for exact values, and for anyone the chart
/// doesn't reach.
private struct DataTable: View {
    let spec: ChartSpec
    @Environment(\.palette) private var palette
    @Environment(\.chatScale) private var scale

    var body: some View {
        let series = spec.series
        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 6 * scale) {
            GridRow {
                Text(spec.x ?? "")
                ForEach(series, id: \.self) { name in
                    Text(name.isEmpty ? (spec.y ?? "") : name).gridColumnAlignment(.trailing)
                }
            }
            .font(Typeface.sans(11.5 * scale).weight(.medium))
            .foregroundStyle(palette.dim)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(spec.categories, id: \.self) { x in
                GridRow {
                    Text(x).font(Typeface.sans(12.5 * scale)).foregroundStyle(palette.ink)
                    ForEach(series, id: \.self) { name in
                        let v = spec.data.first { $0.x == x && $0.name == name }?.y
                        Text(v.map(spec.value) ?? "–")
                            .font(Typeface.sans(12.5 * scale))
                            .monospacedDigit()
                            .foregroundStyle(palette.secondary)
                    }
                }
            }
        }
    }
}

/// Where a block will be while its JSON is still arriving: its shape,
/// breathing, so the reply doesn't show half a JSON and then jump.
struct ReplyBlockPlaceholder: View {
    let kind: ReplyBlockKind
    @Environment(\.palette) private var palette
    @Environment(\.chatScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        TimelineView(.animation(paused: still)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = still ? 0.5 : (sin(t * 2 * .pi / Tune.breathe) + 1) / 2
            let fill = palette.ink.opacity(palette.dark ? 0.06 + 0.04 * pulse : 0.045 + 0.035 * pulse)
            if kind == .kpi {
                HStack(spacing: 10 * scale) {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8 * scale) {
                            Capsule().fill(fill).frame(width: 54 * scale, height: 8 * scale)
                            Capsule().fill(fill).frame(width: 86 * scale, height: 18 * scale)
                            Capsule().fill(fill).frame(width: 64 * scale, height: 8 * scale)
                        }
                        .modifier(BlockPanel(padding: 12))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12 * scale) {
                    Capsule().fill(fill).frame(width: 120 * scale, height: 9 * scale)
                    HStack(alignment: .bottom, spacing: 14 * scale) {
                        ForEach([0.45, 0.62, 0.5, 0.78, 0.66, 0.9, 0.72], id: \.self) { h in
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(fill)
                                .frame(maxWidth: .infinity)
                                .frame(height: ChartBlock.height * scale * 0.8 * h)
                        }
                    }
                    .frame(height: ChartBlock.height * scale, alignment: .bottom)
                }
                .modifier(BlockPanel())
            }
        }
        .accessibilityElement()
        .accessibilityLabel(kind == .kpi ? "Figures on the way" : "Chart on the way")
    }
}

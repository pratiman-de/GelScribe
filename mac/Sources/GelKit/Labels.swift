import Foundation

/// Quick label entry in the notation used at the bench: one entry per lane, separated by `|`, and `{ }` to put lanes
/// under a label: `µM: Ladder|0{L|P}|50{L|P}|200{}`. Layers nest to any depth:
/// `WT{0{L|P}|50{L|P}}|KO{0{L|P}|50{L|P}}`.
public enum QuickLabels {
    /// Tokens that mean "this lane is the ladder" (case-insensitive).
    public static let ladderTokens: Set<String> = ["ladder", "marker", "m", "mw", "std", "standard", "lad", "size marker"]

    /// How many levels of `{ }` the notation may nest. A pasted wall of braces is refused instead of parsed, so it can't
    /// run the parser (or the code that walks what it makes) out of stack.
    public static let maxDepth = 32

    /// A lane, or a label over the lanes (and labels) in `items`.
    public indirect enum Item: Equatable, Sendable {
        case lane(String)
        case group(String, [Item])
    }

    /// `|`, tab or newline separate entries; `X{…}` puts the entries inside under X, and `X{}` is X over one blank
    /// lane. Surrounding whitespace is trimmed; empty entries are blank lanes. Braces left open are closed at the
    /// end, and stray closing ones dropped, each with a warning. Nested deeper than `maxDepth` it parses nothing and gives
    /// an `error` (also the only warning).
    public static func parse(_ text: String) -> (items: [Item], warnings: [String], error: String?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ([], [], nil) }
        let chars = Array(text)
        var i = 0
        var warnings: [String] = []
        var tooDeep = false
        func list(depth: Int) -> [Item] {
            var items: [Item] = []
            var label = ""
            var children: [Item]?
            func flush() {
                let t = unescape(label.trimmingCharacters(in: .whitespaces))
                items.append(children.map { .group(t, $0) } ?? .lane(t))
                label = ""
                children = nil
            }
            while i < chars.count {
                let c = chars[i]
                i += 1
                switch c {
                case "|", "\t", "\n", "\r":
                    flush()
                case "{":
                    if depth >= maxDepth { tooDeep = true; i = chars.count; return items }   // stop, all the way out
                    let inner = list(depth: depth + 1)
                    if tooDeep { return items }
                    if children == nil { children = inner } else {
                        children! += inner
                        warnings.append("“\(label.trimmingCharacters(in: .whitespaces))” has two { }; their lanes were joined.")
                    }
                case "}":
                    if depth == 0 { warnings.append("An extra } was ignored."); continue }
                    flush()
                    return items
                default:
                    label.append(c)
                }
            }
            if depth > 0 { warnings.append("A { was never closed; it was closed at the end.") }
            flush()
            return items
        }
        let items = list(depth: 0)
        if tooDeep {
            let why = "The labels nest more than \(maxDepth) levels of { }, so none of them were used."
            return ([], [why], why)
        }
        return (items, warnings, nil)
    }

    /// The lane labels in order.
    public static func lanes(_ items: [Item]) -> [String] {
        items.flatMap { item -> [String] in
            switch item {
            case .lane(let s): [s]
            case .group(_, let kids): lanes(kids)
            }
        }
    }

    /// Lanes a shorthand line describes (0 when it holds nothing but blanks).
    public static func laneCount(in text: String) -> Int {
        let items = parse(splitRowName(text).rest).items
        let labels = lanes(items)
        let anyGroup = items.contains { if case .group = $0 { true } else { false } }
        return labels.allSatisfy(\.isEmpty) && !anyGroup ? 0 : labels.count
    }

    public struct Result: Equatable, Sendable {
        /// Rows from the gel upward: the lane labels, then one group row per layer.
        public var rows: [LabelRow]
        /// Lane whose label was a ladder word, if any.
        public var ladderLane: Int?
        /// Lane labels as mapped onto lanes (one per lane).
        public var perLane: [String]
        public var warnings: [String]
        /// Set when the text was refused (nested too deep): nothing was built, and `GelOps.applyQuickLabels` left the project alone.
        public var error: String? = nil
    }

    /// Maps the entries onto `laneCount` lanes and builds the rows: the lane labels, then a group row per layer of
    /// `{ }`, nearest the lanes first. A label sits one row above the tallest thing under it, so a label directly
    /// over lanes is always in the row right above them.
    ///
    /// - A ladder word ("ladder", "M", "marker"…) reports `ladderLane` and stays as that lane's label.
    /// - With one lane fewer than there are lanes and a known ladder lane, the entries fill the other lanes.
    /// - `rowNames` title the group rows, listed from the top; they go to the rows nearest the lanes, so a single
    ///   title names the row right above the lane labels.
    public static func build(_ items: [Item], laneCount: Int, knownLadderLane: Int? = nil, rowNames: [String] = []) -> Result {
        var warnings: [String] = []
        var leaves: [String] = []
        var spans: [(text: String, first: Int, last: Int, layer: Int)] = []   // leaf indices, 0-based
        func walk(_ items: [Item]) -> Int {   // height of the tallest entry
            var height = 0
            for item in items {
                switch item {
                case .lane(let s):
                    leaves.append(s)
                case .group(let t, let kids):
                    let start = leaves.count
                    let h = walk(kids) + 1
                    if leaves.count > start { spans.append((t, start, leaves.count - 1, h)) }
                    height = max(height, h)
                }
            }
            return height
        }
        let layers = walk(items)

        // the ladder word marks the ladder lane and stays as its label, exactly as typed
        var ladderLane = leaves.firstIndex { ladderTokens.contains($0.lowercased()) }.map { $0 + 1 }
        var perLane = leaves
        if leaves.count == laneCount - 1, ladderLane == nil, let known = knownLadderLane, (1...laneCount).contains(known) {
            perLane.insert("", at: known - 1)
            ladderLane = known
            spans = spans.map { s in
                var s = s
                if s.first >= known - 1 { s.first += 1 }
                if s.last >= known - 1 { s.last += 1 }
                return s
            }
        }
        if laneCount == 0 {
            // no lanes yet: keep every label; each appears as soon as its lane exists
        } else if perLane.count > laneCount {
            warnings.append("\(perLane.count) labels for \(laneCount) lanes; extra labels dropped: " +
                            perLane[laneCount...].joined(separator: "|"))
            perLane = Array(perLane.prefix(laneCount))
            spans = spans.filter { $0.first < laneCount }.map { var s = $0; s.last = min(s.last, laneCount - 1); return s }
        } else if perLane.count < laneCount {
            warnings.append("\(perLane.count) labels for \(laneCount) lanes; the rest are blank.")
            perLane += Array(repeating: "", count: laneCount - perLane.count)
        }

        var rows = [LabelRow(type: .lanes, labels: perLane)]
        if layers > 0 {
            for layer in 1...layers {
                let groups = spans.filter { $0.layer == layer }.sorted { $0.first < $1.first }
                    .map { LabelGroup(text: $0.text, lanes: Array(($0.first + 1)...($0.last + 1))) }
                rows.append(LabelRow(type: .groups, groups: groups))
            }
        }
        for (k, name) in rowNames.reversed().enumerated() where k < layers {
            rows[1 + k].name = name.isEmpty ? nil : name
        }
        return Result(rows: rows, ladderLane: ladderLane, perLane: perLane, warnings: warnings)
    }

    /// A line break inside a label is written `\n` here, since a real new line separates entries.
    static func unescape(_ s: String) -> String { s.replacingOccurrences(of: "\\n", with: "\n") }
    static func escape(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "\\n") }

    /// One label per lane, no layers.
    public static func build(_ labels: [String], laneCount: Int, knownLadderLane: Int? = nil) -> Result {
        build(labels.map { .lane($0) }, laneCount: laneCount, knownLadderLane: knownLadderLane)
    }

    /// "µM: Ladder|0{L|P}" → (["µM"], "Ladder|0{L|P}"). Several layers take titles from the top, comma-separated:
    /// "Strain, µM: …". A title needs a letter or symbol, so "1:10|1:100" stays a pair of lane labels.
    public static func splitRowName(_ text: String) -> (names: [String], rest: String) {
        guard let colon = text.firstIndex(of: ":") else { return ([], text) }
        let head = text[..<colon]
        guard head.count <= 40, !head.contains(where: { "|{}\t\n".contains($0) }) else { return ([], text) }
        let names = head.split(separator: ",", omittingEmptySubsequences: false).map { unescape($0.trimmingCharacters(in: .whitespaces)) }
        guard names.contains(where: { !$0.isEmpty }),
              names.allSatisfy({ $0.isEmpty || $0.contains { !$0.isNumber && $0 != "." } }) else { return ([], text) }
        return (names, String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }

    /// The project's labels in the same shorthand, row titles first ("µM: Ladder|0{L|P}|…"). Round-trips through
    /// `parse` and `build` for labels made from it.
    public static func shorthand(_ p: GelProject) -> String {
        let laneRow = p.rows.first { $0.type == .lanes }
        let groupRows = p.rows.filter { $0.type == .groups }   // from the gel upward
        let n = max(p.laneCount, laneRow?.labels.count ?? 0, groupRows.flatMap(\.groups).map(\.last).max() ?? 0)
        guard n > 0, laneRow != nil || !groupRows.isEmpty else { return "" }
        func label(_ lane: Int) -> String { escape(laneRow.flatMap { lane <= $0.labels.count ? $0.labels[lane - 1] : nil } ?? "") }
        /// Entries for `lanes` from group row `layer` down (0 = the lane labels).
        func entries(_ lanes: ClosedRange<Int>, layer: Int) -> [String] {
            guard layer > 0 else { return lanes.map(label) }
            var out: [String] = []
            var lane = lanes.lowerBound
            while lane <= lanes.upperBound {
                if let g = groupRows[layer - 1].groups.first(where: { lane >= $0.first && lane <= $0.last }) {
                    let end = min(g.last, lanes.upperBound)
                    out.append(escape(g.text) + "{" + entries(lane...end, layer: layer - 1).joined(separator: "|") + "}")
                    lane = end + 1
                } else {
                    out += entries(lane...lane, layer: layer - 1)
                    lane += 1
                }
            }
            return out
        }
        var items = entries(1...n, layer: groupRows.count)
        while let last = items.last, last.isEmpty { items.removeLast() }
        let body = items.joined(separator: "|")
        var names = groupRows.reversed().map { escape($0.name ?? "") }   // from the top
        while let first = names.first, first.isEmpty { names.removeFirst() }
        return names.isEmpty ? body : names.joined(separator: ", ") + ": " + body
    }
}

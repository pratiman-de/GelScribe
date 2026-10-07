import CoreGraphics
import Foundation
import Testing
@testable import GelKit

@Suite struct MultilineLabels {
    private func project(_ labels: [String]) -> GelProject {
        var p = GelProject(image: "a.png")
        GelOps.setDividers(&p, xs: [100, 200, 300], imageWidth: 400, imageHeight: 300)
        p.rows = [LabelRow(type: .lanes, labels: labels)]
        return p
    }

    @Test func aSecondLineMakesTheRowTallerAndKeepsTheBottomLineOnTheBaseline() throws {
        let one = FigureLayoutEngine.layout(project(["WT", "A", "B", "C"]), imageWidth: 400, imageHeight: 300)
        let two = FigureLayoutEngine.layout(project(["WT\nKO", "A", "B", "C"]), imageWidth: 400, imageHeight: 300)
        let t1 = try #require(one.texts.first { $0.string == "WT" })
        let t2 = try #require(two.texts.first { $0.string == "WT\nKO" })
        #expect(t2.lines == ["WT", "KO"])
        #expect(abs(t2.bounds.height - t1.bounds.height - t2.lineHeight) < 0.01, "one line taller")
        // the gel moves down by the extra line (rounded up to its own pixel grid); the label's last line sits
        // where the single line did
        let drop = two.gelRect.minY - one.gelRect.minY
        #expect(drop >= t2.lineHeight - 0.01 && drop <= t2.lineHeight + two.ptPerPx + 0.01, "drop \(drop)")
        #expect(abs((t2.origin.y - two.gelRect.minY) - (t1.origin.y - one.gelRect.minY)) < 0.01)
        #expect(abs(t2.firstBaseline + t2.lineHeight) < 0.01)
    }

    @Test func namesOfSeveralLinesStayCentredOnTheirBand() throws {
        var p = project(["", "A", "B", "C"])
        p.annotations = [BandAnnotation(y: 150, text: "Protein\n(80 kDa)")]
        let l = FigureLayoutEngine.layout(p, imageWidth: 400, imageHeight: 300)
        let t = try #require(l.texts.first { $0.role == .annotation(0) })
        let bandY = l.point(x: 0, y: 150).y
        #expect(abs(t.bounds.midY - bandY) < 1.5, "block centre \(t.bounds.midY), band \(bandY)")
    }

    @Test func svgKeepsALabelAsOneTextWithALinePerSpan() {
        let l = FigureLayoutEngine.layout(project(["WT\nKO", "A", "B", "C"]), imageWidth: 400, imageHeight: 300)
        let svg = FigureRenderer.svg(l, gel: nil, info: ExportInfo(title: "", description: ""))
        #expect(svg.contains("<tspan") && svg.contains(">WT</tspan>") && svg.contains(">KO</tspan>"))
        #expect(!svg.contains("WT\nKO"))
    }

    @Test func lineBreaksRoundTripThroughQuickLabels() {
        var p = project([])
        _ = GelOps.applyQuickLabels(&p, text: "µM: |0{WT\\nKO|P}|125{L|P}")
        #expect(p.rows.first { $0.type == .lanes }?.labels.prefix(3) == ["", "WT\nKO", "P"])
        let text = QuickLabels.shorthand(p)
        #expect(text.contains("WT\\nKO") && !text.contains("WT\n"))
        var q = project([])
        _ = GelOps.applyQuickLabels(&q, text: text)
        #expect(q.rows == p.rows)
    }

    @Test func editingTheShorthandCanRemoveATitle() {
        var p = project([])
        _ = GelOps.applyQuickLabels(&p, text: "µM: |0{L|P}|125{L|P}")
        var kept = p, removed = p
        _ = GelOps.applyQuickLabels(&kept, text: "|0{L|P}|125{L|P}")   // pasting bare labels keeps the title
        _ = GelOps.applyQuickLabels(&removed, text: "|0{L|P}|125{L|P}", keepTitles: false)
        #expect(kept.rows.first { $0.type == .groups }?.name == "µM")
        #expect(removed.rows.first { $0.type == .groups }?.name ?? "" == "")
    }

    @Test func spreadingWithEqualGapsMatchesTheOriginal() {
        let targets: [Double] = [10, 11, 12, 30, 31, 60]
        let a = FigureLayoutEngine.spread1D(targets, sep: 7.7)
        let b = FigureLayoutEngine.spread1D(targets, gaps: Array(repeating: 7.7, count: targets.count))
        #expect(zip(a, b).allSatisfy { abs($0 - $1) < 1e-9 }, "\(a) vs \(b)")
    }
}

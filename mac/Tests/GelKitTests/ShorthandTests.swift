import CoreGraphics
import Foundation
import Testing
@testable import GelKit

@Suite struct Layers {
    @Test func bracesNestToThreeRows() {
        let text = "Strain, µM: WT{0{L|P}|125{L|P}}|KO{0{L|P}|125{L|P}}"
        var p = GelProject()
        let r = GelOps.applyQuickLabels(&p, text: text)
        #expect(r.warnings.isEmpty)
        #expect(p.rows.count == 3)
        #expect(p.rows[0].labels == ["L", "P", "L", "P", "L", "P", "L", "P"])
        #expect(p.rows[1].name == "µM" && p.rows[1].groups.map(\.text) == ["0", "125", "0", "125"])
        #expect(p.rows[1].groups.map(\.lanes) == [[1, 2], [3, 4], [5, 6], [7, 8]])
        #expect(p.rows[2].name == "Strain" && p.rows[2].groups.map(\.text) == ["WT", "KO"])
        #expect(p.rows[2].groups.map(\.lanes) == [[1, 2, 3, 4], [5, 6, 7, 8]])
        #expect(QuickLabels.shorthand(p) == text)
    }

    @Test func aLabelRightOverLanesSitsInTheRowRightAboveThem() {
        // B is over lanes directly, so it shares the row with the 1/2 groups, not the row with A
        let r = QuickLabels.build(QuickLabels.parse("A{1{x|y}|2{x|y}}|B{z|w}").items, laneCount: 6)
        #expect(r.rows[1].groups.map(\.text) == ["1", "2", "B"])
        #expect(r.rows[2].groups.map(\.text) == ["A"] && r.rows[2].groups[0].lanes == [1, 2, 3, 4])
    }

    @Test func blanksBracesAndOldShortcuts() {
        let r = QuickLabels.build(QuickLabels.parse("|0{L|P}|750{P}|1000{}|0L").items, laneCount: 6)
        #expect(r.rows[0].labels == ["", "L", "P", "P", "", "0L"])   // "0L" is just a label now
        #expect(r.rows[1].groups.map(\.text) == ["0", "750", "1000"])
        #expect(r.rows[1].groups.map(\.lanes) == [[2, 3], [4], [5]])
        #expect(r.ladderLane == nil)
    }

    @Test func unbalancedBracesAreRepairedWithAWarning() {
        let open = QuickLabels.parse("A{1|2")
        #expect(open.items == [.group("A", [.lane("1"), .lane("2")])] && open.warnings.count == 1)
        let stray = QuickLabels.parse("A|B}|C")
        #expect(QuickLabels.lanes(stray.items) == ["A", "B", "C"] && stray.warnings.count == 1)
    }

    @Test func titlesNeedLettersSoRatiosStayLabels() {
        #expect(QuickLabels.splitRowName("1:10|1:100").names.isEmpty)
        #expect(QuickLabels.splitRowName("µM: 0{L|P}").names == ["µM"])
        #expect(QuickLabels.splitRowName("Strain, µM: x").names == ["Strain", "µM"])
        // one title on three layers names the row right above the lane labels
        var p = GelProject()
        GelOps.applyQuickLabels(&p, text: "µM: WT{0{L|P}}|KO{0{L|P}}")
        #expect(p.rows[1].name == "µM" && p.rows[2].name == nil)
    }

    @Test func aKnownLadderLaneShiftsTheGroups() {
        var p = GelProject()
        GelOps.setDividers(&p, xs: [100, 200, 300, 400], imageWidth: 500, imageHeight: 300)   // 5 lanes
        p.ladder = Ladder(lane: 1)
        GelOps.applyQuickLabels(&p, text: "0{L|P}|125{L|P}")   // four labels: the ladder lane stays free
        #expect(p.rows[0].labels == ["", "L", "P", "L", "P"])
        #expect(p.rows[1].groups.map(\.lanes) == [[2, 3], [4, 5]])
    }

    @Test func titlesTypedEarlierStayWhenNoneAreTyped() {
        var p = GelProject()
        GelOps.applyQuickLabels(&p, text: "Strain, µM: WT{0{L|P}}|KO{0{L|P}}")
        GelOps.applyQuickLabels(&p, text: "WT{0{L|P}|5{L|P}}|KO{0{L|P}}")
        #expect(p.rows[1].name == "µM" && p.rows[2].name == "Strain")
    }
}

@Suite struct UnitLabel {
    func project(unitY: Double?) -> GelProject {
        var p = GelProject(image: "g.png")
        p.lanes.centers = [50, 150]
        p.ladder = Ladder(lane: 1, bands: [LadderBand(y: 100, size: 140), LadderBand(y: 300, size: 50)], unitY: unitY)
        return p
    }

    @Test func placedUnitSitsOnItsRow() {
        let l = FigureLayoutEngine.layout(project(unitY: 200), imageWidth: 200, imageHeight: 400)
        let unit = l.texts.first { $0.role == .ladderUnit }!
        let row = l.point(x: 0, y: 200).y
        #expect(abs(unit.bounds.midY - row) < 2)   // centered on gel row 200, beside the gel
        let auto = FigureLayoutEngine.layout(project(unitY: nil), imageWidth: 200, imageHeight: 400)
        #expect(auto.texts.first { $0.role == .ladderUnit }!.bounds.maxY < auto.gelRect.minY)   // default: above the gel
    }

    @Test func placementTravelsWithPositionsOnly() throws {
        let p = project(unitY: 200)
        let again = try JSONDecoder().decode(GelProject.self, from: try GelProject.encoder().encode(p))
        #expect(again.ladder?.unitY == 200)
        var other = GelProject(image: "h.png")
        LabelScheme(from: p, positions: false).apply(to: &other, imageWidth: 200, imageHeight: 400)
        #expect(other.ladder?.unitY == nil)
        LabelScheme(from: p, positions: true).apply(to: &other, imageWidth: 200, imageHeight: 400)
        #expect(other.ladder?.unitY == 200)
    }
}

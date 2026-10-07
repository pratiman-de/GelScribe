import Foundation

/// Apparent sizes of a prestained ladder on one gel chemistry and running buffer (vendor migration chart).
/// Lists run top to bottom and stop where bands run off the gel, so index i is always the same protein.
public struct LadderSystem: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var sizes: [Double]
    public init(_ id: String, _ name: String, _ sizes: [Double]) { self.id = id; self.name = name; self.sizes = sizes }
}

/// A ladder's nominal sizes, largest first. Built-in presets were read off vendor datasheets (see `source`);
/// user presets live in Application Support and can be anything.
public struct LadderPreset: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var vendor: String
    public var catalog: String
    /// Other catalog numbers for the same ladder (pack sizes).
    public var aliases: [String]
    public var unit: String
    /// Sizes on the reference system (the first of `systems` when there are any).
    public var sizes: [Double]
    /// Gel/buffer-specific apparent sizes, when the vendor publishes them.
    public var systems: [LadderSystem]
    /// Differently colored / brighter reference bands, if any.
    public var referenceBands: [Double]
    public var notes: String
    public var source: String
    public var builtin: Bool

    public init(id: String, name: String, vendor: String, catalog: String, aliases: [String] = [], unit: String,
                sizes: [Double], systems: [LadderSystem] = [], referenceBands: [Double] = [], notes: String = "",
                source: String = "", builtin: Bool = false) {
        self.id = id; self.name = name; self.vendor = vendor; self.catalog = catalog; self.aliases = aliases; self.unit = unit
        self.sizes = sizes; self.systems = systems; self.referenceBands = referenceBands; self.notes = notes
        self.source = source; self.builtin = builtin
    }

    enum CodingKeys: String, CodingKey { case id, name, vendor, catalog, aliases, unit, sizes, systems, referenceBands, notes, source, builtin }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        vendor = try c.decodeIfPresent(String.self, forKey: .vendor) ?? ""
        catalog = try c.decodeIfPresent(String.self, forKey: .catalog) ?? ""
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? "kDa"
        sizes = try c.decodeIfPresent([Double].self, forKey: .sizes) ?? []
        systems = try c.decodeIfPresent([LadderSystem].self, forKey: .systems) ?? []
        referenceBands = try c.decodeIfPresent([Double].self, forKey: .referenceBands) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        builtin = try c.decodeIfPresent(Bool.self, forKey: .builtin) ?? false
    }

    public var catalogs: String { ([catalog] + aliases).filter { !$0.isEmpty }.joined(separator: "/") }
    public var displayName: String { catalogs.isEmpty ? name : "\(name) (\(catalogs))" }

    public func system(named key: String?) -> LadderSystem? {
        guard let key else { return nil }
        let k = key.lowercased()
        return systems.first { $0.id == key || $0.name == key } ?? systems.first { $0.name.lowercased().contains(k) }
    }
}

/// Thermo's migration charts (MAN0011772 for PageRuler Prestained, MAN0011773 for PageRuler Plus).
/// Tris-acetate and Bis-Tris values were determined on NuPAGE precast gels.
private enum ThermoCharts {
    static let pagerulerPrestained: [LadderSystem] = {
        let tg = [180.0, 130, 100, 70, 55, 40, 35, 25, 15, 10]
        let ta = [150.0, 120, 85, 65, 50, 40, 30, 25]
        let mops = [140.0, 115, 80, 65, 50, 40, 30, 25, 15, 10]
        let mes = [140.0, 115, 80, 70, 50, 40, 30, 25, 15, 10]
        return [
            .init("tg-4-20", "Tris-glycine 4–20%", tg), .init("tg-8-16", "Tris-glycine 8–16%", tg),
            .init("tg-10-20", "Tris-glycine 10–20%", tg), .init("tg-8", "Tris-glycine 8%", Array(tg.prefix(9))),
            .init("tg-10", "Tris-glycine 10%", tg), .init("tg-12", "Tris-glycine 12%", tg), .init("tg-15", "Tris-glycine 15%", tg),
            .init("ta-3-8", "NuPAGE Tris-acetate 3–8%", ta), .init("ta-7", "NuPAGE Tris-acetate 7%", ta),
            .init("bt-4-12-mops", "NuPAGE Bis-Tris 4–12%, MOPS", mops), .init("bt-4-12-mes", "NuPAGE Bis-Tris 4–12%, MES", mes),
            .init("bt-10-mops", "NuPAGE Bis-Tris 10%, MOPS", Array(mops.prefix(9))), .init("bt-10-mes", "NuPAGE Bis-Tris 10%, MES", mes),
            .init("bt-12-mops", "NuPAGE Bis-Tris 12%, MOPS", Array(mops.prefix(9))), .init("bt-12-mes", "NuPAGE Bis-Tris 12%, MES", mes),
        ]
    }()

    static let pagerulerPlus: [LadderSystem] = {
        let tg = [250.0, 130, 100, 70, 55, 35, 25, 15, 10]
        let ta = [205.0, 120, 85, 65, 50, 30, 25]
        let mops = [185.0, 115, 80, 65, 50, 30, 25, 15, 10]
        let mes = [190.0, 115, 80, 70, 50, 30, 25, 15, 10]
        return [
            .init("tg-4-20", "Tris-glycine 4–20%", tg), .init("tg-8-16", "Tris-glycine 8–16%", tg),
            .init("tg-10-20", "Tris-glycine 10–20%", tg), .init("tg-8", "Tris-glycine 8%", Array(tg.prefix(8))),
            .init("tg-10", "Tris-glycine 10%", Array(tg.prefix(8))), .init("tg-12", "Tris-glycine 12%", tg),
            .init("tg-15", "Tris-glycine 15%", tg),
            .init("ta-3-8", "NuPAGE Tris-acetate 3–8%", ta), .init("ta-7", "NuPAGE Tris-acetate 7%", ta),
            .init("bt-4-12-mops", "NuPAGE Bis-Tris 4–12%, MOPS", mops), .init("bt-4-12-mes", "NuPAGE Bis-Tris 4–12%, MES", mes),
            .init("bt-10-mops", "NuPAGE Bis-Tris 10%, MOPS", Array(mops.prefix(8))), .init("bt-10-mes", "NuPAGE Bis-Tris 10%, MES", mes),
            .init("bt-12-mops", "NuPAGE Bis-Tris 12%, MOPS", Array(mops.prefix(8))), .init("bt-12-mes", "NuPAGE Bis-Tris 12%, MES", mes),
        ]
    }()
}

public enum LadderLibrary {
    /// Every list below was checked against the vendor's own datasheet or product page.
    public static let builtin: [LadderPreset] = [
        // MARK: protein
        .init(id: "thermo-pageruler-plus", name: "PageRuler Plus Prestained", vendor: "Thermo Scientific",
              catalog: "26619", aliases: ["26620", "26621"], unit: "kDa", sizes: [250, 130, 100, 70, 55, 35, 25, 15, 10],
              systems: ThermoCharts.pagerulerPlus, referenceBands: [70, 25, 10],
              notes: "70 and 25 kDa orange, 10 kDa green, others blue. At 700 nm the blue bands fluoresce; the orange ones are dim. Apparent sizes depend on the gel and buffer, so pick yours.",
              source: "https://assets.fishersci.com/TFS-Assets/LSG/manuals/MAN0011773_PgRuler_Plus_Prestain_Protein_Lad_UG.pdf", builtin: true),
        .init(id: "thermo-pageruler-prestained", name: "PageRuler Prestained", vendor: "Thermo Scientific",
              catalog: "26616", aliases: ["26617", "26618"], unit: "kDa", sizes: [180, 130, 100, 70, 55, 40, 35, 25, 15, 10],
              systems: ThermoCharts.pagerulerPrestained, referenceBands: [70, 10],
              notes: "70 kDa orange (dim at 700 nm), 10 kDa green, others blue. Apparent sizes depend on the gel and buffer, so pick yours.",
              source: "https://documents.thermofisher.com/TFS-Assets/LSG/manuals/MAN0011772_PgRuler_Prestain_Protein_Lad_UG.pdf", builtin: true),
        .init(id: "thermo-pageruler-nir", name: "PageRuler Prestained NIR", vendor: "Thermo Scientific",
              catalog: "26635", unit: "kDa", sizes: [250, 130, 95, 70, 55, 43, 34, 26, 15, 11],
              notes: "All bands labeled for the 700 nm channel.",
              source: "https://assets.fishersci.com/TFS-Assets/LSG/manuals/MAN0011747_PgRuler_Prestain_NIR_Protein_Lad_UG.pdf", builtin: true),
        .init(id: "thermo-spectra-br", name: "Spectra Multicolor Broad Range", vendor: "Thermo Scientific",
              catalog: "26634", unit: "kDa", sizes: [260, 140, 100, 70, 50, 40, 35, 25, 15, 10],
              source: "https://assets.fishersci.com/TFS-Assets/LSG/manuals/MAN0011774_Spectra_Multiclr_BrdRnge_Protein_Lad_UG.pdf", builtin: true),
        .init(id: "licor-chameleon-duo", name: "Chameleon Duo Pre-stained", vendor: "LI-COR",
              catalog: "928-60000", unit: "kDa", sizes: [260, 160, 125, 90, 70, 50, 38, 30, 25, 15, 8],
              notes: "700 nm shows 160, 125, 90, 50, 30, 15, 8; 800 nm shows 260, 70, 38, 25. Mark the bands you can't see as ignored.",
              source: "https://www.licorbio.com/support/contents/reagents/chameleon-pre-stained-protein-ladder/duo.html", builtin: true),
        .init(id: "licor-chameleon-800", name: "Chameleon 800 Pre-stained", vendor: "LI-COR",
              catalog: "928-80000", unit: "kDa", sizes: [260, 125, 70, 38, 25, 8],
              source: "https://www.licorbio.com/support/contents/reagents/chameleon-pre-stained-protein-ladder/800.html", builtin: true),
        .init(id: "biorad-precision-plus-dual", name: "Precision Plus Protein Dual Color", vendor: "Bio-Rad",
              catalog: "1610374", unit: "kDa", sizes: [250, 150, 100, 75, 50, 37, 25, 20, 15, 10], referenceBands: [75, 25],
              notes: "75 and 25 kDa pink reference bands.",
              source: "https://www.bio-rad.com/en-us/sku/1610374-precision-plus-protein-dual-color-standards-500-ul?ID=1610374", builtin: true),
        .init(id: "biorad-precision-plus-blue", name: "Precision Plus Protein All Blue", vendor: "Bio-Rad",
              catalog: "1610373", unit: "kDa", sizes: [250, 150, 100, 75, 50, 37, 25, 20, 15, 10],
              source: "https://www.bio-rad.com/en-us/sku/1610373-precision-plus-protein-all-blue-prestained-protein-standards?ID=1610373", builtin: true),
        .init(id: "biorad-precision-plus-kaleidoscope", name: "Precision Plus Protein Kaleidoscope", vendor: "Bio-Rad",
              catalog: "1610375", unit: "kDa", sizes: [250, 150, 100, 75, 50, 37, 25, 20, 15, 10],
              notes: "Loading buffer contains bromophenol blue, which gives a dye front at 700 nm.",
              source: "https://www.bio-rad.com/webroot/web/pdf/lsr/literature/4110182.pdf", builtin: true),
        .init(id: "invitrogen-seeblue-plus2", name: "SeeBlue Plus2 Pre-stained (Tris-glycine)", vendor: "Invitrogen",
              catalog: "LC5925", unit: "kDa", sizes: [250, 148, 98, 64, 50, 36, 22, 16, 6, 4],
              notes: "Apparent sizes on Tris-glycine gels; they differ a lot on NuPAGE Bis-Tris MES/MOPS. Edit the list to your gel's chart.",
              source: "https://www.thermofisher.com/order/catalog/product/LC5925", builtin: true),
        .init(id: "thermo-pageruler-unstained", name: "PageRuler Unstained", vendor: "Thermo Scientific",
              catalog: "26614", unit: "kDa", sizes: [200, 150, 120, 100, 85, 70, 60, 50, 40, 30, 25, 20, 15, 10],
              source: "https://www.thermofisher.com/order/catalog/product/26614", builtin: true),
        .init(id: "licor-chameleon-700", name: "Chameleon 700 Pre-stained", vendor: "LI-COR",
              catalog: "928-70000", unit: "kDa", sizes: [260, 160, 90, 50, 30, 15, 8],
              notes: "The 260 kDa band is visible by eye only; the others fluoresce at 700 nm.",
              source: "https://www.licorbio.com/support/contents/reagents/chameleon-pre-stained-protein-ladder/700.html", builtin: true),
        .init(id: "biorad-precision-plus-dual-xtra", name: "Precision Plus Protein Dual Xtra", vendor: "Bio-Rad",
              catalog: "1610377", unit: "kDa", sizes: [250, 150, 100, 75, 50, 37, 25, 20, 15, 10, 5, 2],
              source: "https://www.bio-rad.com/en-us/sku/1610377-precision-plus-protein-dual-xtra-prestained-protein-standards?ID=1610377", builtin: true),
        .init(id: "neb-p7719", name: "Color Prestained Protein Standard, Broad Range", vendor: "NEB",
              catalog: "P7719", unit: "kDa", sizes: [250, 180, 130, 95, 72, 55, 43, 34, 26, 17, 10],
              source: "https://www.neb.com/en-us/products/p7719-color-prestained-protein-standard-broad-range-10-250-kda", builtin: true),
        .init(id: "neb-p7718", name: "Blue Prestained Protein Standard, Broad Range", vendor: "NEB",
              catalog: "P7718", unit: "kDa", sizes: [250, 180, 130, 95, 72, 55, 43, 34, 26, 17, 11],
              source: "https://www.neb.com/en-us/products/p7718-blue-prestained-protein-standard-broad-range-11-250-kda", builtin: true),
        .init(id: "neb-p7712", name: "Color Prestained Protein Standard, Broad Range (legacy)", vendor: "NEB",
              catalog: "P7712", unit: "kDa", sizes: [245, 190, 135, 100, 80, 58, 46, 32, 25, 22, 17, 11],
              notes: "Discontinued; replaced by P7719.",
              source: "https://web.archive.org/web/20190825074152/https://www.neb.com/products/p7712-color-prestained-protein-standard-broad-range-11-245-kda", builtin: true),
        .init(id: "invitrogen-novex-sharp", name: "Novex Sharp Pre-stained", vendor: "Invitrogen",
              catalog: "LC5800", unit: "kDa", sizes: [260, 160, 110, 80, 60, 50, 40, 30, 20, 15, 10, 3.5],
              source: "https://www.thermofisher.com/order/catalog/product/LC5800", builtin: true),
        .init(id: "invitrogen-ibright-prestained", name: "iBright Prestained", vendor: "Invitrogen",
              catalog: "LC5615", unit: "kDa", sizes: [250, 130, 95, 80, 70, 55, 43, 34, 30, 26, 15, 11],
              source: "https://www.thermofisher.com/order/catalog/product/LC5615", builtin: true),
        .init(id: "abcam-ab116028", name: "Prestained Protein Ladder, Broad", vendor: "Abcam",
              catalog: "ab116028", unit: "kDa", sizes: [245, 180, 135, 100, 75, 63, 48, 35, 25, 20, 17, 11],
              source: "https://www.abcam.com/en-us/products/standards/prestained-protein-ladder-broad-molecular-weight-10-245-kda-ab116028", builtin: true),

        // MARK: DNA
        .init(id: "neb-1kb", name: "1 kb DNA Ladder", vendor: "NEB", catalog: "N3232", unit: "bp",
              sizes: [10000, 8000, 6000, 5000, 4000, 3000, 2000, 1500, 1000, 500], referenceBands: [3000],
              notes: "3.0 kb is the bright reference band. The 0.5 kb band is a 517 + 500 bp doublet.",
              source: "https://www.neb.com/en-us/products/n3232-1-kb-dna-ladder", builtin: true),
        .init(id: "neb-1kb-plus", name: "1 kb Plus DNA Ladder", vendor: "NEB", catalog: "N3200", unit: "bp",
              sizes: [10000, 8000, 6000, 5000, 4000, 3000, 2000, 1500, 1200, 1000, 900, 800, 700, 600, 500, 400, 300, 200, 100],
              referenceBands: [3000, 1000, 500],
              notes: "Formerly the 2-Log DNA Ladder; sizes read from NEB's 2-Log documentation. Not the same as Invitrogen's or Thermo's \"1 kb Plus\".",
              source: "https://www.neb.com/en-us/products/n3200-1-kb-plus-dna-ladder", builtin: true),
        .init(id: "neb-quickload-purple-1kb-plus", name: "Quick-Load Purple 1 kb Plus", vendor: "NEB", catalog: "N0550", unit: "bp",
              sizes: [10000, 8000, 6000, 5000, 4000, 3000, 2000, 1500, 1200, 1000, 900, 800, 700, 600, 500, 400, 300, 200, 100],
              referenceBands: [3000, 1000, 500],
              source: "https://www.neb.com/en-us/products/n0550-quick-load-purple-1-kb-plus-dna-ladder", builtin: true),
        .init(id: "neb-100bp", name: "100 bp DNA Ladder", vendor: "NEB", catalog: "N3231", unit: "bp",
              sizes: [1517, 1200, 1000, 900, 800, 700, 600, 500, 400, 300, 200, 100], referenceBands: [1000, 500],
              notes: "The 500 bp band is a 517 + 500 bp doublet.",
              source: "https://www.neb.com/en-us/products/n3231-100-bp-dna-ladder", builtin: true),
        .init(id: "neb-50bp", name: "50 bp DNA Ladder", vendor: "NEB", catalog: "N3236", unit: "bp",
              sizes: [1350, 916, 766, 700, 650, 600, 550, 500, 450, 400, 350, 300, 250, 200, 150, 100, 50], referenceBands: [500, 200],
              source: "https://www.neb.com/en-us/products/n3236-50-bp-dna-ladder", builtin: true),
        .init(id: "thermo-generuler-1kb", name: "GeneRuler 1 kb", vendor: "Thermo Scientific", catalog: "SM0311", unit: "bp",
              sizes: [10000, 8000, 6000, 5000, 4000, 3500, 3000, 2500, 2000, 1500, 1000, 750, 500, 250], referenceBands: [6000, 3000, 1000],
              source: "https://documents.thermofisher.com/TFS-Assets/LSG/manuals/MAN0013004_GeneRuler_1kb_DNALadder_250ug_UG.pdf", builtin: true),
        .init(id: "thermo-generuler-1kb-plus", name: "GeneRuler 1 kb Plus", vendor: "Thermo Scientific", catalog: "SM1331", unit: "bp",
              sizes: [20000, 10000, 7000, 5000, 4000, 3000, 2000, 1500, 1000, 700, 500, 400, 300, 200, 75], referenceBands: [5000, 1500, 500],
              source: "https://documents.thermofisher.com/TFS-Assets/LSG/manuals/MAN0013047_GeneRuler_1kb_Plus_DNALadder_250ug_UG.pdf", builtin: true),
        .init(id: "thermo-generuler-100bp-plus", name: "GeneRuler 100 bp Plus", vendor: "Thermo Scientific", catalog: "SM0321", unit: "bp",
              sizes: [3000, 2000, 1500, 1200, 1000, 900, 800, 700, 600, 500, 400, 300, 200, 100],
              source: "https://assets.fishersci.com/TFS-Assets/LSG/manuals/MAN0013008_GeneRuler_100bp_Plus_DNALadder_50ug_UG.pdf", builtin: true),
        .init(id: "thermo-generuler-50bp", name: "GeneRuler 50 bp", vendor: "Thermo Scientific", catalog: "SM0371", unit: "bp",
              sizes: [1000, 900, 800, 700, 600, 500, 400, 300, 250, 200, 150, 100, 50],
              source: "https://documents.thermofisher.com/TFS-Assets/LSG/manuals/MAN0013016_GeneRuler_50bp_DNALadder_50ug_UG.pdf", builtin: true),
        .init(id: "thermo-generuler-mix", name: "GeneRuler DNA Ladder Mix", vendor: "Thermo Scientific", catalog: "SM0331", unit: "bp",
              sizes: [10000, 8000, 6000, 5000, 4000, 3500, 3000, 2500, 2000, 1500, 1200, 1000, 900, 800, 700, 600, 500, 400, 300, 200, 100],
              source: "https://documents.thermofisher.com/TFS-Assets/LSG/manuals/MAN0013012_GeneRuler_DNALadder_250ug_UG.pdf", builtin: true),
        .init(id: "invitrogen-1kb-plus", name: "1 Kb Plus DNA Ladder", vendor: "Invitrogen", catalog: "10787018", unit: "bp",
              sizes: [15000, 10000, 8000, 7000, 6000, 5000, 4000, 3000, 2000, 1500, 1000, 850, 650, 500, 400, 300, 200, 100],
              source: "https://assets.fishersci.com/TFS-Assets/LSG/manuals/1Kb_Plus_DNA_ladder_man.pdf", builtin: true),
        .init(id: "invitrogen-egel-1kb-plus-express", name: "E-Gel 1 Kb Plus Express", vendor: "Invitrogen", catalog: "10488091", unit: "bp",
              sizes: [5000, 3000, 2000, 1500, 1000, 750, 500, 300, 100],
              source: "https://documents.thermofisher.com/TFS-Assets/LSG/manuals/egel_1kb_plus_express_ladder_man.pdf", builtin: true),
        .init(id: "promega-1kb", name: "1 kb DNA Ladder", vendor: "Promega", catalog: "G5711", unit: "bp",
              sizes: [10000, 8000, 6000, 5000, 4000, 3000, 2500, 2000, 1500, 1000, 750, 500, 250],
              notes: "Sizes read from a Promega application note, not the product datasheet; check your lot's datasheet.",
              source: "https://www.promega.com/-/media/files/resources/application-notes/dna-purification/an335---large-dna-size-selection-with-the-pronex-size-selective-purification-system.pdf", builtin: true),
    ]

    public static var userURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GelScribe", isDirectory: true).appendingPathComponent("ladders.json")
    }

    public static func loadUser() -> [LadderPreset] {
        guard let data = try? Data(contentsOf: userURL),
              let list = try? JSONDecoder().decode([LadderPreset].self, from: data) else { return [] }
        return list.map { var p = $0; p.builtin = false; return p }
    }

    public static func saveUser(_ presets: [LadderPreset]) throws {
        try FileManager.default.createDirectory(at: userURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try GelProject.encoder().encode(presets.filter { !$0.builtin })
        try data.write(to: userURL, options: .atomic)
    }

    public static func all() -> [LadderPreset] { builtin + loadUser() }

    public static func preset(id: String) -> LadderPreset? { all().first { $0.id == id } }

    /// Loose lookup for CLI/LLM use: id, catalog number, or a case-insensitive name fragment.
    public static func find(_ query: String) -> LadderPreset? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let list = all()
        return list.first { $0.id == q } ?? list.first { $0.catalog.lowercased() == q || $0.aliases.map { $0.lowercased() }.contains(q) }
            ?? list.first { $0.name.lowercased() == q }
            ?? list.first { $0.name.lowercased().contains(q) || $0.displayName.lowercased().contains(q) }
    }
}

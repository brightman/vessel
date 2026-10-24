import XCTest
@testable import CompanionCore

final class RecommendationTests: XCTestCase {
    private func hardware(_ gb: Int, appleSilicon: Bool = true) -> MacHardware {
        .init(memoryBytes: UInt64(gb) * 1_073_741_824, chip: appleSilicon ? "Apple M4" : "Intel", isAppleSilicon: appleSilicon)
    }
    func testSelectsOnlyPinnedModelsWithinConservativeMemoryPolicy() throws {
        let catalog = try CatalogModel.bundled()
        for gb in [8, 12] { XCTAssertEqual(ModelRecommendation.preferredID(hardware: hardware(gb), catalog: catalog), ModelRecommendation.lightweight) }
        for gb in [16, 24, 32, 64] { XCTAssertEqual(ModelRecommendation.preferredID(hardware: hardware(gb), catalog: catalog), ModelRecommendation.balanced) }
        XCTAssertFalse(ModelRecommendation.fits(ModelRecommendation.balanced, hardware: hardware(8)))
        XCTAssertTrue(ModelRecommendation.fits(ModelRecommendation.lightweight, hardware: hardware(8)))
        XCTAssertNil(ModelRecommendation.preferredID(hardware: hardware(4), catalog: catalog))
        XCTAssertNil(ModelRecommendation.preferredID(hardware: hardware(32, appleSilicon: false), catalog: catalog))
        XCTAssertNil(ModelRecommendation.preferredID(hardware: hardware(16), catalog: []))
        XCTAssertFalse(ModelRecommendation.fits("unlisted-model", hardware: hardware(64)))
    }
    func testTotalMemoryAndFileSizeRemainSeparate() throws {
        let largeFileModel = try XCTUnwrap(CatalogModel.bundled().first { $0.id == ModelRecommendation.balanced })
        let belowBoundary = MacHardware(memoryBytes: 16 * 1_073_741_824 - 1, chip: "Apple M4", isAppleSilicon: true)
        XCTAssertFalse(ModelRecommendation.fits(largeFileModel.id, hardware: belowBoundary))
        XCTAssertEqual(hardware(16).memoryGB, 16)
        XCTAssertTrue(ModelRecommendation.explanation(for: largeFileModel.id, hardware: hardware(16)).contains("16 GB"))
    }
}

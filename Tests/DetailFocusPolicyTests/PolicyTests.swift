import XCTest
@testable import DetailFocusPolicy
final class PolicyTests: XCTestCase {
  func testDetailNeverOverridesResourceBudget() {
    XCTAssertEqual(DetailFocusPolicy.depthInterval(normal: 0.5, constrained: true, active: true),0.5)
    XCTAssertEqual(DetailFocusPolicy.depthInterval(normal: 0.2, constrained: false, active: true),0.12)
    XCTAssertEqual(DetailFocusPolicy.depthInterval(normal: 0.2, constrained: false, active: false),0.2)
  }
  func testSmallDetailMovementAddsEvidenceButStationaryFramesDoNot() {
    XCTAssertTrue(DetailFocusPolicy.shouldRecord(elapsed: 0.2, interval: 0.12, moved: 0.02, turned: 0, detail: true))
    XCTAssertFalse(DetailFocusPolicy.shouldRecord(elapsed: 0.2, interval: 0.12, moved: 0.02, turned: 0, detail: false))
    XCTAssertFalse(DetailFocusPolicy.shouldRecord(elapsed: 0.2, interval: 0.12, moved: 0, turned: 0, detail: true))
  }
  func testBrushIsUnionOfLocalRegionsNotBoundingBox() {
    let centers: [SIMD3<Float>] = [SIMD3(-0.3,0,0),SIMD3(0.3,0,0)]
    XCTAssertTrue(DetailFocusPolicy.contains(SIMD3(0.32,0,0),centers: centers,radius: 0.07))
    XCTAssertFalse(DetailFocusPolicy.contains(.zero,centers: centers,radius: 0.07))
  }
  func testRecordedFramesAloneCannotDeclareEnoughEvidence() {
    XCTAssertFalse(DetailEvidencePolicy.sufficient(frames:10000,views:1))
    XCTAssertFalse(DetailEvidencePolicy.sufficient(frames:2,views:3))
    XCTAssertTrue(DetailEvidencePolicy.sufficient(frames:6,views:3))
  }
  func testDiversityRejectsSameDirectionAndInvalidVectors() {
    let front = SIMD3<Float>(0,0,1)
    XCTAssertFalse(DetailEvidencePolicy.newDirection(front,previous:[front]))
    XCTAssertFalse(DetailEvidencePolicy.newDirection(.zero,previous:[]))
    XCTAssertTrue(DetailEvidencePolicy.newDirection(SIMD3(1,0,0),previous:[front]))
  }
  func testDistanceAndBoundsDoNotIncludeBackground() {
    XCTAssertFalse(DetailEvidencePolicy.acceptsDistance(.nan))
    XCTAssertFalse(DetailEvidencePolicy.acceptsDistance(1.2))
    let bounds = CaptureBounds(minimum:SIMD3(-0.4,-0.5,-0.3),maximum:SIMD3(0.4,0.5,0.3))
    XCTAssertTrue(bounds.contains(.zero))
    XCTAssertFalse(bounds.contains(SIMD3(0,0,1)))
    XCTAssertEqual(CaptureScope.allCases.count,3)
  }
}

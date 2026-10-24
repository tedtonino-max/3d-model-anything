import XCTest
import SurfaceCore

final class SurfaceTests: XCTestCase {
  func testVolumeBudgetAndUnknownSpace() {
    XCTAssertNil(DFCreateVolume(512,512,512,0.006,0,0,0))
    XCTAssertNil(DFCreateVolume(20,20,20,0,0,0,0))
    guard let v=DFCreateVolume(16,16,16,0.01,0,0,-1) else {return XCTFail("allocation")}
    defer {DFDestroyVolume(v)}
    guard let m=DFExtractMesh(v,3,1) else {return XCTFail("extraction")}
    defer {DFDestroyMesh(m)}
    XCTAssertEqual(DFTriangleCount(m),0,"Unknown space must never become geometry")
  }
  func testPlanarFusionPreservesMeasuredPlaneAndReducesFaces() {
    guard let v=DFCreateVolume(41,41,41,0.01,-0.2,-0.2,-1.1) else {return XCTFail("allocation")}
    defer {DFDestroyVolume(v)}
    let depth=[Float](repeating:0.9,count:256*192),confidence=[UInt8](repeating:2,count:depth.count)
    let pose:[Float]=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]
    for _ in 0..<4 {
      let updated=depth.withUnsafeBufferPointer {d in confidence.withUnsafeBufferPointer {c in pose.withUnsafeBufferPointer {p in
        DFIntegrate(v,d.baseAddress,c.baseAddress,256,192,p.baseAddress,200,200,127,95)
      }}}
      XCTAssertGreaterThan(updated,0)
    }
    guard let dense=DFExtractMesh(v,3,0),let adapted=DFExtractMesh(v,3,1) else {return XCTFail("mesh")}
    defer {DFDestroyMesh(dense);DFDestroyMesh(adapted)}
    XCTAssertGreaterThan(DFTriangleCount(adapted),0)
    XCTAssertLessThan(DFTriangleCount(adapted),DFTriangleCount(dense)/2)
    XCTAssertGreaterThan(DFMergedPlanarQuads(adapted),0)
    guard let p=DFPositions(adapted),let ids=DFIndices(adapted) else {return XCTFail("buffers")}
    for i in 0..<Int(DFVertexCount(adapted)) {XCTAssertEqual(p[3*i+2],-0.9,accuracy:0.002)}
    for i in 0..<Int(DFTriangleCount(adapted))*3 {XCTAssertLessThan(ids[i],UInt32(DFVertexCount(adapted)))}
  }
}

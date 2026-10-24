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
  func testFloorWallJunctionAndDepthDiscontinuityStaySeparate() {
    guard let v=DFCreateVolume(51,51,91,0.006,-0.15,-0.30,-1.20) else {return XCTFail("allocation")}
    defer {DFDestroyVolume(v)}
    var depth=[Float](repeating:1,count:256*192)
    let confidence=[UInt8](repeating:2,count:depth.count)
    let pose:[Float]=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]
    for y in 96..<192 {for x in 0..<256 {depth[y*256+x]=min(1,0.15*200/Float(y-95))}}
    for _ in 0..<4 {depth.withUnsafeBufferPointer {d in confidence.withUnsafeBufferPointer {c in pose.withUnsafeBufferPointer {p in
      _=DFIntegrate(v,d.baseAddress,c.baseAddress,256,192,p.baseAddress,200,200,127,95)
    }}}}
    guard let m=DFExtractMesh(v,3,1),let p=DFPositions(m) else {return XCTFail("corner mesh")}
    defer {DFDestroyMesh(m)}
    XCTAssertGreaterThan(DFTriangleCount(m),0)
    var joint=Float.infinity,invalid=0
    for i in 0..<Int(DFVertexCount(m)) {
      let y=p[3*i+1],z=p[3*i+2]
      joint=min(joint,sqrt((y+0.15)*(y+0.15)+(z+1)*(z+1)))
      if abs(y+0.15)>0.015 && abs(z+1)>0.015 {invalid+=1}
    }
    XCTAssertLessThan(joint,0.012,"The floor/wall intersection must remain represented")
    XCTAssertEqual(invalid,0,"No unsupported surface between the measured planes")
  }
}

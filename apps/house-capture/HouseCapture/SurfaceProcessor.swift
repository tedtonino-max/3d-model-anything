import Foundation
import simd
import SurfaceCore

/// A bounded post-capture pass. Raw observations remain on disk. One local volume
/// is processed at a time, so a long room scan cannot grow an unbounded voxel map.
enum SurfaceProcessor {
  struct Report: Codable, Sendable {
    var status: String
    var processedFrames = 0
    var reconstructedFaces = 0
    var retainedBaseFaces = 0
    var mergedPlanarQuads = 0
    var voxelMeters: Float = 0
    var outputVertices = 0
    var outputFaces = 0
    var warning: String?
  }
  struct Mesh {
    var points: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var indices: [UInt32] = []
  }
  struct Cell: Hashable {
    var x:Int32; var y:Int32; var z:Int32
    init(_ p:SIMD3<Float>,step:Float) { x=Int32(floor(p.x/step)); y=Int32(floor(p.y/step)); z=Int32(floor(p.z/step)) }
  }
  enum Failure: LocalizedError {
    case missingSelection, noSurface, memoryBudget, invalidDepth, cancelled
    var errorDescription: String? {
      switch self {
      case .missingSelection: return "Kies eerst een objectkader of schilder een gebied."
      case .noSurface: return "Er zijn te weinig betrouwbare dieptemetingen voor een nieuw oppervlak. De basisscan en opnamen zijn bewaard."
      case .memoryBudget: return "Dit detailgebied is te groot voor het beschikbare werkgeheugen. De basisscan en opnamen zijn bewaard."
      case .invalidDepth: return "Een opgeslagen dieptebeeld is onleesbaar. De basisscan is bewaard."
      case .cancelled: return "Verwerking onderbroken; de basisscan en opnamen zijn bewaard."
      }
    }
  }
  static func process(bundle: ScanBundle,room:Int,scope:CaptureScope,objectBounds:CaptureBounds?,
                      regions:[DetailFocus.Region],progress:@escaping @Sendable (String)->Void) throws -> Report {
    let selected=regions.filter {$0.room == room && !$0.centers.isEmpty}
    if scope != .room && objectBounds == nil && selected.isEmpty { throw Failure.missingSelection }
    let path="mesh/room-\(room).ply",basePath="mesh/room-\(room)-base.ply"
    let fm=FileManager.default
    if !fm.fileExists(atPath:bundle.file(basePath).path),fm.fileExists(atPath:bundle.file(path).path) {
      try fm.copyItem(at:bundle.file(path),to:bundle.file(basePath))
    }
    var report=Report(status:"basis")
    let base=try? PLYMesh.load(url:bundle.file(basePath))
    let allRecords=try JSONDecoder().decode([DepthRecorder.Record].self,from:Data(contentsOf:bundle.file("depth/frames.json")))
      .filter {$0.room == room && $0.transform.count == 16 && $0.intrinsics.count == 9 && $0.width > 2 && $0.height > 2 && $0.width*$0.height <= 1024*768}
    func selectedPoint(_ p:SIMD3<Float>,padding:Float=0)->Bool {
      if let objectBounds,scope == .object { return objectBounds.contains(p,margin:padding) }
      return selected.contains { r in r.centers.enumerated().contains { simd_distance($0.element,p) <= r.radius(at:$0.offset)+padding } }
    }
    var bounds:[CaptureBounds]=[]
    if let objectBounds,scope == .object { bounds=[objectBounds] }
    else {
      for r in selected {
        var lo=SIMD3<Float>(repeating:.infinity),hi=SIMD3<Float>(repeating:-.infinity)
        for (i,c) in r.centers.enumerated() { let pad=SIMD3<Float>(repeating:r.radius(at:i)+0.025);lo=simd_min(lo,c-pad);hi=simd_max(hi,c+pad) }
        bounds.append(CaptureBounds(minimum:lo,maximum:hi))
      }
    }
    // Overlapping requests share one fusion volume, never duplicate surface layers.
    var merged=true
    while merged {
      merged=false
      outer: for i in bounds.indices { for j in bounds.indices where j>i {
        if (0..<3).allSatisfy({bounds[i].minimum[$0] <= bounds[j].maximum[$0]+0.02 && bounds[j].minimum[$0] <= bounds[i].maximum[$0]+0.02}) {
          bounds[i]=CaptureBounds(minimum:simd_min(bounds[i].minimum,bounds[j].minimum),maximum:simd_max(bounds[i].maximum,bounds[j].maximum))
          bounds.remove(at:j);merged=true;break outer
        }
      } }
    }
    var detail=Mesh()
    for (i,box) in bounds.enumerated() {
      if Task.isCancelled { throw Failure.cancelled }
      let candidates=allRecords.filter { visible(box,in:$0) }
      let frameStride=max(1,Int(ceil(Double(candidates.count)/400)))
      let records=candidates.enumerated().filter {$0.offset % frameStride == 0}.map(\.element)
      guard records.count >= 3 else { continue }
      let patch=try fuse(box:box,records:records,bundle:bundle,progress:{done in
        progress("Oppervlak \(i+1)/\(bounds.count) Â· \(done)/\(records.count) dieptebeelden")
      })
      report.processedFrames+=patch.frames;report.mergedPlanarQuads+=patch.merged
      report.voxelMeters=max(report.voxelMeters,patch.step)
      let offset=UInt32(detail.points.count)
      detail.points+=patch.mesh.points;detail.normals+=patch.mesh.normals
      for f in stride(from:0,to:patch.mesh.indices.count,by:3) {
        let ids=Array(patch.mesh.indices[f..<f+3]);let center=ids.reduce(SIMD3<Float>.zero){$0+patch.mesh.points[Int($1)]}/3
        if selectedPoint(center,padding:0.006) { detail.indices+=ids.map {$0+offset} }
      }
    }
    report.reconstructedFaces=detail.indices.count/3
    // Native faces remain where the reconstruction has no supported replacement.
    // Missing raw observations must never erase an otherwise usable base scan.
    var supported=Set<Cell>();let supportStep:Float=0.015
    for id in detail.indices { supported.insert(Cell(detail.points[Int(id)],step:supportStep)) }
    func hasReplacement(_ p:SIMD3<Float>)->Bool {
      let c=Cell(p,step:supportStep)
      for x in -1...1 {for y in -1...1 {for z in -1...1 {
        var n=c;n.x+=Int32(x);n.y+=Int32(y);n.z+=Int32(z)
        if supported.contains(n){return true}
      }}}
      return false
    }
    var output=detail
    if let base {
      let offset=UInt32(output.points.count)
      for i in 0..<base.vertexCount { output.points.append(base.position(i));output.normals.append(base.normal(i)) }
      for f in stride(from:0,to:base.indices.count,by:3) {
        let ids=Array(base.indices[f..<f+3]);let center=ids.reduce(SIMD3<Float>.zero){$0+base.position(Int($1))}/3
        let inside=selectedPoint(center)
        if scope != .room && !inside {continue}
        if inside && hasReplacement(center) {continue}
        output.indices+=ids.map {$0+offset};report.retainedBaseFaces+=1
      }
    }
    guard !output.indices.isEmpty else {throw Failure.noSurface}
    progress("Eindresultaat opslaanâ€¦")
    let written=try write(output,to:bundle.file(path))
    report.outputVertices=written.0;report.outputFaces=written.1
    report.status=report.reconstructedFaces>0 ? "verwerkt" : "alleen basisscan"
    if !bounds.isEmpty && report.reconstructedFaces == 0 {report.warning=Failure.noSurface.localizedDescription}
    try JSONEncoder().encode(report).write(to:bundle.file("details/result-room-\(room).json"),options:.atomic)
    return report
  }
  private static func visible(_ box:CaptureBounds,in record:DepthRecorder.Record)->Bool {
    let inverse=simd_float4x4(columnMajor:record.transform).inverse
    var minU=Float.infinity,maxU = -Float.infinity,minV=Float.infinity,maxV = -Float.infinity
    var forward=false
    for x in [box.minimum.x,box.maximum.x] {for y in [box.minimum.y,box.maximum.y] {for z in [box.minimum.z,box.maximum.z] {
      let p=inverse*SIMD4<Float>(x,y,z,1),depth = -p.z
      if depth <= 0.05 {continue};forward=true
      let u=record.intrinsics[0]*p.x/depth+record.intrinsics[6],v = -record.intrinsics[4]*p.y/depth+record.intrinsics[7]
      minU=min(minU,u);maxU=max(maxU,u);minV=min(minV,v);maxV=max(maxV,v)
    }}}
    return forward && maxU>=0 && maxV>=0 && minU<Float(record.width) && minV<Float(record.height)
  }
  private static func fuse(box:CaptureBounds,records:[DepthRecorder.Record],bundle:ScanBundle,
                           progress:(Int)->Void) throws -> (mesh:Mesh,frames:Int,merged:Int,step:Float) {
    let size=box.size+SIMD3<Float>(repeating:0.024),origin=box.minimum-SIMD3<Float>(repeating:0.012)
    // Eight million samples is a hard native allocation ceiling, including on iPad.
    var step:Float=max(0.006,pow(size.x*size.y*size.z/6_500_000,Float(1.0/3.0)))
    step=max(step,max(size.x,max(size.y,size.z))/300)
    let dims=SIMD3<Int32>(Int32(ceil(size.x/step))+1,Int32(ceil(size.y/step))+1,Int32(ceil(size.z/step))+1)
    guard let volume=DFCreateVolume(dims.x,dims.y,dims.z,step,origin.x,origin.y,origin.z) else {throw Failure.memoryBudget}
    defer {DFDestroyVolume(volume)}
    var integrated=0
    for (i,r) in records.enumerated() {
      if Task.isCancelled {throw Failure.cancelled}
      try autoreleasepool {
        let compressed=try Data(contentsOf:bundle.file(r.file))
        let expected=r.width*r.height*2
        let raw:Data
        if compressed.count == expected {raw=compressed}
        else {raw=try (compressed as NSData).decompressed(using:.zlib) as Data}
        let confidence=try Data(contentsOf:bundle.file(r.confidence))
        guard raw.count == expected,confidence.count == r.width*r.height else {throw Failure.invalidDepth}
        var depth=[Float](repeating:0,count:r.width*r.height)
        raw.withUnsafeBytes { bytes in
          for j in depth.indices {let bits=bytes.loadUnaligned(fromByteOffset:j*2,as:UInt16.self);depth[j]=Float(Float16(bitPattern:UInt16(littleEndian:bits)))}
        }
        let inverse=simd_float4x4(columnMajor:r.transform).inverse.columnMajor
        let updated=depth.withUnsafeBufferPointer {dp in confidence.withUnsafeBytes {cp in inverse.withUnsafeBufferPointer {mp in
          DFIntegrate(volume,dp.baseAddress,cp.bindMemory(to:UInt8.self).baseAddress,Int32(r.width),Int32(r.height),mp.baseAddress,r.intrinsics[0],r.intrinsics[4],r.intrinsics[6],r.intrinsics[7])
        }}}
        if updated>0 {integrated+=1}
      }
      if i%8 == 0 {progress(i+1)}
    }
    guard let result=DFExtractMesh(volume,3,1) else {throw Failure.memoryBudget}
    defer {DFDestroyMesh(result)}
    var mesh=Mesh();let count=Int(DFVertexCount(result)),faces=Int(DFTriangleCount(result))
    if let p=DFPositions(result),let n=DFNormals(result),let ids=DFIndices(result),count>0,faces>0 {
      mesh.points.reserveCapacity(count);mesh.normals.reserveCapacity(count)
      for i in 0..<count {mesh.points.append(SIMD3(p[3*i],p[3*i+1],p[3*i+2]));mesh.normals.append(SIMD3(n[3*i],n[3*i+1],n[3*i+2]))}
      mesh.indices=Array(UnsafeBufferPointer(start:ids,count:faces*3))
    }
    return(mesh,integrated,Int(DFMergedPlanarQuads(result)),step)
  }
  private static func write(_ mesh:Mesh,to url:URL) throws -> (Int,Int) {
    var remap=[UInt32:UInt32]();var points:[SIMD3<Float>]=[],normals:[SIMD3<Float>]=[],indices:[UInt32]=[]
    for old in mesh.indices {
      if let new=remap[old] {indices.append(new)}
      else {let new=UInt32(points.count);remap[old]=new;points.append(mesh.points[Int(old)]);normals.append(mesh.normals[Int(old)]);indices.append(new)}
    }
    let header="ply\nformat binary_little_endian 1.0\ncomment reconstructed from saved depth; density is not accuracy\nelement vertex \(points.count)\nproperty float x\nproperty float y\nproperty float z\nproperty float nx\nproperty float ny\nproperty float nz\nelement face \(indices.count/3)\nproperty list uchar uint vertex_indices\nend_header\n"
    var data=Data(header.utf8);data.reserveCapacity(data.count+points.count*24+indices.count/3*13)
    func append<T>(_ value:T){var v=value;withUnsafeBytes(of:&v){data.append(contentsOf:$0)}}
    for i in points.indices {for x in [points[i].x,points[i].y,points[i].z,normals[i].x,normals[i].y,normals[i].z]{append(x)}}
    for i in stride(from:0,to:indices.count,by:3){append(UInt8(3));append(indices[i].littleEndian);append(indices[i+1].littleEndian);append(indices[i+2].littleEndian)}
    try data.write(to:url,options:.atomic)
    return(points.count,indices.count/3)
  }
}

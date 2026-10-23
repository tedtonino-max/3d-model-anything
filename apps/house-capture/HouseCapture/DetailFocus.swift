import ARKit
import SceneKit
import SwiftUI

/// An additive focus pass on the original scanner. Native topology is untouched.
@MainActor
final class DetailFocus: ObservableObject {
  struct Region: Codable {
    var id = UUID()
    var room: Int
    var centers: [SIMD3<Float>] = []
    var radius: Float = 0.07
    var startedAt: Double = 0
    var endedAt: Double?
    var views = 0
    var meshVertices = 0
    var meshTriangles = 0
    var initialMedianEdgeMeters: Float?
    var medianEdgeMeters: Float?
    var nearestDistanceMeters: Float?
  }
  @Published private(set) var painting = false
  @Published private(set) var active = false
  @Published private(set) var selected = 0
  @Published private(set) var message = "Schilder een plek die je van dichtbij wilt meten"
  @Published private(set) var measurement = ""
  private(set) var regions: [Region] = []
  private var draft: Region?
  private var current: Int?
  private var lastPaint = -Double.infinity
  private var lastUpdate = -Double.infinity
  private var lastSave = -Double.infinity
  private var views: [SIMD3<Float>] = []
  private let overlay = SCNNode()
  private let bundle: ScanBundle
  private(set) var inView = false
  var captureID: UUID? { active && inView ? current.map { regions[$0].id } : nil }
  init(bundle: ScanBundle) { self.bundle = bundle }
  func attach(_ scene: SCNScene) { scene.rootNode.addChildNode(overlay) }
  func begin(room: Int) {
    end(); draft = Region(room: room); painting = true; selected = 0
    message = "Schilder over het detail. De gewone scan blijft doorlopen."
    redraw([])
  }
  func paint(_ point: CGPoint, frame: ARFrame, view: ARSCNView) {
    guard painting, frame.timestamp-lastPaint > 0.04, case .normal = frame.camera.trackingState,
          let depth = frame.sceneDepth, let confidence = depth.confidenceMap else { return }
    lastPaint = frame.timestamp
    let size = view.bounds.size
    guard size.width > 0, size.height > 0 else { return }
    let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
    let uv = CGPoint(x: point.x/size.width, y: point.y/size.height)
      .applying(frame.displayTransform(for: orientation, viewportSize: size).inverted())
    let w = CVPixelBufferGetWidth(depth.depthMap), h = CVPixelBufferGetHeight(depth.depthMap)
    let x = Int(uv.x*CGFloat(w)), y = Int(uv.y*CGFloat(h))
    guard x >= 0, y >= 0, x < w, y < h else { return }
    CVPixelBufferLockBaseAddress(depth.depthMap, .readOnly); CVPixelBufferLockBaseAddress(confidence, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(depth.depthMap, .readOnly); CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
    guard let db = CVPixelBufferGetBaseAddress(depth.depthMap), let cb = CVPixelBufferGetBaseAddress(confidence),
          CVPixelBufferGetPixelFormatType(depth.depthMap) == kCVPixelFormatType_DepthFloat32 else { return }
    let d = db.advanced(by: y*CVPixelBufferGetBytesPerRow(depth.depthMap)).assumingMemoryBound(to: Float.self)[x]
    let c = cb.advanced(by: y*CVPixelBufferGetBytesPerRow(confidence)).assumingMemoryBound(to: UInt8.self)[x]
    guard c == 2, d.isFinite, d > 0.15, d < 3 else { message = "Hier ontbreekt betrouwbare diepte; richt iets dichterbij"; return }
    let k = frame.camera.intrinsics, scale = Float(w)/Float(frame.camera.imageResolution.width)
    let local = SIMD4<Float>((Float(x)-k.columns.2.x*scale)*d/(k.columns.0.x*scale),
                            -(Float(y)-k.columns.2.y*scale)*d/(k.columns.1.y*scale), -d, 1)
    let p = simd_make_float3(frame.camera.transform*local)
    guard var region = draft, region.centers.count < 64,
          !region.centers.contains(where: { simd_distance($0,p) < 0.035 }) else { return }
    region.centers.append(p); draft = region; selected = region.centers.count
    redraw(region.centers); message = "Oranje markeert je gekozen detail"
  }
  func confirm(timestamp: Double) {
    guard var region = draft, !region.centers.isEmpty else { return }
    region.startedAt = timestamp; regions.append(region); current = regions.count-1
    draft = nil; painting = false; active = true; inView = false; views = []
    lastUpdate = -.infinity; lastSave = -.infinity; measurement = "Geometrie wordt apart gemeten"
    message = "Kom op 25–70 cm en beweeg rustig naar een andere kijkhoek"
  }
  func cancel() { painting = false; draft = nil; selected = 0; redraw([]) }
  func end() {
    if let current, active { regions[current].endedAt = CACurrentMediaTime() }
    active = false; inView = false; painting = false; current = nil; redraw([])
    try? save()
  }
  func update(_ frame: ARFrame) {
    guard active, let index = current, frame.timestamp-lastUpdate >= 0.5 else { return }
    lastUpdate = frame.timestamp
    var region = regions[index]
    let pose = frame.camera.transform, inverse = pose.inverse, camera = simd_make_float3(pose.columns.3)
    let k = frame.camera.intrinsics, image = frame.camera.imageResolution
    let depth = frame.sceneDepth?.depthMap
    let confidence = frame.sceneDepth?.confidenceMap
    if let depth { CVPixelBufferLockBaseAddress(depth, .readOnly) }
    if let confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
    defer {
      if let depth { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
      if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
    }
    let visible = region.centers.filter { p in
      let local = inverse*SIMD4<Float>(p,1), z = -local.z
      guard z > 0.15 else { return false }
      let u = k.columns.0.x*local.x/z+k.columns.2.x, v = -k.columns.1.y*local.y/z+k.columns.2.y
      guard u > 0, v > 0, u < Float(image.width), v < Float(image.height),
            let depth, let confidence,
            CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32,
            let db = CVPixelBufferGetBaseAddress(depth), let cb = CVPixelBufferGetBaseAddress(confidence) else { return false }
      let w = CVPixelBufferGetWidth(depth), h = CVPixelBufferGetHeight(depth)
      let x = min(w-1,Int(u/Float(image.width)*Float(w))), y = min(h-1,Int(v/Float(image.height)*Float(h)))
      for dy in -1...1 { for dx in -1...1 {
        let xx = x+dx, yy = y+dy
        guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
        let measured = db.advanced(by: yy*CVPixelBufferGetBytesPerRow(depth)).assumingMemoryBound(to: Float.self)[xx]
        let c = cb.advanced(by: yy*CVPixelBufferGetBytesPerRow(confidence)).assumingMemoryBound(to: UInt8.self)[xx]
        if c == 2, measured.isFinite, measured > 0.15, abs(measured-z) < 0.10 { return true }
      } }
      return false
    }
    inView = !visible.isEmpty
    guard let center = visible.min(by: { simd_distance($0,camera) < simd_distance($1,camera) }) else {
      message = "Breng het oranje gebied weer in beeld"; return
    }
    let distance = simd_distance(center,camera)
    region.nearestDistanceMeters = min(region.nearestDistanceMeters ?? distance,distance)
    if distance > 0.70 { message = "Kom dichterbij: ongeveer \(Int(distance*100)) cm afstand" }
    else if distance < 0.25 { message = "Iets terug: houd minstens 25 cm afstand" }
    else {
      let direction = simd_normalize(camera-center)
      if views.allSatisfy({ simd_dot($0,direction) < 0.985 }), views.count < 32 { views.append(direction) }
      region.views = views.count
      message = "Detailopname · \(Int(distance*100)) cm · \(views.count) kijkhoeken"
    }
    // Inspect ARKit's actual triangles in the region. Never manufacture finer faces.
    var edges: [Float] = [], vertices = 0, triangles = 0
    for anchor in frame.anchors.compactMap({ $0 as? ARMeshAnchor }) {
      let g = anchor.geometry, s = g.vertices
      var points: [SIMD3<Float>] = []; points.reserveCapacity(s.count)
      var included: [Bool] = []; included.reserveCapacity(s.count)
      for i in 0..<s.count {
        let p = s.buffer.contents().advanced(by: s.offset+i*s.stride).assumingMemoryBound(to: Float.self)
        let world = simd_make_float3(anchor.transform*SIMD4<Float>(p[0],p[1],p[2],1))
        points.append(world); included.append(DetailFocusPolicy.contains(world, centers: region.centers, radius: region.radius))
      }
      vertices += included.filter { $0 }.count
      let source = g.faces.buffer.contents()
      for f in 0..<g.faces.count {
        guard g.faces.indexCountPerPrimitive == 3 else { continue }
        let ids = (0..<3).map { j in g.faces.bytesPerIndex == 2 ? Int(source.assumingMemoryBound(to: UInt16.self)[f*3+j]) : Int(source.assumingMemoryBound(to: UInt32.self)[f*3+j]) }
        guard ids.allSatisfy({ $0 < points.count && included[$0] }) else { continue }
        triangles += 1
        if edges.count < 30000 { for i in 0..<3 { edges.append(simd_distance(points[ids[i]],points[ids[(i+1)%3]])) } }
      }
    }
    region.meshVertices = vertices; region.meshTriangles = triangles
    if !edges.isEmpty {
      edges.sort(); let median = edges[edges.count/2]; region.medianEdgeMeters = median
      if region.initialMedianEdgeMeters == nil { region.initialMedianEdgeMeters = median }
      measurement = "Geometrie: \(triangles) vlakken · maaswijdte \(Int(median*1000)) mm (start \(Int((region.initialMedianEdgeMeters ?? median)*1000)) mm)"
    } else { measurement = "Nog geen meshvlakken in dit detailgebied" }
    regions[index] = region
    if frame.timestamp-lastSave > 3 { lastSave = frame.timestamp; do { try save() } catch { message = "Detailmarkering kon niet worden opgeslagen" } }
  }
  func save() throws {
    for room in Set(regions.map(\.room)) {
      let url = bundle.file("details/room-\(room).json")
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(regions.filter { $0.room == room }).write(to: url, options: .atomic)
    }
  }
  private func redraw(_ centers: [SIMD3<Float>]) {
    overlay.childNodes.forEach { $0.removeFromParentNode() }
    for center in centers {
      let shape = SCNSphere(radius: 0.07); shape.segmentCount = 10
      let material = SCNMaterial(); material.lightingModel = .constant
      material.diffuse.contents = UIColor.systemOrange.withAlphaComponent(0.35)
      material.readsFromDepthBuffer = false; material.writesToDepthBuffer = false
      shape.firstMaterial = material
      let node = SCNNode(geometry: shape); node.simdPosition = center; node.renderingOrder = 100
      overlay.addChildNode(node)
    }
  }
}

struct DetailPaintLayer: View {
  @ObservedObject var focus: DetailFocus
  let controller: CaptureController
  var body: some View {
    if focus.painting {
      Color.clear.contentShape(Rectangle()).ignoresSafeArea().gesture(
        DragGesture(minimumDistance: 0).onChanged { value in
          if let frame = controller.arSession.currentFrame { focus.paint(value.location, frame: frame, view: controller.scanView.view) }
        })
    }
  }
}

struct DetailFocusControls: View {
  @ObservedObject var focus: DetailFocus
  let begin: () -> Void
  let timestamp: () -> Double
  var body: some View {
    VStack(spacing: 7) {
      if focus.painting || focus.active {
        Text(focus.message).font(.subheadline.weight(.semibold))
        if focus.active {
          Text(focus.measurement).font(.caption)
          Text("Maaswijdte is puntdichtheid, geen nauwkeurigheid. Foto's maken de mesh niet automatisch fijner.").font(.caption2).foregroundStyle(.secondary)
        }
      }
      HStack {
        if focus.painting {
          Button("Annuleer") { focus.cancel() }
          Spacer()
          Button("Meet dit detail") { focus.confirm(timestamp: timestamp()) }.disabled(focus.selected == 0)
        } else if focus.active {
          Button("Ander detail", action: begin)
          Spacer()
          Button("Terug naar gewone scan") { focus.end() }
        } else {
          Button(action: begin) { Label("Detail schilderen", systemImage: "paintbrush.pointed") }
        }
      }.buttonStyle(.bordered)
    }.padding(10).frame(maxWidth: 500).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
  }
}

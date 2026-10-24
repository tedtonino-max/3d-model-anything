import ARKit
import SceneKit
import SwiftUI

/// Selection is world-fixed. Its colours describe successfully saved observations,
/// never the native ARKit mesh's density or an unverified accuracy claim.
@MainActor
final class DetailFocus: ObservableObject {
  struct Region: Codable {
    var id = UUID()
    var room: Int
    var centers: [SIMD3<Float>] = []
    var radius: Float = 0.05
    var startedAt: Double = 0
    var endedAt: Double?
    var views = 0
    var meshVertices = 0
    var meshTriangles = 0
    var initialMedianEdgeMeters: Float?
    var medianEdgeMeters: Float?
    var nearestDistanceMeters: Float?
    var radii: [Float]?
    var observations: [Int]?
    var viewCounts: [Int]?
    var savedDepth: Int?
    var savedPhotos: Int?
    func radius(at i: Int) -> Float { radii.flatMap { i < $0.count ? $0[i] : nil } ?? radius }
  }
  @Published private(set) var painting = false
  @Published private(set) var active = false
  @Published private(set) var selected = 0
  @Published private(set) var message = "Schilder waar je extra detail wilt"
  @Published private(set) var measurement = ""
  @Published private(set) var covered = 0
  @Published private(set) var savedFrames = 0
  @Published private(set) var savedPhotos = 0
  @Published var brushRadius: Float = 0.05
  @Published var erasing = false
  @Published private(set) var cursorRadius: CGFloat = 28
  private(set) var regions: [Region] = []
  private var draft: Region?
  private var current: Int?
  private var displayedRoom = 0
  private var lastPaint = -Double.infinity
  private var lastUpdate = -Double.infinity
  private var lastSave = -Double.infinity
  private var directions: [UUID: [[SIMD3<Float>]]] = [:]
  private let overlay = SCNNode()
  private let bundle: ScanBundle
  private(set) var inView = false
  var captureID: UUID? { active && inView ? current.map { regions[$0].id } : nil }
  var selectionCount: Int { current.map { regions[$0].centers.count } ?? selected }
  var hasSelection: Bool { regions.contains { $0.room == displayedRoom && !$0.centers.isEmpty } }
  init(bundle: ScanBundle) { self.bundle = bundle }
  func attach(_ scene: SCNScene) { scene.rootNode.addChildNode(overlay) }
  func show(room: Int) { displayedRoom = room; redraw() }
  func begin(room: Int) {
    end(); displayedRoom = room; draft = Region(room: room); painting = true
    erasing = false; selected = 0; covered = 0; savedFrames = 0; savedPhotos = 0
    message = "Schilder over het oppervlak. De markering blijft op haar plek."
    redraw()
  }
  func paint(_ point: CGPoint, frame: ARFrame, view: ARSCNView) {
    guard painting, frame.timestamp-lastPaint > 0.025, case .normal = frame.camera.trackingState else { return }
    lastPaint = frame.timestamp
    guard let p = Self.surfacePoint(point, frame: frame, view: view) else {
      message = "Hier nog geen betrouwbare diepte. Richt op het oppervlak."; return
    }
    let camera = simd_make_float3(frame.camera.transform.columns.3)
    let distance = max(0.15, simd_distance(p,camera))
    cursorRadius = max(10, min(100, CGFloat(brushRadius/distance) * view.bounds.height * CGFloat(frame.camera.intrinsics.columns.0.x) / frame.camera.imageResolution.width))
    guard var region = draft else { return }
    var radii = region.radii ?? Array(repeating: region.radius, count: region.centers.count)
    if erasing {
      let keep = region.centers.indices.filter { simd_distance(region.centers[$0],p) > brushRadius + radii[$0]*0.5 }
      region.centers = keep.map { region.centers[$0] }; radii = keep.map { radii[$0] }
    } else {
      guard !region.centers.enumerated().contains(where: { simd_distance($0.element,p) < min(radii[$0.offset],brushRadius)*0.45 }) else { return }
      guard region.centers.count < 1024 else {
        message = "Deze selectie is groot. Start de opname en voeg daarna een nieuw detailgebied toe."; return
      }
      region.centers.append(p); radii.append(brushRadius)
    }
    region.radii = radii; draft = region; selected = region.centers.count
    message = erasing ? "Gum over je markering" : "Oranje = geselecteerd. Tik op Detail opnemen."
    redraw()
  }
  static func surfacePoint(_ point: CGPoint, frame: ARFrame, view: ARSCNView) -> SIMD3<Float>? {
    guard let depth = frame.sceneDepth, let confidence = depth.confidenceMap else { return nil }
    let size = view.bounds.size
    guard size.width > 0, size.height > 0 else { return nil }
    let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
    let uv = CGPoint(x: point.x/size.width, y: point.y/size.height)
      .applying(frame.displayTransform(for: orientation, viewportSize: size).inverted())
    let w = CVPixelBufferGetWidth(depth.depthMap), h = CVPixelBufferGetHeight(depth.depthMap)
    let x = Int(uv.x*CGFloat(w)), y = Int(uv.y*CGFloat(h))
    guard x >= 0, y >= 0, x < w, y < h else { return nil }
    CVPixelBufferLockBaseAddress(depth.depthMap, .readOnly); CVPixelBufferLockBaseAddress(confidence, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(depth.depthMap, .readOnly); CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
    guard let db = CVPixelBufferGetBaseAddress(depth.depthMap), let cb = CVPixelBufferGetBaseAddress(confidence),
          CVPixelBufferGetPixelFormatType(depth.depthMap) == kCVPixelFormatType_DepthFloat32 else { return nil }
    let d = db.advanced(by: y*CVPixelBufferGetBytesPerRow(depth.depthMap)).assumingMemoryBound(to: Float.self)[x]
    let c = cb.advanced(by: y*CVPixelBufferGetBytesPerRow(confidence)).assumingMemoryBound(to: UInt8.self)[x]
    guard c == 2, d.isFinite, d > 0.15, d < 3 else { return nil }
    let k = frame.camera.intrinsics, scale = Float(w)/Float(frame.camera.imageResolution.width)
    let local = SIMD4<Float>((Float(x)-k.columns.2.x*scale)*d/(k.columns.0.x*scale),
                            -(Float(y)-k.columns.2.y*scale)*d/(k.columns.1.y*scale), -d, 1)
    return simd_make_float3(frame.camera.transform*local)
  }
  func confirm(timestamp: Double) {
    guard var region = draft, !region.centers.isEmpty else { return }
    region.startedAt = timestamp; regions.append(region); current = regions.count-1
    directions[region.id] = Array(repeating: [], count: region.centers.count)
    draft = nil; painting = false; active = true; inView = false
    lastUpdate = -.infinity; lastSave = -.infinity; erasing = false
    message = "Bekijk je selectie van dichtbij vanuit verschillende hoeken"
    updateSummary(); redraw()
  }
  func cancel() { painting = false; draft = nil; selected = 0; redraw() }
  func clearDraft() { draft?.centers = []; draft?.radii = []; selected = 0; redraw() }
  func end() {
    if let current, active { regions[current].endedAt = CACurrentMediaTime() }
    active = false; inView = false; painting = false; current = nil; draft = nil
    redraw() // completed selections remain visible, including their evidence colours
    do { try save() } catch { message = "Selectie kon niet worden opgeslagen" }
  }
  /// Evaluated on the exact frame offered to the writer. The indices become
  /// evidence only after the writer confirms that depth and confidence are on disk.
  func observedIndices(_ frame: ARFrame) -> [Int] {
    guard active, let index = current, let depth = frame.sceneDepth?.depthMap,
          let confidence = frame.sceneDepth?.confidenceMap else { return [] }
    CVPixelBufferLockBaseAddress(depth, .readOnly); CVPixelBufferLockBaseAddress(confidence, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly); CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
    guard CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32,
          let db = CVPixelBufferGetBaseAddress(depth), let cb = CVPixelBufferGetBaseAddress(confidence) else { return [] }
    let w = CVPixelBufferGetWidth(depth), h = CVPixelBufferGetHeight(depth), image = frame.camera.imageResolution
    let k = frame.camera.intrinsics, inverse = frame.camera.transform.inverse
    let camera = simd_make_float3(frame.camera.transform.columns.3), region = regions[index]
    return region.centers.indices.filter { i in
      let p = region.centers[i], local = inverse*SIMD4<Float>(p,1), z = -local.z
      guard DetailEvidencePolicy.acceptsDistance(simd_distance(p,camera)), z > 0.15 else { return false }
      let u = (k.columns.0.x*local.x/z+k.columns.2.x)/Float(image.width)*Float(w)
      let v = (-k.columns.1.y*local.y/z+k.columns.2.y)/Float(image.height)*Float(h)
      guard u >= 0, v >= 0, u < Float(w), v < Float(h) else { return false }
      let x = Int(u), y = Int(v)
      let d = db.advanced(by: y*CVPixelBufferGetBytesPerRow(depth)).assumingMemoryBound(to: Float.self)[x]
      let c = cb.advanced(by: y*CVPixelBufferGetBytesPerRow(confidence)).assumingMemoryBound(to: UInt8.self)[x]
      return c == 2 && d.isFinite && abs(d-z) < min(0.04,region.radius(at:i))
    }
  }
  func recorded(_ record: DepthRecorder.Record) {
    guard let id = record.detailID, let index = regions.firstIndex(where: { $0.id == id }), record.transform.count == 16 else { return }
    var r = regions[index]
    r.savedDepth = (r.savedDepth ?? 0)+1
    var counts = r.observations ?? Array(repeating: 0,count:r.centers.count)
    var views = directions[id] ?? Array(repeating: [],count:r.centers.count)
    let camera = SIMD3<Float>(record.transform[12],record.transform[13],record.transform[14])
    for i in record.detailSamples ?? [] where i >= 0 && i < r.centers.count {
      let delta = camera-r.centers[i], distance = simd_length(delta)
      guard DetailEvidencePolicy.acceptsDistance(distance) else { continue }
      counts[i] += 1
      let direction = delta/distance
      if views[i].count < 12 && DetailEvidencePolicy.newDirection(direction,previous:views[i]) { views[i].append(direction) }
      r.nearestDistanceMeters = min(r.nearestDistanceMeters ?? distance,distance)
    }
    directions[id] = views; r.observations = counts; r.viewCounts = views.map(\.count)
    r.views = r.viewCounts?.max() ?? 0; regions[index] = r
    updateSummary(); recolor()
  }
  func photoRecorded(_ record: PhotoRecord) {
    guard let id = record.detailID, let index = regions.firstIndex(where: {$0.id == id}) else { return }
    regions[index].savedPhotos = (regions[index].savedPhotos ?? 0)+1; updateSummary()
  }
  func update(_ frame: ARFrame) {
    guard active, let index = current, frame.timestamp-lastUpdate >= 0.35 else { return }
    lastUpdate = frame.timestamp
    let observed = observedIndices(frame); inView = !observed.isEmpty
    let r = regions[index], camera = simd_make_float3(frame.camera.transform.columns.3)
    let closest = r.centers.map { simd_distance($0,camera) }.min() ?? 0
    if closest > DetailEvidencePolicy.maximumDistance { message = "Kom dichterbij: \(Int(closest*100)) cm tot je selectie" }
    else if closest < DetailEvidencePolicy.minimumDistance { message = "Iets terug: houd minstens 25 cm afstand" }
    else if !inView { message = "Breng je markering in beeld; nog geen betrouwbare diepte hier" }
    else if covered == r.centers.count { message = "Selectie heeft meerdere bruikbare aanzichten. Je kunt opslaan." }
    else { message = "Beweeg rustig opzij en bekijk oranje delen vanuit een andere hoek" }
    if frame.timestamp-lastSave > 3 { lastSave = frame.timestamp; do { try save() } catch { message = "Detailgegevens konden niet worden opgeslagen" } }
  }
  private func updateSummary() {
    guard let index = current else { return }
    let r = regions[index]; selected = r.centers.count
    covered = r.centers.indices.filter { sufficient(r,$0) }.count
    savedFrames = r.savedDepth ?? 0; savedPhotos = r.savedPhotos ?? 0
    measurement = "\(savedFrames) dieptebeelden · \(savedPhotos) foto's opgeslagen"
  }
  private func sufficient(_ r: Region, _ i: Int) -> Bool {
    DetailEvidencePolicy.sufficient(frames:r.observations.flatMap { i < $0.count ? $0[i] : nil } ?? 0,
      views:r.viewCounts.flatMap { i < $0.count ? $0[i] : nil } ?? 0)
  }
  func save() throws {
    for room in Set(regions.map(\.room)) {
      let url = bundle.file("details/room-\(room).json")
      try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
      try JSONEncoder().encode(regions.filter {$0.room == room}).write(to:url,options:.atomic)
    }
  }
  private func recolor() {
    for group in overlay.childNodes {
      guard let name = group.name, let id = UUID(uuidString:name), let r = regions.first(where: {$0.id == id}) else { continue }
      for (i,node) in group.childNodes.enumerated() {
        let color: UIColor = sufficient(r,i) ? .systemGreen : ((r.observations?.indices.contains(i) == true && (r.observations?[i] ?? 0)>0) ? .systemYellow : .systemOrange)
        node.geometry?.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.20)
        node.childNodes.first?.childNodes.first?.geometry?.firstMaterial?.diffuse.contents = color
      }
    }
  }
  private func redraw() {
    overlay.childNodes.forEach {$0.removeFromParentNode()}
    let all = regions.filter {$0.room == displayedRoom} + (draft.map {[$0]} ?? [])
    for r in all {
      let group = SCNNode(); group.name = r.id.uuidString
      for (i,center) in r.centers.enumerated() {
        let radius = CGFloat(r.radius(at:i)), shape = SCNSphere(radius:radius); shape.segmentCount = 8
        let fill = SCNMaterial(); fill.lightingModel = .constant
        fill.diffuse.contents = UIColor.systemOrange.withAlphaComponent(0.20)
        fill.readsFromDepthBuffer = false; fill.writesToDepthBuffer = false; shape.firstMaterial = fill
        let node = SCNNode(geometry:shape); node.simdPosition = center; node.renderingOrder = 100
        let ring = SCNTorus(ringRadius:radius,pipeRadius:0.0015); ring.ringSegmentCount = 18; ring.pipeSegmentCount = 3
        let material = SCNMaterial(); material.lightingModel = .constant; material.diffuse.contents = UIColor.systemOrange
        material.readsFromDepthBuffer = false; material.writesToDepthBuffer = false; ring.firstMaterial = material
        let circle = SCNNode(geometry:ring); circle.eulerAngles.x = .pi/2; circle.renderingOrder = 101
        let facing = SCNNode(); facing.constraints = [SCNBillboardConstraint()]; facing.addChildNode(circle)
        node.addChildNode(facing); group.addChildNode(node)
      }
      overlay.addChildNode(group)
    }
    recolor()
  }
}

/// UIKit converts touch coordinates into the actual AR view's coordinate space;
/// safe areas and the SwiftUI panel no longer offset the painted selection.
private final class DetailTouchView: UIView {
  var onPoint: ((CGPoint,UIView)->Void)?
  var radius: CGFloat = 28
  var erase = false
  private let cursor = CAShapeLayer()
  override init(frame:CGRect) {
    super.init(frame:frame); backgroundColor = .clear; isMultipleTouchEnabled = false
    layer.addSublayer(cursor); cursor.lineWidth = 3
  }
  required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
  private func draw(_ touches:Set<UITouch>) {
    guard let p = touches.first?.location(in:self) else { return }
    onPoint?(p,self)
    cursor.path = UIBezierPath(ovalIn:CGRect(x:p.x-radius,y:p.y-radius,width:radius*2,height:radius*2)).cgPath
    cursor.strokeColor = (erase ? UIColor.systemPink : UIColor.white).cgColor
    cursor.fillColor = (erase ? UIColor.systemPink : UIColor.systemOrange).withAlphaComponent(0.22).cgColor
  }
  override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent?) { draw(touches) }
  override func touchesMoved(_ touches:Set<UITouch>,with event:UIEvent?) { draw(touches) }
  override func touchesEnded(_ touches:Set<UITouch>,with event:UIEvent?) { cursor.path = nil }
  override func touchesCancelled(_ touches:Set<UITouch>,with event:UIEvent?) { cursor.path = nil }
}
private struct DetailTouchSurface: UIViewRepresentable {
  @ObservedObject var focus: DetailFocus
  let controller: CaptureController
  func makeUIView(context:Context)->DetailTouchView { DetailTouchView() }
  func updateUIView(_ view:DetailTouchView,context:Context) {
    view.radius = focus.cursorRadius; view.erase = focus.erasing
    view.onPoint = { point, source in
      guard let frame = controller.arSession.currentFrame else { return }
      focus.paint(source.convert(point,to:controller.scanView.view),frame:frame,view:controller.scanView.view)
    }
  }
}
struct DetailPaintLayer: View {
  @ObservedObject var focus: DetailFocus
  let controller: CaptureController
  var body: some View {
    if focus.painting { DetailTouchSurface(focus:focus,controller:controller).ignoresSafeArea() }
  }
}
struct DetailFocusControls: View {
  @ObservedObject var focus: DetailFocus
  let begin: ()->Void
  let timestamp: ()->Double
  var body: some View {
    VStack(spacing:8) {
      if focus.painting || focus.active {
        Text(focus.message).font(.subheadline.weight(.semibold))
        if focus.painting {
          HStack {
            Image(systemName:focus.erasing ? "eraser" : "paintbrush.pointed")
            Slider(value:$focus.brushRadius,in:0.025...0.12)
            Text("\(Int(focus.brushRadius*200)) cm").font(.caption.monospacedDigit())
          }.accessibilityLabel("Kwastdiameter")
          HStack {
            Toggle("Gum",isOn:$focus.erasing).toggleStyle(.button)
            Button("Wissen",action:focus.clearDraft)
            Spacer()
            Text("\(focus.selected) markeringen").font(.caption)
          }
        } else {
          ProgressView(value:Double(focus.covered),total:Double(max(1,focus.selectionCount))).tint(.green)
          Text("\(focus.covered) van \(focus.selectionCount) delen: voldoende aanzichten").font(.caption)
          Text(focus.measurement).font(.caption.monospacedDigit())
          Text("Oranje: gekozen · Geel: opgenomen · Groen: meerdere aanzichten").font(.caption2)
          Text("Groen is opnamekwaliteit, geen nauwkeurigheidsgarantie.").font(.caption2).foregroundStyle(.secondary)
        }
      }
      HStack {
        if focus.painting {
          Button("Annuleer",action:focus.cancel)
          Spacer()
          Button("Detail opnemen") { focus.confirm(timestamp:timestamp()) }.disabled(focus.selected == 0).buttonStyle(.borderedProminent)
        } else if focus.active {
          Button("Nieuw detail",action:begin)
          Spacer()
          Button("Klaar met detail",action:focus.end)
        } else {
          Button(action:begin) { Label("Detail schilderen",systemImage:"paintbrush.pointed") }
          if focus.hasSelection { Text("Markeringen blijven bewaard").font(.caption) }
        }
      }.buttonStyle(.bordered)
    }.padding(12).frame(maxWidth:500).background(.regularMaterial,in:RoundedRectangle(cornerRadius:14))
  }
}

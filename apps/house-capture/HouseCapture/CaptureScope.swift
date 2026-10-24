import Foundation

enum CaptureScope: String, Codable, CaseIterable, Identifiable {
  case room, area, object
  var id: String { rawValue }
  var title: String {
    switch self { case .room: return "Hele kamer"; case .area: return "Deel van kamer"; case .object: return "Object" }
  }
  var symbol: String {
    switch self { case .room: return "door.left.hand.open"; case .area: return "paintbrush.pointed"; case .object: return "cube.transparent" }
  }
  var guidance: String {
    switch self {
    case .room: return "Loop rustig door de kamer. Schilder plekken waar je extra detail wilt."
    case .area: return "Schilder het stuk muur of de oppervlakken die je wilt bewaren. Alleen je selectie wordt het eindresultaat."
    case .object: return "Plaats het kader rond je object en loop eromheen. De kamer buiten het kader wordt niet meegenomen."
    }
  }
}

struct CaptureBounds: Codable, Equatable, Sendable {
  var minimum: SIMD3<Float>
  var maximum: SIMD3<Float>
  var center: SIMD3<Float> { (minimum + maximum) * 0.5 }
  var size: SIMD3<Float> { maximum - minimum }
  func contains(_ p: SIMD3<Float>, margin: Float = 0) -> Bool {
    (0..<3).allSatisfy { p[$0] >= minimum[$0] - margin && p[$0] <= maximum[$0] + margin }
  }
}

/// Acquisition evidence, never an accuracy estimate. Repeated stationary frames
/// cannot turn a selected surface green without angular diversity.
enum DetailEvidencePolicy {
  static let requiredFrames = 6
  static let requiredViews = 3
  static let minimumDistance: Float = 0.25
  static let maximumDistance: Float = 0.85
  static func sufficient(frames: Int, views: Int) -> Bool {
    frames >= requiredFrames && views >= requiredViews
  }
  static func acceptsDistance(_ meters: Float) -> Bool {
    meters.isFinite && meters >= minimumDistance && meters <= maximumDistance
  }
  static func newDirection(_ direction: SIMD3<Float>, previous: [SIMD3<Float>]) -> Bool {
    let lengthSquared = direction.x*direction.x + direction.y*direction.y + direction.z*direction.z
    guard lengthSquared.isFinite, abs(lengthSquared - 1) < 0.01 else { return false }
    return previous.allSatisfy { $0.x*direction.x + $0.y*direction.y + $0.z*direction.z < 0.9781476 }
  }
}

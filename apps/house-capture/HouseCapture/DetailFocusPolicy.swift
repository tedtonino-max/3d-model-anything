import Foundation

/// Detail changes capture priority, never ARKit's geometry or its confidence.
enum DetailFocusPolicy {
  static func depthInterval(normal: Double, constrained: Bool, active: Bool) -> Double {
    active && !constrained ? min(normal, 0.12) : normal
  }
  static func shouldRecord(elapsed: Double, interval: Double, moved: Float, turned: Float, detail: Bool) -> Bool {
    elapsed > interval && (moved > (detail ? 0.012 : 0.04) || turned > (detail ? 0.02 : 0.06))
  }
  static func usefulDistance(_ distance: Float) -> Bool { distance >= 0.25 && distance <= 0.70 }
  static func contains(_ point: SIMD3<Float>, centers: [SIMD3<Float>], radius: Float) -> Bool {
    centers.contains { c in let d = point - c; return d.x*d.x + d.y*d.y + d.z*d.z <= radius*radius }
  }
}

// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "DetailFocusPolicy", products: [
  .library(name: "SurfaceCore", targets: ["SurfaceCore"])
], targets: [
  .target(name: "SurfaceCore", path: "Sources/SurfaceCore", publicHeadersPath: "include"),
  .target(name: "DetailFocusPolicy", path: "apps/house-capture/HouseCapture", sources: ["DetailFocusPolicy.swift", "CaptureScope.swift"]),
  .testTarget(name: "DetailFocusPolicyTests", dependencies: ["DetailFocusPolicy", "SurfaceCore"], path: "Tests/DetailFocusPolicyTests")
], cxxLanguageStandard: .cxx17)

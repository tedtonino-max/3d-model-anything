// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "DetailFocusPolicy", targets: [
  .target(name: "DetailFocusPolicy", path: "apps/house-capture/HouseCapture", sources: ["DetailFocusPolicy.swift", "CaptureScope.swift"]),
  .testTarget(name: "DetailFocusPolicyTests", dependencies: ["DetailFocusPolicy"], path: "Tests/DetailFocusPolicyTests")
])

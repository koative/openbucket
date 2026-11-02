// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Bucketdeck",
  platforms: [.macOS("26.0")],
  products: [
    .library(name: "BucketdeckCore", targets: ["BucketdeckCore"]),
    .library(name: "BucketdeckS3", targets: ["BucketdeckS3"]),
  ],
  dependencies: [
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.36.2"),
    .package(url: "https://github.com/soto-project/soto.git", from: "7.17.0"),
    .package(url: "https://github.com/soto-project/soto-core.git", from: "7.17.0"),
  ],
  targets: [
    .target(name: "BucketdeckCore"),
    .target(
      name: "BucketdeckS3",
      dependencies: [
        "BucketdeckCore",
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "SotoS3", package: "soto"),
        .product(name: "SotoCore", package: "soto-core"),
      ]
    ),
    .testTarget(name: "BucketdeckCoreTests", dependencies: ["BucketdeckCore"]),
    .testTarget(
      name: "BucketdeckS3Tests",
      dependencies: [
        "BucketdeckS3",
        "BucketdeckCore",
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "SotoCore", package: "soto-core"),
      ]),
  ]
)

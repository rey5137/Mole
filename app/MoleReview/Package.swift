// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MoleReview",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MoleReview", targets: ["MoleReview"]),
        .executable(name: "MoleReviewChecks", targets: ["MoleReviewChecks"]),
        .executable(name: "MoleReviewSnapshots", targets: ["MoleReviewSnapshots"]),
    ],
    targets: [
        .target(name: "MoleReviewCore"),
        .target(name: "MoleReviewUI", dependencies: ["MoleReviewCore"]),
        .executableTarget(name: "MoleReview", dependencies: ["MoleReviewCore", "MoleReviewUI"]),
        .executableTarget(name: "MoleReviewSnapshots", dependencies: ["MoleReviewCore", "MoleReviewUI"]),
        .executableTarget(name: "MoleReviewChecks", dependencies: ["MoleReviewCore", "MoleReviewUI"]),
    ]
)

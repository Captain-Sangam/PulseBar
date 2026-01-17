// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PulseBar",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", from: "0.40.0")
    ],
    targets: [
        .executableTarget(
            name: "PulseBar",
            dependencies: [
                .product(name: "AWSRDS", package: "aws-sdk-swift"),
                .product(name: "AWSCloudWatch", package: "aws-sdk-swift")
            ],
            path: "Sources"
        )
    ]
)

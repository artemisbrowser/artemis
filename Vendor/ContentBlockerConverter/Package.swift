// swift-tools-version:5.6
import PackageDescription

let package = Package(
    name: "ContentBlockerConverter",
    products: [.library(name: "ContentBlockerConverter", targets: ["ContentBlockerConverter"])],
    dependencies: [
        .package(url: "https://github.com/gumob/PunycodeSwift.git", exact: "3.0.0"),
        .package(url: "https://github.com/ameshkov/swift-psl", exact: "1.1.195"),
    ],
    targets: [
        .target(
            name: "ContentBlockerConverter",
            dependencies: [
                .product(name: "Punycode", package: "PunycodeSwift"),
                .product(name: "PublicSuffixList", package: "swift-psl"),
            ]
        ),
    ]
)

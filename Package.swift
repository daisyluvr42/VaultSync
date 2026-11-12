// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VaultWeave",
    platforms: [.macOS(.v13)],
    products: [.library(name: "VaultWeaveCore", targets: ["VaultWeaveCore"]),
               .executable(name: "VaultWeave", targets: ["VaultWeave"]),
               .executable(name: "VaultWeaveEngineHost", targets: ["VaultWeaveEngineHost"]),
               .executable(name: "VaultWeaveCLI", targets: ["VaultWeaveCLI"])],
    targets: [.target(name: "VaultWeaveCore"),
              .executableTarget(name: "VaultWeave", dependencies: ["VaultWeaveCore"]),
              .executableTarget(name: "VaultWeaveEngineHost"),
              .executableTarget(name: "VaultWeaveCLI", dependencies: ["VaultWeaveCore"]),
              .executableTarget(name: "VaultWeaveChecks", dependencies: ["VaultWeaveCore"], path: "Tests/VaultWeaveCoreTests")])

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VaultSync",
    platforms: [.macOS(.v13)],
    products: [.library(name: "VaultSyncCore", targets: ["VaultSyncCore"]),
               .executable(name: "VaultSync", targets: ["VaultSync"]),
               .executable(name: "VaultSyncEngineHost", targets: ["VaultSyncEngineHost"]),
               .executable(name: "VaultSyncCLI", targets: ["VaultSyncCLI"])],
    targets: [.target(name: "VaultSyncCore"),
              .executableTarget(name: "VaultSync", dependencies: ["VaultSyncCore"]),
              .executableTarget(name: "VaultSyncEngineHost"),
              .executableTarget(name: "VaultSyncCLI", dependencies: ["VaultSyncCore"]),
              .executableTarget(name: "VaultSyncChecks", dependencies: ["VaultSyncCore"], path: "Tests/VaultSyncCoreTests")])

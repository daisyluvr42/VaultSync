import Foundation

public struct FileChanges: Sendable {
    public var files: Set<String> = []
    public var directories: Set<String> = []

    public init(files: Set<String> = [], directories: Set<String> = []) {
        self.files = files
        self.directories = directories
    }

    public var isEmpty: Bool { files.isEmpty && directories.isEmpty }

    public mutating func formUnion(_ other: FileChanges) {
        files.formUnion(other.files)
        directories.formUnion(other.directories)
    }
}

/// nil on either side requests reconciliation of that tree.
public struct ScanChanges: Sendable {
    public var local: FileChanges?
    public var objects: FileChanges?

    public init(local: FileChanges? = FileChanges(), objects: FileChanges? = FileChanges()) {
        self.local = local
        self.objects = objects
    }

    public static let full = ScanChanges(local: nil, objects: nil)

    public mutating func formUnion(_ other: ScanChanges) {
        if let delta = other.local { local?.formUnion(delta) } else { local = nil }
        if let delta = other.objects { objects?.formUnion(delta) } else { objects = nil }
    }
}

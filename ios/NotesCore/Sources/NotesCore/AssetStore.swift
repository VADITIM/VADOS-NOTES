import Foundation

public enum AssetError: Error, Equatable {
    case tooLarge(bytes: Int, limit: Int)
}

public final class AssetStore {
    public static let fileExtension = "pdf"

    public let directory: URL
    public let byteLimit: Int

    public init(directory: URL, byteLimit: Int = .max) throws {
        self.directory = directory
        self.byteLimit = byteLimit
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func identifier(for data: Data) -> String {
        RepositoryPath.assetPrefix + ContentHash.sha256(data)
    }

    public func fileURL(for asset: String) -> URL? {
        RepositoryPath.assetHash(asset).map { directory.appendingPathComponent("\($0).\(Self.fileExtension)") }
    }

    public func contains(_ asset: String) -> Bool {
        guard let url = fileURL(for: asset) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func data(for asset: String) -> Data? {
        fileURL(for: asset).flatMap { try? Data(contentsOf: $0) }
    }

    public func byteCount(of asset: String) -> Int? {
        guard let url = fileURL(for: asset), let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.intValue
    }

    @discardableResult
    public func add(_ data: Data) throws -> String {
        guard data.count <= byteLimit else {
            throw AssetError.tooLarge(bytes: data.count, limit: byteLimit)
        }
        let asset = Self.identifier(for: data)
        try write(data, as: asset)
        return asset
    }

    func store(_ data: Data, as asset: String) throws -> Bool {
        guard Self.identifier(for: data) == asset else { return false }
        try write(data, as: asset)
        return true
    }

    private func write(_ data: Data, as asset: String) throws {
        guard let url = fileURL(for: asset), !FileManager.default.fileExists(atPath: url.path) else { return }
        try data.write(to: url, options: .atomic)
    }
}

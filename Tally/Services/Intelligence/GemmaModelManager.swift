import CryptoKit
import Foundation
import Darwin
import OSLog

private let gemmaModelLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Tally",
    category: "GemmaModel"
)

enum GemmaModelStatusKind: Equatable, Sendable {
    case ready
    case missing
    case downloading
    case failed
}

enum GemmaModelHealth: Equatable, Sendable {
    case ready
    case missing
    case adoptable
    case downloading
    case invalid
    case failed
}

struct GemmaModelStatusSnapshot: Sendable {
    let kind: GemmaModelStatusKind
    let health: GemmaModelHealth
    let title: String
    let detail: String
    let modelURL: URL?
    let adoptableSourceURL: URL?
}

enum GemmaModelValidationError: LocalizedError, Equatable, Sendable {
    case brokenSymlink
    case unreadableAttributes
    case notARegularFile
    case fileTooSmall(actualBytes: Int64, minimumBytes: Int64)
    case unreadableHeader
    case invalidGGUFHeader(found: String)
    case unreadableChecksum
    case checksumMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .brokenSymlink:
            return "The managed model link points to a file that no longer exists."
        case .unreadableAttributes:
            return "Tally could not inspect the Gemma model on disk."
        case .notARegularFile:
            return "The Gemma model path does not point to a regular GGUF file."
        case let .fileTooSmall(actualBytes, minimumBytes):
            return """
            The Gemma model is too small to be valid \
            (\(Self.byteCountString(actualBytes)) found, at least \(Self.byteCountString(minimumBytes)) required).
            """
        case .unreadableHeader:
            return "Tally could not read the Gemma model header."
        case let .invalidGGUFHeader(found):
            return "The Gemma model header is invalid. Expected GGUF but found \(found)."
        case .unreadableChecksum:
            return "Tally could not compute the Gemma model checksum."
        case let .checksumMismatch(expected, actual):
            return "The Gemma model checksum did not match the expected download. Expected \(expected), found \(actual)."
        }
    }

    private static func byteCountString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private enum GemmaModelValidationState: Equatable, Sendable {
    case valid
    case missing
    case invalid(GemmaModelValidationError)
}

private struct GemmaModelValidationCacheEntry: Equatable, Sendable {
    let resolvedPath: String
    let fileSize: Int64
    let modificationDate: Date
    let state: GemmaModelValidationState
}

private enum GemmaModelValidationCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: GemmaModelValidationCacheEntry] = [:]

    static func lookup(
        path: String,
        resolvedPath: String,
        fileSize: Int64,
        modificationDate: Date
    ) -> GemmaModelValidationState? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entries[path],
              entry.resolvedPath == resolvedPath,
              entry.fileSize == fileSize,
              entry.modificationDate == modificationDate else {
            return nil
        }
        return entry.state
    }

    static func store(
        path: String,
        resolvedPath: String,
        fileSize: Int64,
        modificationDate: Date,
        state: GemmaModelValidationState
    ) {
        lock.lock()
        entries[path] = GemmaModelValidationCacheEntry(
            resolvedPath: resolvedPath,
            fileSize: fileSize,
            modificationDate: modificationDate,
            state: state
        )
        lock.unlock()
    }
}

struct GemmaModelManager {
    static let managedModelFileName = "gemma-4-E4B-it-Q4_K_M.gguf"
    static let defaultMinimumValidModelSizeBytes: Int64 = 256 * 1024 * 1024
    static let downloadURL = URL(
        string: "https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_M.gguf?download=true"
    )!
    static let expectedDownloadedModelSHA256 = "90ce98129eb3e8cc57e62433d500c97c624b1e3af1fcc85dd3b55ad7e0313e9f"
    private static let ggufHeader = "GGUF"

    private let fileManager: FileManager
    private let appSupportDirectory: URL
    private let adoptableSourceURLs: [URL]
    private let minimumValidModelSizeBytes: Int64
    private let expectedDownloadedModelSHA256: String?

    init(
        fileManager: FileManager = .default,
        appSupportDirectory: URL = GemmaModelManager.defaultAppSupportDirectory(),
        adoptableSourceURLs: [URL] = GemmaModelManager.defaultAdoptableSourceURLs(),
        minimumValidModelSizeBytes: Int64 = GemmaModelManager.defaultMinimumValidModelSizeBytes,
        expectedDownloadedModelSHA256: String? = GemmaModelManager.expectedDownloadedModelSHA256
    ) {
        self.fileManager = fileManager
        self.appSupportDirectory = appSupportDirectory
        self.adoptableSourceURLs = adoptableSourceURLs
        self.minimumValidModelSizeBytes = minimumValidModelSizeBytes
        self.expectedDownloadedModelSHA256 = expectedDownloadedModelSHA256
    }

    var modelsDirectoryURL: URL {
        appSupportDirectory.appending(path: "Models", directoryHint: .isDirectory)
    }

    var managedModelURL: URL {
        modelsDirectoryURL.appending(path: Self.managedModelFileName, directoryHint: .notDirectory)
    }

    func managedModelIfReady() -> URL? {
        isManagedModelReady() ? managedModelURL : nil
    }

    func prepareManagedModelIfNeeded() throws -> URL? {
        if let readyURL = managedModelIfReady() {
            gemmaModelLogger.notice("Managed Gemma model already validated and ready file=\(readyURL.lastPathComponent, privacy: .public)")
            return readyURL
        }

        if pathEntryExists(at: managedModelURL) {
            gemmaModelLogger.notice("Removing stale managed Gemma model entry file=\(managedModelURL.lastPathComponent, privacy: .public) before repair or adoption")
            try removeManagedModelEntryIfPresent()
        }

        guard let adoptableSourceURL = firstAdoptableSourceURL() else {
            gemmaModelLogger.notice("No adoptable Gemma model source found on this Mac")
            return nil
        }

        gemmaModelLogger.notice("Preparing managed Gemma model from adoptable source file=\(adoptableSourceURL.lastPathComponent, privacy: .public)")
        return try adoptExistingModel(from: adoptableSourceURL)
    }

    func adoptExistingModel(from sourceURL: URL) throws -> URL {
        try validateModel(at: sourceURL)
        try ensureModelsDirectoryExists()
        try removeManagedModelEntryIfPresent()

        try fileManager.createSymbolicLink(at: managedModelURL, withDestinationURL: sourceURL)
        try validateModel(at: managedModelURL)
        gemmaModelLogger.notice(
            "Adopted Gemma model source_file=\(sourceURL.lastPathComponent, privacy: .public) managed_file=\(managedModelURL.lastPathComponent, privacy: .public)"
        )
        return managedModelURL
    }

    func installDownloadedModel(from temporaryURL: URL) throws -> URL {
        try validateDownloadedModel(at: temporaryURL)
        try ensureModelsDirectoryExists()
        try removeManagedModelEntryIfPresent()

        try fileManager.moveItem(at: temporaryURL, to: managedModelURL)
        do {
            try validateModel(at: managedModelURL)
        } catch {
            try? removeManagedModelEntryIfPresent()
            gemmaModelLogger.error(
                "Downloaded Gemma model failed post-install validation file=\(managedModelURL.lastPathComponent, privacy: .public) error_type=\(String(describing: type(of: error)), privacy: .public)"
            )
            throw error
        }
        gemmaModelLogger.notice("Installed downloaded Gemma model file=\(managedModelURL.lastPathComponent, privacy: .public)")
        return managedModelURL
    }

    func removeManagedModel() throws {
        try removeManagedModelEntryIfPresent()
        gemmaModelLogger.notice("Removed managed Gemma model entry file=\(managedModelURL.lastPathComponent, privacy: .public)")
    }

    func firstAdoptableSourceURL() -> URL? {
        adoptableSourceURLs.first(where: { validationState(for: $0) == .valid })
    }

    func statusSnapshot(
        isDownloading: Bool = false,
        errorMessage: String? = nil
    ) -> GemmaModelStatusSnapshot {
        if let readyURL = managedModelIfReady() {
            return GemmaModelStatusSnapshot(
                kind: .ready,
                health: .ready,
                title: "Gemma is ready",
                detail: "The local model is available for classification and grounded copilot responses.",
                modelURL: readyURL,
                adoptableSourceURL: nil
            )
        }

        if isDownloading {
            return GemmaModelStatusSnapshot(
                kind: .downloading,
                health: .downloading,
                title: "Downloading Gemma",
                detail: "The 5.3 GB local model is being saved into the app’s managed library.",
                modelURL: managedModelURL,
                adoptableSourceURL: nil
            )
        }

        let adoptableSourceURL = firstAdoptableSourceURL()

        if let errorMessage {
            gemmaModelLogger.error("Gemma setup failed surfaced_error_chars=\(errorMessage.count, privacy: .public)")
            return GemmaModelStatusSnapshot(
                kind: .failed,
                health: .failed,
                title: "Gemma setup failed",
                detail: errorMessage,
                modelURL: pathEntryExists(at: managedModelURL) ? managedModelURL : nil,
                adoptableSourceURL: adoptableSourceURL
            )
        }

        if case let .invalid(validationError) = validationState(for: managedModelURL) {
            gemmaModelLogger.error(
                "Managed Gemma model is invalid file=\(managedModelURL.lastPathComponent, privacy: .public) reason=\(String(describing: validationError), privacy: .public)"
            )
            return GemmaModelStatusSnapshot(
                kind: .failed,
                health: .invalid,
                title: "Gemma model is invalid",
                detail: validationError.errorDescription ?? "The managed Gemma model is not usable.",
                modelURL: managedModelURL,
                adoptableSourceURL: adoptableSourceURL
            )
        }

        if let adoptableSourceURL {
            return GemmaModelStatusSnapshot(
                kind: .missing,
                health: .adoptable,
                title: "Gemma can be adopted",
                detail: "A verified compatible local model already exists on this Mac and can be linked into Tally.",
                modelURL: nil,
                adoptableSourceURL: adoptableSourceURL
            )
        }

        return GemmaModelStatusSnapshot(
            kind: .missing,
            health: .missing,
            title: "Gemma needs setup",
            detail: "Download the managed local model to make Gemma the default intelligence provider on this Mac.",
            modelURL: nil,
            adoptableSourceURL: nil
        )
    }

    func downloadRequest() -> URLRequest {
        var request = URLRequest(url: Self.downloadURL)
        request.timeoutInterval = 60 * 60 * 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func ensureModelsDirectoryExists() throws {
        try fileManager.createDirectory(
            at: modelsDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func isManagedModelReady() -> Bool {
        validationState(for: managedModelURL) == .valid
    }

    private func removeManagedModelEntryIfPresent() throws {
        guard pathEntryExists(at: managedModelURL) else {
            return
        }

        try fileManager.removeItem(at: managedModelURL)
    }

    private func pathEntryExists(at url: URL) -> Bool {
        var fileStatus = stat()
        return lstat(url.path, &fileStatus) == 0
    }

    private func validationState(for url: URL) -> GemmaModelValidationState {
        guard pathEntryExists(at: url) else {
            return .missing
        }

        let resolvedURL = url.resolvingSymlinksInPath()

        do {
            let attributes = try fileManager.attributesOfItem(atPath: resolvedURL.path)
            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modificationDate = (attributes[.modificationDate] as? Date) ?? .distantPast

            if let cachedState = GemmaModelValidationCache.lookup(
                path: url.path,
                resolvedPath: resolvedURL.path,
                fileSize: fileSize,
                modificationDate: modificationDate
            ) {
                return cachedState
            }

            let state: GemmaModelValidationState
            do {
                try validateModel(at: url)
                state = .valid
            } catch let error as GemmaModelValidationError {
                state = .invalid(error)
            } catch {
                state = .invalid(.unreadableAttributes)
            }

            GemmaModelValidationCache.store(
                path: url.path,
                resolvedPath: resolvedURL.path,
                fileSize: fileSize,
                modificationDate: modificationDate,
                state: state
            )
            return state
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .invalid(.brokenSymlink)
        } catch {
            return .invalid(.unreadableAttributes)
        }

    }

    private func validateModel(at url: URL) throws {
        let start = Date()
        var validatedFileSize: Int64 = 0

        do {
            try validateModelBody(at: url, validatedFileSize: &validatedFileSize)
            let durationMilliseconds = Date().timeIntervalSince(start) * 1_000
            gemmaModelLogger.notice(
                "Validated Gemma model file=\(url.lastPathComponent, privacy: .public) size=\(validatedFileSize, privacy: .public)B latency_ms=\(durationMilliseconds, privacy: .public)"
            )
        } catch let error as GemmaModelValidationError {
            let durationMilliseconds = Date().timeIntervalSince(start) * 1_000
            gemmaModelLogger.error(
                "Gemma model validation failed file=\(url.lastPathComponent, privacy: .public) reason=\(String(describing: error), privacy: .public) latency_ms=\(durationMilliseconds, privacy: .public)"
            )
            throw error
        } catch {
            let durationMilliseconds = Date().timeIntervalSince(start) * 1_000
            gemmaModelLogger.error(
                "Gemma model validation failed file=\(url.lastPathComponent, privacy: .public) error_type=\(String(describing: type(of: error)), privacy: .public) latency_ms=\(durationMilliseconds, privacy: .public)"
            )
            throw error
        }
    }

    private func validateDownloadedModel(at url: URL) throws {
        try validateModel(at: url)
        guard let expectedDownloadedModelSHA256 else {
            return
        }

        let actualSHA256 = try sha256HexDigest(for: url)
        guard actualSHA256.localizedCaseInsensitiveCompare(expectedDownloadedModelSHA256) == .orderedSame else {
            throw GemmaModelValidationError.checksumMismatch(
                expected: expectedDownloadedModelSHA256,
                actual: actualSHA256
            )
        }
    }

    private func sha256HexDigest(for url: URL) throws -> String {
        let resolvedURL = url.resolvingSymlinksInPath()
        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(forReadingFrom: resolvedURL)
        } catch {
            throw GemmaModelValidationError.unreadableChecksum
        }

        var hasher = SHA256()
        do {
            while true {
                let data = try fileHandle.read(upToCount: 4 * 1024 * 1024) ?? Data()
                guard data.isEmpty == false else {
                    break
                }
                hasher.update(data: data)
            }
            try fileHandle.close()
        } catch {
            try? fileHandle.close()
            throw GemmaModelValidationError.unreadableChecksum
        }

        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func validateModelBody(at url: URL, validatedFileSize: inout Int64) throws {
        guard pathEntryExists(at: url) else {
            throw GemmaModelValidationError.brokenSymlink
        }

        let resolvedURL = url.resolvingSymlinksInPath()

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: resolvedURL.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw GemmaModelValidationError.brokenSymlink
        } catch {
            throw GemmaModelValidationError.unreadableAttributes
        }

        let fileType = attributes[.type] as? FileAttributeType
        guard fileType == .typeRegular else {
            throw GemmaModelValidationError.notARegularFile
        }

        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        validatedFileSize = fileSize
        guard fileSize >= minimumValidModelSizeBytes else {
            throw GemmaModelValidationError.fileTooSmall(
                actualBytes: fileSize,
                minimumBytes: minimumValidModelSizeBytes
            )
        }

        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(forReadingFrom: resolvedURL)
        } catch {
            throw GemmaModelValidationError.unreadableHeader
        }

        let headerData: Data
        do {
            headerData = try fileHandle.read(upToCount: Self.ggufHeader.utf8.count) ?? Data()
        } catch {
            fileHandle.closeFile()
            throw GemmaModelValidationError.unreadableHeader
        }
        fileHandle.closeFile()

        guard headerData.count == Self.ggufHeader.utf8.count else {
            throw GemmaModelValidationError.unreadableHeader
        }

        let header = String(decoding: headerData, as: UTF8.self)
        guard header == Self.ggufHeader else {
            throw GemmaModelValidationError.invalidGGUFHeader(found: header)
        }
    }

    static func defaultAppSupportDirectory() -> URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")

        let folderName = Bundle.main.bundleIdentifier ?? "Tally"
        return baseDirectory.appending(path: folderName, directoryHint: .isDirectory)
    }

    static func defaultAdoptableSourceURLs() -> [URL] {
        let homeDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let cotypistModelsDirectory = homeDirectory
            .appending(path: "Library/Application Support/app.cotypist.Cotypist", directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)

        return [
            cotypistModelsDirectory
                .appending(path: Self.managedModelFileName, directoryHint: .notDirectory),
            cotypistModelsDirectory
                .appending(path: "gemma-4-E4B-UD-Q5_K_XL.gguf", directoryHint: .notDirectory)
        ]
    }
}

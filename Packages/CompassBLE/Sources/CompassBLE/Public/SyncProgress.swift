import Foundation

/// Progress updates emitted during a FIT file sync operation.
///
/// Consumers receive these through an `AsyncStream<SyncProgress>.Continuation`
/// passed to ``GarminDeviceManager/pullFITFiles(directories:progress:)``.
public enum SyncProgress: Sendable {
    /// The sync operation is starting (connection verified, about to list files).
    case starting

    /// Listing files in the given directory on the device.
    case listing(directory: FITDirectory)

    /// Downloading a specific file from the device.
    case downloading(file: String, bytesReceived: Int, totalBytes: Int?)

    /// Parsing downloaded FIT data.
    case parsing

    /// Sync completed successfully.
    case completed(fileCount: Int)

    /// Sync failed with an error.
    case failed(Error)
}

// SyncProgress contains Error which is not Equatable, so we provide
// a debug-friendly description instead.
extension SyncProgress: CustomStringConvertible {
    public var description: String {
        switch self {
        case .starting:
            return "SyncProgress.starting"
        case .listing(let directory):
            return "SyncProgress.listing(\(directory.rawValue))"
        case .downloading(let file, let received, let total):
            let totalStr = total.map(String.init) ?? "unknown"
            return "SyncProgress.downloading(\(file), \(received)/\(totalStr))"
        case .parsing:
            return "SyncProgress.parsing"
        case .completed(let count):
            return "SyncProgress.completed(\(count) files)"
        case .failed(let error):
            return "SyncProgress.failed(\(error))"
        }
    }
}

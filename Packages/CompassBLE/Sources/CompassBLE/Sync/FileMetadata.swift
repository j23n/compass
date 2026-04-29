import Foundation

/// Metadata for a file stored on the Garmin device.
///
/// File entries are returned by the device in response to a file list request.
/// Each entry identifies a FIT file with its index (used for download requests),
/// type, size, and creation date.
///
/// Reference: Gadgetbridge `FileDownloadHandler.java` — `FileEntry` struct.
public struct FileEntry: Sendable, Equatable {
    /// The file index on the device. Used in download/upload requests.
    public let index: UInt16

    /// The FIT file type.
    public let fileType: FileType

    /// The file size in bytes.
    public let size: UInt32

    /// The file's creation or modification date.
    public let date: Date

    public init(index: UInt16, fileType: FileType, size: UInt32, date: Date) {
        self.index = index
        self.fileType = fileType
        self.size = size
        self.date = date
    }

    // MARK: - Garmin Epoch

    /// The Garmin epoch: December 31, 1989 00:00:00 UTC.
    ///
    /// Garmin devices store timestamps as seconds since this epoch, rather than
    /// the Unix epoch (January 1, 1970). The offset between them is 631065600 seconds.
    private static let garminEpochOffset: TimeInterval = 631_065_600

    /// Convert a Garmin epoch timestamp to a Foundation `Date`.
    ///
    /// - Parameter garminSeconds: Seconds since the Garmin epoch.
    /// - Returns: The corresponding `Date`.
    public static func dateFromGarminEpoch(_ garminSeconds: UInt32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(garminSeconds) + garminEpochOffset)
    }

    /// Convert a Foundation `Date` to a Garmin epoch timestamp.
    ///
    /// - Parameter date: The date to convert.
    /// - Returns: Seconds since the Garmin epoch.
    public static func garminEpochFromDate(_ date: Date) -> UInt32 {
        let interval = date.timeIntervalSince1970 - garminEpochOffset
        return UInt32(max(0, interval))
    }
}

/// FIT file type identifiers.
///
/// These correspond to the file type byte stored in the device's file directory.
/// Each type maps to a ``FITDirectory`` in the public API.
///
/// Reference: Garmin FIT SDK — `FIT_FILE` constants.
///            Gadgetbridge `FileType.java`.
public enum FileType: UInt8, Sendable, Equatable {
    /// Activity recording (run, ride, swim, etc.).
    /// Corresponds to ``FITDirectory/activity``.
    case activity = 0x04

    /// Course file (route for navigation).
    /// Used for uploads, not typically in sync directories.
    case course = 0x06

    /// Health monitoring data (HR, steps, stress).
    /// Corresponds to ``FITDirectory/monitor``.
    case monitor = 0x20

    /// Sleep tracking data.
    /// Corresponds to ``FITDirectory/sleep``.
    case sleep = 0x49

    /// Health metrics summaries.
    /// Corresponds to ``FITDirectory/metrics``.
    case metrics = 0x52
}

/// Extension to map between ``FITDirectory`` and ``FileType``.
extension FITDirectory {
    /// The ``FileType`` corresponding to this directory.
    public var fileType: FileType {
        switch self {
        case .activity: return .activity
        case .monitor: return .monitor
        case .sleep: return .sleep
        case .metrics: return .metrics
        }
    }
}

extension FileType {
    /// The ``FITDirectory`` corresponding to this file type, if any.
    public var directory: FITDirectory? {
        switch self {
        case .activity: return .activity
        case .monitor: return .monitor
        case .sleep: return .sleep
        case .metrics: return .metrics
        case .course: return nil
        }
    }
}

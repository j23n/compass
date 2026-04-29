import Foundation

/// The FIT file directories on a Garmin device that can be synced.
///
/// Each directory corresponds to a FIT file type stored on the watch.
/// When requesting a file list from the device, the directory is used to
/// filter to only the relevant file types.
///
/// Reference: Gadgetbridge `FileType.java` in the Garmin device support module.
public enum FITDirectory: String, Sendable, Hashable, CaseIterable {
    /// Activity recordings (runs, rides, swims, etc.).
    /// FIT file type 0x04.
    case activity

    /// Health monitoring snapshots (heart rate, steps, stress).
    /// FIT file type 0x20.
    case monitor

    /// Sleep tracking data.
    /// FIT file type 0x49.
    case sleep

    /// Health metrics summaries.
    /// FIT file type 0x52.
    case metrics
}

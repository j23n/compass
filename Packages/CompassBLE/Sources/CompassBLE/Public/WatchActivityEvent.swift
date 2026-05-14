import Foundation

/// Short-lived, observable phone↔watch interactions that aren't full file syncs.
///
/// File-sync progress is emitted through ``SyncProgress`` instead. These events
/// exist so the UI can show "the radio is doing something right now" — a
/// pulsing dot, a recent-activity label — without having to inspect every
/// individual GFDI message.
public enum WatchActivityKind: String, Sendable, CaseIterable {
    /// Watch requested a weather forecast; phone is fetching + replying.
    case weather
    /// Phone pushed a now-playing update to the watch.
    case music
    /// Phone pushed a GPS fix to the watch.
    case location
    /// Watch triggered the "find my phone" alert (started or cancelled).
    case findMyPhone
    /// Phone archived a FIT file on the watch after parsing it.
    case archive

    public var displayName: String {
        switch self {
        case .weather:     "Weather"
        case .music:       "Music"
        case .location:    "Location"
        case .findMyPhone: "Find My Phone"
        case .archive:     "Archive"
        }
    }
}

public struct WatchActivityEvent: Sendable, Equatable {
    public let kind: WatchActivityKind
    public let at: Date

    public init(kind: WatchActivityKind, at: Date = Date()) {
        self.kind = kind
        self.at = at
    }
}

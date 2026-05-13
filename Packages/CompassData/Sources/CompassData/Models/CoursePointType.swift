import Foundation

/// FIT `course_point` type enum, filtered down to the values that Garmin
/// watches actually render with a distinct icon. The raw value matches the
/// FIT SDK number, so `UInt8(type.rawValue)` is the byte to write into a
/// `course_point.type` field.
///
/// Used by `CoursePOI` (persisted as Int), `GPXCourseParser` (mapping from
/// GPX `<type>` / `<sym>`), `CourseFITEncoder` (FIT byte), and the SwiftUI
/// edit picker.
public enum CoursePointType: Int, CaseIterable, Sendable, Codable {
    case generic       = 0
    case summit        = 1
    case valley        = 2
    case water         = 3
    case food          = 4
    case danger        = 5
    case left          = 6
    case right         = 7
    case straight      = 8
    case firstAid      = 9
    case sprint        = 15
    case leftFork      = 16
    case rightFork     = 17
    case middleFork    = 18
    case slightLeft    = 19
    case sharpLeft     = 20
    case slightRight   = 21
    case sharpRight    = 22
    case uTurn         = 23
    case segmentStart  = 24
    case segmentEnd    = 25
    case campsite      = 27
    case aidStation    = 28
    case restArea      = 29
    case service       = 31
    case energyGel     = 32
    case sportsDrink   = 33
    case checkpoint    = 35
    case shelter       = 36
    case meetingSpot   = 37
    case overlook      = 38
    case toilet        = 39
    case shower        = 40
    case store         = 48
    case transport     = 51
    case alert         = 52
    case info          = 53

    /// Human-readable name shown in the picker.
    public var displayName: String {
        switch self {
        case .generic:      "Generic"
        case .summit:       "Summit"
        case .valley:       "Valley"
        case .water:        "Water"
        case .food:         "Food"
        case .danger:       "Danger"
        case .left:         "Left turn"
        case .right:        "Right turn"
        case .straight:     "Straight"
        case .firstAid:     "First aid"
        case .sprint:       "Sprint"
        case .leftFork:     "Left fork"
        case .rightFork:    "Right fork"
        case .middleFork:   "Middle fork"
        case .slightLeft:   "Slight left"
        case .sharpLeft:    "Sharp left"
        case .slightRight:  "Slight right"
        case .sharpRight:   "Sharp right"
        case .uTurn:        "U-turn"
        case .segmentStart: "Segment start"
        case .segmentEnd:   "Segment end"
        case .campsite:     "Campsite"
        case .aidStation:   "Aid station"
        case .restArea:     "Rest area"
        case .service:      "Service"
        case .energyGel:    "Energy gel"
        case .sportsDrink:  "Sports drink"
        case .checkpoint:   "Checkpoint"
        case .shelter:      "Shelter"
        case .meetingSpot:  "Meeting spot"
        case .overlook:     "Overlook"
        case .toilet:       "Toilet"
        case .shower:       "Shower"
        case .store:        "Store"
        case .transport:    "Transport"
        case .alert:        "Alert"
        case .info:         "Info"
        }
    }

    /// SF Symbol used for in-app rendering. The actual on-watch glyph is
    /// drawn from Garmin's own sprite for the FIT enum value.
    public var systemImage: String {
        switch self {
        case .generic:      "mappin"
        case .summit:       "mountain.2.fill"
        case .valley:       "arrow.down.to.line"
        case .water:        "drop.fill"
        case .food:         "fork.knife"
        case .danger:       "exclamationmark.triangle.fill"
        case .left:         "arrow.turn.up.left"
        case .right:        "arrow.turn.up.right"
        case .straight:     "arrow.up"
        case .firstAid:     "cross.fill"
        case .sprint:       "flag.checkered"
        case .leftFork:     "arrow.triangle.branch"
        case .rightFork:    "arrow.triangle.branch"
        case .middleFork:   "arrow.triangle.branch"
        case .slightLeft:   "arrow.up.left"
        case .sharpLeft:    "arrow.uturn.left"
        case .slightRight:  "arrow.up.right"
        case .sharpRight:   "arrow.uturn.right"
        case .uTurn:        "arrow.uturn.down"
        case .segmentStart: "flag.fill"
        case .segmentEnd:   "flag.checkered"
        case .campsite:     "tent.fill"
        case .aidStation:   "cross.case.fill"
        case .restArea:     "bed.double.fill"
        case .service:      "wrench.and.screwdriver.fill"
        case .energyGel:    "bolt.fill"
        case .sportsDrink:  "cup.and.saucer.fill"
        case .checkpoint:   "checkmark.seal.fill"
        case .shelter:      "house.fill"
        case .meetingSpot:  "person.2.fill"
        case .overlook:     "binoculars.fill"
        case .toilet:       "toilet.fill"
        case .shower:       "shower.fill"
        case .store:        "cart.fill"
        case .transport:    "bus.fill"
        case .alert:        "bell.fill"
        case .info:         "info.circle.fill"
        }
    }

    /// Resolve from a raw FIT enum byte. Falls back to `.generic` if the
    /// byte is outside the curated set (Garmin renders many values as a
    /// dot anyway, so degrading to `.generic` is honest).
    public init(fitCode: UInt8) {
        self = CoursePointType(rawValue: Int(fitCode)) ?? .generic
    }

    /// Byte written into FIT `course_point.type`.
    public var fitCode: UInt8 { UInt8(rawValue) }

    /// True if the type is a turn cue (the watch fires a "turn ahead" alert
    /// for these as you approach). Used to label turn POIs distinctly in the
    /// list and to seed the synthetic-turn detector.
    public var isTurnCue: Bool {
        switch self {
        case .left, .right, .slightLeft, .slightRight,
             .sharpLeft, .sharpRight, .uTurn,
             .leftFork, .rightFork, .middleFork:
            return true
        default:
            return false
        }
    }
}

// MARK: - GPX symbol/type mapping

extension CoursePointType {
    /// Resolve a `CoursePointType` from GPX `<type>` and/or `<sym>` strings.
    /// `<type>` is preferred when both are present (Garmin Connect / Strava /
    /// RideWithGPS emit `<type>`; Komoot only emits `<sym>`).
    ///
    /// Unknown inputs fall back to `.generic` — the caller can override via
    /// the POI editor.
    public static func resolve(gpxType: String?, gpxSym: String?) -> CoursePointType {
        if let t = gpxType?.lowercased(), let match = fromTextHints(t) {
            return match
        }
        if let s = gpxSym?.lowercased(), let match = fromTextHints(s) {
            return match
        }
        return .generic
    }

    private static func fromTextHints(_ raw: String) -> CoursePointType? {
        // Most specific first.
        if raw.contains("u-turn") || raw.contains("u turn") || raw.contains("uturn") { return .uTurn }
        if raw.contains("sharp") && raw.contains("left")  { return .sharpLeft  }
        if raw.contains("sharp") && raw.contains("right") { return .sharpRight }
        if raw.contains("slight") && raw.contains("left")  { return .slightLeft  }
        if raw.contains("slight") && raw.contains("right") { return .slightRight }
        if raw.contains("fork") && raw.contains("left")  { return .leftFork  }
        if raw.contains("fork") && raw.contains("right") { return .rightFork }
        if raw.contains("fork") && raw.contains("middle") { return .middleFork }
        if raw.contains("first aid") || raw.contains("first_aid") || raw.contains("medical") || raw.contains("hospital") { return .firstAid }
        if raw.contains("aid station") || raw.contains("aid_station") { return .aidStation }
        if raw.contains("rest") && raw.contains("area")  { return .restArea }
        if raw.contains("water") || raw.contains("fountain") || raw.contains("drinking") { return .water }
        if raw.contains("summit") || raw.contains("peak") || raw.contains("mountain") { return .summit }
        if raw.contains("valley") { return .valley }
        if raw.contains("food") || raw.contains("restaurant") || raw.contains("cafe") || raw.contains("café") { return .food }
        if raw.contains("danger") || raw.contains("warning") { return .danger }
        if raw.contains("overlook") || raw.contains("viewpoint") || raw.contains("view point") || raw.contains("scenic") { return .overlook }
        if raw.contains("shelter") || raw.contains("hut") || raw.contains("refuge") { return .shelter }
        if raw.contains("camp") { return .campsite }
        if raw.contains("toilet") || raw.contains("restroom") || raw.contains("wc") { return .toilet }
        if raw.contains("shower") { return .shower }
        if raw.contains("store") || raw.contains("shop") || raw.contains("market") { return .store }
        if raw.contains("transport") || raw.contains("bus") || raw.contains("train") || raw.contains("station") { return .transport }
        if raw.contains("alert") { return .alert }
        if raw.contains("info") { return .info }
        if raw.contains("checkpoint") { return .checkpoint }
        if raw.contains("segment") && raw.contains("start") { return .segmentStart }
        if raw.contains("segment") && raw.contains("end")   { return .segmentEnd   }
        if raw.contains("sprint") { return .sprint }
        if raw.contains("left")  { return .left  }
        if raw.contains("right") { return .right }
        if raw.contains("straight") { return .straight }
        return nil
    }
}

import Foundation

/// MUSIC_CONTROL (5041 / 0x13B1) command ordinals sent by the watch.
///
/// Reference: Gadgetbridge `GarminMusicControlCommand.java`
public enum GarminMusicControlCommand: UInt8, Sendable, CaseIterable {
    case playPause          = 0
    case skipToNextCuepoint = 1
    case skipBackToCuepoint = 2
    case nextTrack          = 3
    case previousTrack      = 4
    case volumeUp           = 5
    case volumeDown         = 6
}

/// One TLV attribute inside a MUSIC_CONTROL_ENTITY_UPDATE (5049 / 0x13B9) push.
///
/// Entity / attribute breakdown:
///   entity 0 (player):  attr 0=name, 1=playbackState (0=paused,1=playing,3=stopped), 2=volume (0-100)
///   entity 1 (queue):   attr 0=operationsSupported, 1=shuffleState, 2=repeatState
///   entity 2 (track):   attr 0=artist, 1=album, 2=title, 3=duration (UInt32 ms)
///
/// Reference: Gadgetbridge `MusicControlEntityUpdateMessage.java`
public struct MusicEntityUpdate: Sendable {
    public let entity: UInt8
    public let attribute: UInt8
    public let flags: UInt8
    public let value: Data

    public init(entity: UInt8, attribute: UInt8, value: Data, flags: UInt8 = 0) {
        self.entity = entity
        self.attribute = attribute
        self.flags = flags
        self.value = value
    }

    // MARK: Convenience factories — player entity (0)

    public static func playerName(_ name: String) -> MusicEntityUpdate {
        MusicEntityUpdate(entity: 0, attribute: 0, value: Data(name.utf8))
    }

    /// playbackState: 0=paused, 1=playing, 3=stopped
    public static func playbackState(_ state: UInt8) -> MusicEntityUpdate {
        MusicEntityUpdate(entity: 0, attribute: 1, value: Data([state]))
    }

    /// volume: 0–100
    public static func volume(_ v: UInt8) -> MusicEntityUpdate {
        MusicEntityUpdate(entity: 0, attribute: 2, value: Data([v]))
    }

    // MARK: Convenience factories — track entity (2)

    public static func trackArtist(_ artist: String) -> MusicEntityUpdate {
        MusicEntityUpdate(entity: 2, attribute: 0, value: Data(artist.utf8))
    }

    public static func trackAlbum(_ album: String) -> MusicEntityUpdate {
        MusicEntityUpdate(entity: 2, attribute: 1, value: Data(album.utf8))
    }

    public static func trackTitle(_ title: String) -> MusicEntityUpdate {
        MusicEntityUpdate(entity: 2, attribute: 2, value: Data(title.utf8))
    }

    /// duration in milliseconds
    public static func trackDurationMs(_ ms: UInt32) -> MusicEntityUpdate {
        var d = Data()
        d.appendUInt32LE(ms)
        return MusicEntityUpdate(entity: 2, attribute: 3, value: d)
    }
}

/// Encodes a list of `MusicEntityUpdate` TLVs into a single
/// MUSIC_CONTROL_ENTITY_UPDATE (5049) GFDIMessage.
///
/// Wire format per update:
/// ```
/// [entity:    UInt8]
/// [attribute: UInt8]
/// [flags:     UInt8]
/// [length:    UInt16 LE]
/// [value:     length bytes]
/// ```
public enum MusicEntityUpdateEncoder {
    public static func encode(_ updates: [MusicEntityUpdate]) -> GFDIMessage {
        var payload = Data()
        for u in updates {
            payload.append(u.entity)
            payload.append(u.attribute)
            payload.append(u.flags)
            payload.appendUInt16LE(UInt16(u.value.count))
            payload.append(u.value)
        }
        return GFDIMessage(type: .musicControlEntityUpdate, payload: payload)
    }
}

import Foundation
import MediaPlayer
import CompassBLE

/// Integrates the watch's music remote with iOS media playback.
///
/// - Receives MUSIC_CONTROL commands from the watch and routes them to
///   `MPMusicPlayerController.systemMusicPlayer` (controls Apple Music;
///   third-party apps like Spotify are not controllable via the sandbox API).
/// - Observes `MPNowPlayingInfoCenter` changes and pushes
///   MUSIC_CONTROL_ENTITY_UPDATE messages to the watch so its now-playing
///   screen stays current.
@MainActor
final class MusicService {

    private var observers: [NSObjectProtocol] = []
    private var onUpdate: (([GFDIMessage]) -> Void)?

    private var systemPlayer: MPMusicPlayerController {
        MPMusicPlayerController.systemMusicPlayer
    }

    // MARK: - Lifecycle

    func startObserving(onUpdate: @escaping ([GFDIMessage]) -> Void) {
        self.onUpdate = onUpdate
        systemPlayer.beginGeneratingPlaybackNotifications()
        registerObservers()
        pushCurrentState()
    }

    func stopObserving() {
        onUpdate = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        systemPlayer.endGeneratingPlaybackNotifications()
    }

    // MARK: - Command dispatch (called via musicCommandHandler)

    func handleCommand(ordinal: UInt8) {
        guard let command = GarminMusicControlCommand(rawValue: ordinal) else {
            AppLogger.services.warning("Music: unknown command ordinal \(ordinal)")
            return
        }
        AppLogger.services.info("Music: command \(String(describing: command))")
        switch command {
        case .playPause:
            if systemPlayer.playbackState == .playing {
                systemPlayer.pause()
            } else {
                systemPlayer.play()
            }
        case .nextTrack, .skipToNextCuepoint:
            systemPlayer.skipToNextItem()
        case .previousTrack, .skipBackToCuepoint:
            systemPlayer.skipToPreviousItem()
        case .volumeUp, .volumeDown:
            // System volume cannot be set programmatically in the sandbox.
            // The watch's own volume buttons take precedence for BT headsets anyway.
            AppLogger.services.debug("Music: volume command \(String(describing: command)) ignored (no sandbox API)")
        }
    }

    // MARK: - Now-playing observation

    private func registerObservers() {
        let nc = NotificationCenter.default

        let names: [NSNotification.Name] = [
            .MPMusicPlayerControllerNowPlayingItemDidChange,
            .MPMusicPlayerControllerPlaybackStateDidChange,
        ]
        for name in names {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.pushCurrentState()
            }
            observers.append(token)
        }
    }

    // MARK: - Now-playing push

    func pushCurrentState() {
        let nowPlaying = MPNowPlayingInfoCenter.default().nowPlayingInfo
        var updates: [MusicEntityUpdate] = []

        // Player entity
        let isPlaying = systemPlayer.playbackState == .playing
        updates.append(.playerName("Music"))
        updates.append(.playbackState(isPlaying ? 1 : 0))

        // Track entity — only include fields that are actually set
        if let title = nowPlaying?[MPMediaItemPropertyTitle] as? String, !title.isEmpty {
            updates.append(.trackTitle(title))
        }
        if let artist = nowPlaying?[MPMediaItemPropertyArtist] as? String, !artist.isEmpty {
            updates.append(.trackArtist(artist))
        }
        if let album = nowPlaying?[MPMediaItemPropertyAlbumTitle] as? String, !album.isEmpty {
            updates.append(.trackAlbum(album))
        }
        if let duration = nowPlaying?[MPMediaItemPropertyPlaybackDuration] as? TimeInterval, duration > 0 {
            updates.append(.trackDurationMs(UInt32(duration * 1000)))
        }

        let message = MusicEntityUpdateEncoder.encode(updates)
        AppLogger.services.debug("Music: pushing \(updates.count) entity updates to watch")
        onUpdate?([message])
    }
}

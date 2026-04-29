import Foundation
import AVFoundation
import UserNotifications
import CompassBLE

/// Handles FIND_MY_PHONE_REQUEST / FIND_MY_PHONE_CANCEL from the watch.
///
/// When the watch triggers Find My Phone, we:
///   1. Activate an AVAudioSession (.playback) so sound plays over silent mode.
///   2. Generate a repeating 880 Hz tone via AVAudioEngine (no bundled file needed).
///   3. Post a persistent UNUserNotificationCenter banner.
///
/// When the watch cancels (or the banner is dismissed), everything stops.
@MainActor
final class FindMyPhoneService {

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var isRinging = false
    private let notificationID = "com.compass.findmyphone"

    func handle(_ event: FindMyPhoneEvent) async {
        switch event {
        case .started:
            guard !isRinging else { return }
            isRinging = true
            AppLogger.services.info("Find My Phone: started")
            await startRinging()
        case .cancelled:
            guard isRinging else { return }
            AppLogger.services.info("Find My Phone: cancelled by watch")
            await stopRinging()
        }
    }

    // MARK: - Private

    private func startRinging() async {
        configureAudioSession()
        startTone()
        await postNotification()
    }

    private func stopRinging() async {
        isRinging = false
        stopTone()
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [notificationID])
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [notificationID])
        AppLogger.services.info("Find My Phone: stopped")
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // .playback + .duckOthers: plays over silent switch, lowers any other audio.
        try? session.setCategory(.playback, mode: .default, options: [.duckOthers])
        try? session.setActive(true)
    }

    private func startTone() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        let sampleRate: Double = 44100
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)

        guard let buffer = makeToneBuffer(format: format, sampleRate: sampleRate) else { return }

        try? engine.start()
        // Loop the buffer indefinitely until stopTone() is called.
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()

        audioEngine = engine
        playerNode = player
    }

    private func stopTone() {
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Builds a 0.6 s sine-wave buffer at 880 Hz with a short fade-out.
    private func makeToneBuffer(format: AVAudioFormat, sampleRate: Double) -> AVAudioPCMBuffer? {
        let duration = 0.6
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        let frequency = 880.0
        let fadeFrames = Int(sampleRate * 0.05)  // 50 ms fade-out

        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            var amplitude: Float = 0.85
            let remaining = Int(frameCount) - i
            if remaining < fadeFrames {
                amplitude *= Float(remaining) / Float(fadeFrames)
            }
            samples[i] = amplitude * Float(sin(2 * Double.pi * frequency * t))
        }
        return buffer
    }

    private func postNotification() async {
        let center = UNUserNotificationCenter.current()

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
              settings.authorizationStatus == .provisional else {
            AppLogger.services.warning("Find My Phone: notification permission not granted")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Find My Phone"
        content.body = "Your Garmin watch is looking for your phone."
        content.sound = .default
        // Keep the banner alive so the user can see it even after unlocking.
        let request = UNNotificationRequest(
            identifier: notificationID,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            AppLogger.services.error("Find My Phone: notification error \(error)")
        }
    }
}

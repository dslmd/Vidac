import AppKit
import MediaPlayer

/// Shows the current video in Control Center and answers the media keys,
/// AirPods and other remote controls. While no video is open it registers as
/// nothing, so those keys go back to whatever else is playing.
final class NowPlayingBridge {
    private weak var player: PlayerController?
    private var publishing = false
    private var lastElapsed = 0.0
    private var lastTime: TimeInterval = 0
    private var lastRate = 0.0

    init(player: PlayerController) { self.player = player }

    func setUp() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.perform { $0.remotePlay() } ?? .commandFailed }
        center.pauseCommand.addTarget { [weak self] _ in self?.perform { $0.remotePause() } ?? .commandFailed }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.perform { $0.togglePause() } ?? .commandFailed }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            return self?.perform { $0.seekBy(interval) } ?? .commandFailed
        }
        center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            return self?.perform { $0.seekBy(-interval) } ?? .commandFailed
        }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.perform { $0.playNext() } ?? .commandFailed }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.perform { $0.playPrevious() } ?? .commandFailed }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            return self?.perform { $0.jump(to: position) } ?? .commandFailed
        }
        updateEnabled()
    }

    /// Remote commands can arrive on any thread.
    private func perform(_ work: @escaping (PlayerController) -> Void) -> MPRemoteCommandHandlerStatus {
        let run = { [weak self] in
            if let player = self?.player, player.hasVideo, !player.quitting { work(player) }
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
        return .success
    }

    private func updateEnabled() {
        let center = MPRemoteCommandCenter.shared()
        let active = publishing
        for command in [
            center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.skipForwardCommand,
            center.skipBackwardCommand, center.changePlaybackPositionCommand,
        ] as [MPRemoteCommand] where command.isEnabled != active {
            command.isEnabled = active
        }
        let next = active && player?.hasNextItem == true, previous = active && player?.hasPreviousItem == true
        if center.nextTrackCommand.isEnabled != next { center.nextTrackCommand.isEnabled = next }
        if center.previousTrackCommand.isEnabled != previous { center.previousTrackCommand.isEnabled = previous }
    }

    /// Publishes the current state, or withdraws it when no video is open.
    func refresh() {
        guard let player, !player.quitting, player.hasVideo, let url = player.currentURL else {
            clear()
            return
        }
        publishing = true
        let rate = player.isPaused || player.atEnd ? 0 : player.playbackSpeed
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: url.deletingPathExtension().lastPathComponent,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.playbackPosition,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if player.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = player.duration }
        if player.queue.count > 1 {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = player.queueIndex
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = player.queue.count
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = rate > 0 ? .playing : .paused
        lastElapsed = player.playbackPosition
        lastTime = ProcessInfo.processInfo.systemUptime
        lastRate = rate
        updateEnabled()
    }

    /// The system extrapolates the position from the last report, so only a
    /// jump (a seek, a new file) needs a new one.
    func positionChanged() {
        guard publishing, let player else { return }
        let expected = lastElapsed + (ProcessInfo.processInfo.systemUptime - lastTime) * lastRate
        if abs(player.playbackPosition - expected) > 1.2 { refresh() }
    }

    func clear() {
        let wasPublishing = publishing
        publishing = false
        updateEnabled()
        guard wasPublishing else { return }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }
}

extension PlayerController {
    /// Play from a remote: resumes, or starts over at the end of the video.
    func remotePlay() { if atEnd || isPaused { togglePause() } }
    func remotePause() { if !atEnd && !isPaused { togglePause() } }
}

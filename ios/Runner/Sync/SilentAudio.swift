import AVFoundation

/// Layer 2: AVAudioSession .playback + .mixWithOthers looping a silent buffer, so iOS keeps the process alive.
final class SilentAudio {
    static let shared = SilentAudio()

    private var player: AVAudioPlayer?
    private var observing = false

    var isPlaying: Bool { player?.isPlaying ?? false }

    func start() {
        guard Config.AUDIO_ENABLED else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            NSLog("[Sync] audio session error: %@", error.localizedDescription)
        }
        if player == nil {
            player = try? AVAudioPlayer(data: SilentAudio.silentWav(seconds: 1))
            player?.numberOfLoops = -1
            player?.prepareToPlay()
        }
        if player?.isPlaying == false { player?.play() }
        observe()
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func observe() {
        guard !observing else { return }
        observing = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { n in
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            if AVAudioSession.InterruptionType(rawValue: raw) == .ended, SyncStore.shared.running { self.start() }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            self.player = nil
            if SyncStore.shared.running { self.start() }
        }
    }

    /// 8 kHz / 16-bit / mono PCM WAV of zeros, generated at runtime (no binary asset to ship).
    private static func silentWav(seconds: Int) -> Data {
        let rate = 8000, samples = rate * seconds, dataSize = samples * 2
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataSize)
        d.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataSize)
        d.append(Data(count: dataSize))
        return d
    }
}

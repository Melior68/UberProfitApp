import Foundation
import AVFoundation

/// Mantém o aplicativo principal vivo 100% do tempo em segundo plano usando uma sessão de áudio
/// `.playback` com `.mixWithOthers`, reproduzindo um buffer PCM inaudível em loop contínuo.
@MainActor
public final class BackgroundKeepAlive: ObservableObject {
    @Published public private(set) var isRunning: Bool = false

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var silenceBuffer: AVAudioPCMBuffer?

    public init() {
        setupNotifications()
    }

    public func start() {
        guard !isRunning else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            configureEngineIfNeeded()

            if !audioEngine.isRunning {
                try audioEngine.start()
            }

            if let buffer = silenceBuffer, !playerNode.isPlaying {
                playerNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
                playerNode.play()
            }

            isRunning = true
        } catch {
            isRunning = false
        }
    }

    public func stop() {
        guard isRunning else { return }
        playerNode.stop()
        audioEngine.stop()
        isRunning = false
    }

    private func configureEngineIfNeeded() {
        guard silenceBuffer == nil else { return }

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1)!
        let frameCount: AVAudioFrameCount = 44100 // 1 segundo de áudio silencioso
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        if let channelData = buffer.floatChannelData?[0] {
            for i in 0..<Int(frameCount) {
                channelData[i] = 0.0
            }
        }

        silenceBuffer = buffer
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        audioEngine.mainMixerNode.outputVolume = 0.01
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.isRunning = false
                self.start()
            }
        }
    }
}

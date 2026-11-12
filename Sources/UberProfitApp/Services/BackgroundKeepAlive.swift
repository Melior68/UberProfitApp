import Foundation
import AVFoundation

/// Mantém o aplicativo principal vivo 100% do tempo em segundo plano usando uma sessão de áudio
/// `.playback` com `.mixWithOthers`, reproduzindo um buffer PCM inaudível em loop contínuo e
/// auto-recuperando o `AVAudioEngine` após qualquer síntese de voz ou interrupção do sistema.
@MainActor
public final class BackgroundKeepAlive: ObservableObject {
    @Published public private(set) var isRunning: Bool = false

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var silenceBuffer: AVAudioPCMBuffer?
    private var watchdogTimer: Timer?

    public init() {
        setupNotifications()
    }

    public func start() {
        ensureEnginePlaying()
        startWatchdog()
    }

    public func ensureEnginePlaying() {
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

            isRunning = audioEngine.isRunning && playerNode.isPlaying
        } catch {
            isRunning = false
        }
    }

    public func stop() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        playerNode.stop()
        audioEngine.stop()
        isRunning = false
    }

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.audioEngine.isRunning || !self.playerNode.isPlaying {
                    self.ensureEnginePlaying()
                }
            }
        }
    }

    private func configureEngineIfNeeded() {
        guard silenceBuffer == nil else { return }

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1)!
        let frameCount: AVAudioFrameCount = 44100
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
                self?.ensureEnginePlaying()
            }
        }
    }
}

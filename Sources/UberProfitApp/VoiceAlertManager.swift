import Foundation
import AVFoundation
import AudioToolbox

/// Emite alertas sonoros (bipes de sistema) e síntese de voz imediata (`AVSpeechSynthesizer`)
/// aplicando `.duckOthers` temporariamente para reduzir o volume da música/Spotify durante a fala.
@MainActor
public final class VoiceAlertManager: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func announce(analysis: RideAnalysis, enabled: Bool) {
        guard enabled else { return }

        activateDuckingSession()

        // Toca bipe imediato antes da voz para reação instantânea
        switch analysis.verdict {
        case .approved:
            AudioServicesPlaySystemSound(1057) // Som positivo curto
        case .warning:
            AudioServicesPlaySystemSound(1052) // Som de alerta médio
        case .rejected:
            AudioServicesPlaySystemSound(1053) // Som grave de recusa
        }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let speechText = buildSpeechPhrase(for: analysis)
        let utterance = AVSpeechUtterance(string: speechText)
        utterance.voice = AVSpeechSynthesisVoice(language: "pt-BR")
        utterance.rate = 0.54 // Ritmo ágil e claro para leitura rápida no trânsito
        utterance.pitchMultiplier = analysis.verdict == .approved ? 1.08 : 0.95
        utterance.volume = 1.0

        synthesizer.speak(utterance)
    }

    private func buildSpeechPhrase(for analysis: RideAnalysis) -> String {
        let reais = Int(analysis.grossPerKm)
        let centavos = Int(((analysis.grossPerKm - Double(reais)) * 100).rounded())
        let horaInt = Int(analysis.grossPerHour.rounded())
        let lucroInt = Int(analysis.netProfitBRL.rounded())

        let kmFormatted: String
        if centavos > 0 {
            kmFormatted = "\(reais) e \(centavos) por quilômetro"
        } else {
            kmFormatted = "\(reais) reais por quilômetro"
        }

        switch analysis.verdict {
        case .approved:
            return "Boa! \(kmFormatted). \(horaInt) por hora. Lucro \(lucroInt) reais."
        case .warning:
            return "Atenção! \(kmFormatted). \(horaInt) por hora."
        case .rejected:
            return "Recusar! Apenas \(kmFormatted)."
        }
    }

    private func activateDuckingSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers, .duckOthers])
        try? session.setActive(true)
    }

    private func restoreBackgroundMixSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        restoreBackgroundMixSession()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        restoreBackgroundMixSession()
    }
}

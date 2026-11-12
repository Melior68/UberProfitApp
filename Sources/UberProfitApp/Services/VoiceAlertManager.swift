import Foundation
import AVFoundation
import AudioToolbox

/// Emite alertas sonoros (bipes de sistema) e síntese de voz imediata (`AVSpeechSynthesizer`)
/// totalmente personalizável (Completa, Curta ou Apenas Boas/Atenção, além da velocidade da fala).
@MainActor
public final class VoiceAlertManager: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    public var onSpeechFinished: (() -> Void)?

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func announce(analysis: RideAnalysis, settings: DriverSettings) {
        guard settings.voiceAlertsEnabled else { return }

        // Toca bipe imediato antes da voz
        switch analysis.verdict {
        case .approved:
            AudioServicesPlaySystemSound(1057)
        case .warning:
            AudioServicesPlaySystemSound(1052)
        case .rejected:
            AudioServicesPlaySystemSound(1053)
        }

        // Se o motorista escolheu "Falar Só Boas/Atenção", nas recusadas toca apenas o bipe curto acima e não fala voz
        if settings.voiceSpeechStyle == .approvedAndWarningOnly && analysis.verdict == .rejected {
            return
        }

        activateDuckingSession()

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let speechText = buildSpeechPhrase(for: analysis, settings: settings)
        let utterance = AVSpeechUtterance(string: speechText)
        utterance.voice = AVSpeechSynthesisVoice(language: "pt-BR")
        utterance.rate = Float(settings.voiceSpeechRate)
        utterance.pitchMultiplier = analysis.verdict == .approved ? 1.08 : 0.95
        utterance.volume = 1.0

        synthesizer.speak(utterance)
    }

    private func buildSpeechPhrase(for analysis: RideAnalysis, settings: DriverSettings) -> String {
        let kmValue = (settings.primaryMetricDisplay == .net) ? analysis.netPerKm : analysis.grossPerKm
        let hourValue = (settings.primaryMetricDisplay == .net) ? analysis.netPerHour : analysis.grossPerHour

        let reais = Int(max(kmValue, 0))
        let centavos = Int(((max(kmValue, 0) - Double(reais)) * 100).rounded())
        let horaInt = Int(max(hourValue, 0).rounded())
        let lucroInt = Int(analysis.netProfitBRL.rounded())

        let kmFormatted: String
        if centavos > 0 {
            kmFormatted = "\(reais) e \(centavos) por quilômetro"
        } else {
            kmFormatted = "\(reais) reais por quilômetro"
        }

        if settings.voiceSpeechStyle == .compact {
            switch analysis.verdict {
            case .approved:
                return "Boa! \(kmFormatted). Lucro \(lucroInt)."
            case .warning:
                return "Atenção! \(kmFormatted)."
            case .rejected:
                return "Recusar! \(kmFormatted)."
            }
        }

        switch analysis.verdict {
        case .approved:
            return "Boa! \(kmFormatted). \(horaInt) por hora. Lucro \(lucroInt) reais."
        case .warning:
            return "Atenção! \(kmFormatted). \(horaInt) por hora."
        case .rejected:
            return "Recusar! \(kmFormatted)."
        }
    }

    private func activateDuckingSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
        try? session.setActive(true)
    }

    private func restoreBackgroundMixSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        onSpeechFinished?()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        restoreBackgroundMixSession()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        restoreBackgroundMixSession()
    }
}

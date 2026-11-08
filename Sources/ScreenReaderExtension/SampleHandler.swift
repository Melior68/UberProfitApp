import ReplayKit
import Vision
import Network
import CoreImage
import UIKit

/// Payload compartilhado enviado via UDP local para o App Principal
public struct RideOfferPayload: Codable, Sendable {
    public let appSource: String?
    public let fareBRL: Double
    public let pickupDistanceKm: Double
    public let tripDistanceKm: Double
    public let totalDistanceKm: Double
    public let pickupMinutes: Int
    public let tripMinutes: Int
    public let totalMinutes: Int
    public let rawRecognizedText: String
    public let timestamp: TimeInterval
}

private struct RecognizedLine {
    let text: String
    let midY: CGFloat
    let height: CGFloat
}

@objc(SampleHandler)
public final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {

    // MARK: - Configurações de Performance e Limites
    private let throttleInterval: TimeInterval = 0.35 // 1 frame a cada 0.35s
    private let heartbeatInterval: TimeInterval = 2.0
    private let debounceInterval: TimeInterval = 10.0
    private let udpHost: NWEndpoint.Host = "127.0.0.1"
    private let udpPort: NWEndpoint.Port = 9876

    // MARK: - Estado Interno
    private var lastProcessedTime: TimeInterval = 0
    private var lastHeartbeatTime: TimeInterval = 0
    private var recentOfferHashes: [Int: TimeInterval] = [:]
    private var isProcessingFrame: Bool = false
    private var udpConnection: NWConnection?
    private let processingQueue = DispatchQueue(label: "com.uberprofit.screenreader.vision", qos: .userInteractive)

    // MARK: - Regex Pré-Compiladas (Suporta Uber e 99 Motorista com ou sem espaço após R$)
    private static let priceRegex = try! NSRegularExpression(
        pattern: #"(?<!\+)(?:R\s*\$|RS|\$)\s*(\d{1,3}(?:[.,]\d{2}))(?!\s*/)"#,
        options: [.caseInsensitive]
    )
    private static let uberOr99StepRegex = try! NSRegularExpression(
        pattern: #"(?:(\d{1,2})\s*h(?:oras?)?\s*)?(\d{1,3})\s*min(?:utos?)?\s*\(\s*(\d{1,3}(?:[.,]\d{1,2})?)\s*(km|m)\s*\)"#,
        options: [.caseInsensitive]
    )
    private static let uberSummaryRegex = try! NSRegularExpression(
        pattern: #"(?:(\d{1,2})\s*h(?:oras?)?\s*)?(\d{1,3})\s*min(?:utos?)?\s*[•·\-]\s*(\d{1,3}(?:[.,]\d{1,2})?)\s*(km|m)\b"#,
        options: [.caseInsensitive]
    )
    private static let genericDistanceRegex = try! NSRegularExpression(
        pattern: #"(?<!/)\b(\d{1,3}(?:[.,]\d{1,2})?)\s*(km|m)\b(?!\s*/)"#,
        options: [.caseInsensitive]
    )
    private static let genericDurationRegex = try! NSRegularExpression(
        pattern: #"(?:(\d{1,2})\s*h(?:oras?)?\s*)?(\d{1,3})\s*min(?:utos?)?\b"#,
        options: [.caseInsensitive]
    )

    // MARK: - Ciclo de Vida do ReplayKit
    public override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        setupUDPConnection()
        sendPingStatus(status: "BROADCAST_STARTED")
    }

    public override func broadcastPaused() {
        sendPingStatus(status: "BROADCAST_PAUSED")
    }

    public override func broadcastResumed() {
        setupUDPConnection()
        sendPingStatus(status: "BROADCAST_RESUMED")
    }

    public override func broadcastFinished() {
        sendPingStatus(status: "BROADCAST_FINISHED")
        udpConnection?.cancel()
        udpConnection = nil
    }

    public override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        let now = CACurrentMediaTime()

        if (now - lastHeartbeatTime) >= heartbeatInterval {
            lastHeartbeatTime = now
            sendPingStatus(status: "BROADCAST_ACTIVE")
        }

        guard (now - lastProcessedTime) >= throttleInterval, !isProcessingFrame else {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        lastProcessedTime = now
        isProcessingFrame = true

        let orientationRaw = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? UInt32
        let cgOrientation = CGImagePropertyOrientation(rawValue: orientationRaw ?? CGImagePropertyOrientation.up.rawValue) ?? .up

        autoreleasepool {
            defer { isProcessingFrame = false }
            performFastOCR(on: pixelBuffer, orientation: cgOrientation, timestamp: Date().timeIntervalSince1970)
        }
    }

    // MARK: - OCR de Baixa Latência
    private func performFastOCR(on pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, timestamp: TimeInterval) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.010
        // 70% inferiores da tela onde surgem os cards da Uber e da 99 Motorista
        request.regionOfInterest = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.70)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }

        guard let observations = request.results, !observations.isEmpty else {
            return
        }

        let sortedObservations = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }

        var recognizedLines: [RecognizedLine] = []
        recognizedLines.reserveCapacity(sortedObservations.count)

        for obs in sortedObservations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let clean = candidate.string.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }

            if isSelfOverlayLine(clean) {
                continue
            }

            recognizedLines.append(
                RecognizedLine(
                    text: clean,
                    midY: obs.boundingBox.midY,
                    height: obs.boundingBox.height
                )
            )
        }

        guard !recognizedLines.isEmpty,
              let payload = parseRideCard(from: recognizedLines, timestamp: timestamp) else {
            return
        }

        let offerHash = computeOfferHash(fare: payload.fareBRL, totalKm: payload.totalDistanceKm, totalMin: payload.totalMinutes)
        pruneExpiredHashes(now: timestamp)

        if let lastSeen = recentOfferHashes[offerHash], (timestamp - lastSeen) < debounceInterval {
            return
        }

        recentOfferHashes[offerHash] = timestamp
        sendOfferViaUDP(payload)
    }

    private func isSelfOverlayLine(_ line: String) -> Bool {
        let upper = line.uppercased()
        return upper.contains("PROFIT ATIVO") ||
               upper.contains("UBERPROFIT") ||
               upper.contains("LUCRO R$") ||
               upper.contains("LUCRO LIVRE:") ||
               upper.contains("COMB. -R$") ||
               upper.contains("GASOLINA: -R$") ||
               upper.contains("KM TOTAL") ||
               upper.contains("MONITORANDO OFERTAS") ||
               upper.contains("SIMULAR CORRIDA")
    }

    // MARK: - Parser Universal para Uber Driver e 99 Motorista
    private func parseRideCard(from lines: [RecognizedLine], timestamp: TimeInterval) -> RideOfferPayload? {
        let fullText = lines.map(\.text).joined(separator: "\n")
        let lowerFull = fullText.lowercased()

        // Identifica automaticamente se o card é da 99 Motorista ou da Uber Driver
        let is99Card = lowerFull.contains("99") ||
                       lowerFull.contains("pgto") ||
                       lowerFull.contains("tarifa base") ||
                       lowerFull.contains("cpf verif") ||
                       lowerFull.contains("perfil premium") ||
                       lowerFull.contains("corridas") ||
                       lowerFull.contains("negocia") ||
                       lowerFull.contains("poupa")

        let appSource = is99Card ? "99" : "UBER"

        // 1. Extrai a Tarifa Principal em Reais (ignorando adicionais "+R$ 3,50 incluído" e "R$3,34 Tarifa base dinâmica incl.")
        guard let fare = extractMainFareBRL(from: lines), fare >= 4.0, fare <= 950.0 else {
            return nil
        }

        // 2. Extrai Distâncias e Tempos somando busca + viagem sem duplicar linha de resumo
        let (pickupKm, tripKm, totalKm, pickupMin, tripMin, totalMin) = extractDistancesAndDurations(from: lines, fullText: fullText)

        guard totalKm >= 0.2, totalMin >= 1 else {
            return nil
        }

        return RideOfferPayload(
            appSource: appSource,
            fareBRL: fare,
            pickupDistanceKm: pickupKm,
            tripDistanceKm: tripKm,
            totalDistanceKm: totalKm,
            pickupMinutes: pickupMin,
            tripMinutes: tripMin,
            totalMinutes: totalMin,
            rawRecognizedText: fullText,
            timestamp: timestamp
        )
    }

    private func extractMainFareBRL(from lines: [RecognizedLine]) -> Double? {
        var candidates: [(value: Double, height: CGFloat)] = []

        for line in lines {
            let lower = line.text.lowercased()
            // Ignora linhas de bônus/adicional da Uber e da 99 ("+R$ 3,50 incluído", "R$3,34 Tarifa base dinâmica incl.", "Est. de R$1,91/km")
            if lower.contains("incluíd") ||
               lower.contains("incluid") ||
               lower.contains("incl.") ||
               lower.contains("tarifa base") ||
               lower.contains("dinâmica") ||
               lower.contains("dinamica") ||
               lower.contains("prioritária") ||
               lower.contains("prioritaria") ||
               lower.contains("est. de") ||
               lower.contains("/km") ||
               lower.contains("/h") {
                continue
            }

            let nsRange = NSRange(line.text.startIndex..<line.text.endIndex, in: line.text)
            let matches = Self.priceRegex.matches(in: line.text, options: [], range: nsRange)

            for match in matches {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: line.text) else { continue }
                let rawValue = line.text[range].replacingOccurrences(of: ",", with: ".")
                if let value = Double(rawValue), value >= 4.0, value <= 950.0 {
                    candidates.append((value: value, height: line.height))
                }
            }
        }

        guard !candidates.isEmpty else { return nil }

        // Prioriza a maior fonte do card, mas também garante pegar o maior valor principal caso o OCR divida a caixa
        let maxHeight = candidates.map(\.height).max() ?? 0
        let prominent = candidates.filter { $0.height >= maxHeight * 0.65 }
        return prominent.map(\.value).max() ?? candidates.map(\.value).max()
    }

    private func extractDistancesAndDurations(from lines: [RecognizedLine], fullText: String) -> (Double, Double, Double, Int, Int, Int) {
        let nsFullRange = NSRange(fullText.startIndex..<fullText.endIndex, in: fullText)

        // 1. Verifica se existe a linha de resumo explícita da Uber: ex: "15 min • 5.4 km • Est. de R$1,91/km"
        var summaryResult: (min: Int, km: Double)? = nil
        if let match = Self.uberSummaryRegex.firstMatch(in: fullText, options: [], range: nsFullRange) {
            var hours = 0
            if let hRange = Range(match.range(at: 1), in: fullText), let h = Int(fullText[hRange]) {
                hours = h
            }
            if let mRange = Range(match.range(at: 2), in: fullText),
               let mins = Int(fullText[mRange]),
               let dRange = Range(match.range(at: 3), in: fullText),
               let uRange = Range(match.range(at: 4), in: fullText),
               let distVal = Double(fullText[dRange].replacingOccurrences(of: ",", with: ".")) {
                let unit = fullText[uRange].lowercased()
                let km = (unit == "m") ? (distVal / 1000.0) : distVal
                let totalMins = (hours * 60) + mins
                if km > 0 && totalMins > 0 {
                    summaryResult = (min: totalMins, km: km)
                }
            }
        }

        // 2. Verifica os passos detalhados entre parênteses (usado tanto na Uber quanto na 99!):
        // Ex Uber: "3 min (0.8 km)" e "12 minutos (5.2 km)"
        // Ex 99:   "8 min (3,2 km)" e "13 min (7,2 km)"
        var parenSteps: [(min: Int, km: Double)] = []
        let stepMatches = Self.uberOr99StepRegex.matches(in: fullText, options: [], range: nsFullRange)
        for match in stepMatches {
            var hours = 0
            if let hRange = Range(match.range(at: 1), in: fullText), let h = Int(fullText[hRange]) {
                hours = h
            }
            guard let mRange = Range(match.range(at: 2), in: fullText),
                  let mins = Int(fullText[mRange]),
                  let dRange = Range(match.range(at: 3), in: fullText),
                  let uRange = Range(match.range(at: 4), in: fullText),
                  let distVal = Double(fullText[dRange].replacingOccurrences(of: ",", with: ".")) else { continue }

            let unit = fullText[uRange].lowercased()
            let distKm = (unit == "m") ? (distVal / 1000.0) : distVal
            let totalMins = (hours * 60) + mins

            if distKm > 0 && totalMins > 0 {
                parenSteps.append((min: totalMins, km: distKm))
            }
        }

        if parenSteps.count >= 2 {
            let pKm = parenSteps[0].km
            let tKm = parenSteps[1].km
            let pMin = parenSteps[0].min
            let tMin = parenSteps[1].min
            let sumKm = pKm + tKm
            let sumMin = pMin + tMin

            if let summary = summaryResult, summary.km > sumKm {
                return (pKm, summary.km - pKm, summary.km, pMin, max(summary.min - pMin, 1), summary.min)
            }
            return (pKm, tKm, sumKm, pMin, tMin, sumMin)
        }

        if let summary = summaryResult {
            if let firstStep = parenSteps.first, summary.km > firstStep.km {
                let tripKm = summary.km - firstStep.km
                let tripMin = max(summary.min - firstStep.min, 1)
                return (firstStep.km, tripKm, summary.km, firstStep.min, tripMin, summary.min)
            }
            return (0.0, summary.km, summary.km, 0, summary.min, summary.min)
        }

        // 3. Fallback genérico para quando o OCR não leu os parênteses
        let cleanLines = lines.map(\.text).filter { line in
            let lower = line.lowercased()
            return !lower.contains("/km") && !lower.contains("est. de")
        }
        let cleanText = cleanLines.joined(separator: "\n")

        let distancesKm = extractGenericDistancesKm(from: cleanText)
        let durationsMin = extractGenericDurationsMin(from: cleanText)

        guard !distancesKm.isEmpty, !durationsMin.isEmpty else {
            return (0, 0, 0, 0, 0, 0)
        }

        let pickupKm: Double
        let tripKm: Double
        if distancesKm.count >= 2 {
            pickupKm = distancesKm[0]
            tripKm = distancesKm[1]
        } else {
            pickupKm = 0.0
            tripKm = distancesKm[0]
        }

        let pickupMin: Int
        let tripMin: Int
        if durationsMin.count >= 2 {
            pickupMin = durationsMin[0]
            tripMin = durationsMin[1]
        } else {
            pickupMin = 0
            tripMin = durationsMin[0]
        }

        return (pickupKm, tripKm, pickupKm + tripKm, pickupMin, tripMin, pickupMin + tripMin)
    }

    private func extractGenericDistancesKm(from text: String) -> [Double] {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = Self.genericDistanceRegex.matches(in: text, options: [], range: nsRange)

        var results: [Double] = []
        for match in matches {
            guard match.numberOfRanges > 2,
                  let valRange = Range(match.range(at: 1), in: text),
                  let unitRange = Range(match.range(at: 2), in: text) else { continue }

            let rawVal = text[valRange].replacingOccurrences(of: ",", with: ".")
            let unit = text[unitRange].lowercased()
            guard let value = Double(rawVal) else { continue }

            if unit == "m" {
                if value >= 50 && value <= 999 {
                    results.append(value / 1000.0)
                }
            } else {
                if value > 0 && value < 600 {
                    results.append(value)
                }
            }
        }

        return Array(results.prefix(2))
    }

    private func extractGenericDurationsMin(from text: String) -> [Int] {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = Self.genericDurationRegex.matches(in: text, options: [], range: nsRange)

        var durations: [Int] = []
        for match in matches {
            var hours = 0
            if match.numberOfRanges > 1,
               let hRange = Range(match.range(at: 1), in: text),
               let hVal = Int(text[hRange]) {
                hours = hVal
            }

            if match.numberOfRanges > 2,
               let mRange = Range(match.range(at: 2), in: text),
               let mVal = Int(text[mRange]) {
                let totalMinutes = (hours * 60) + mVal
                if totalMinutes > 0 && totalMinutes <= 480 {
                    durations.append(totalMinutes)
                }
            }
        }

        return Array(durations.prefix(2))
    }

    // MARK: - Debouncing
    private func computeOfferHash(fare: Double, totalKm: Double, totalMin: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(Int((fare * 100).rounded()))
        hasher.combine(Int((totalKm * 10).rounded()))
        hasher.combine(totalMin)
        return hasher.finalize()
    }

    private func pruneExpiredHashes(now: TimeInterval) {
        recentOfferHashes = recentOfferHashes.filter { (_, timestamp) in
            (now - timestamp) < debounceInterval
        }
    }

    // MARK: - Envio UDP Local (127.0.0.1:9876)
    private func setupUDPConnection() {
        udpConnection?.cancel()
        let connection = NWConnection(host: udpHost, port: udpPort, using: .udp)
        connection.start(queue: processingQueue)
        self.udpConnection = connection
    }

    private func sendOfferViaUDP(_ payload: RideOfferPayload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        if udpConnection == nil {
            setupUDPConnection()
        }
        udpConnection?.send(content: data, completion: .contentProcessed({ _ in }))
    }

    private func sendPingStatus(status: String) {
        let packet: [String: String] = ["status": status]
        guard let data = try? JSONSerialization.data(withJSONObject: packet, options: []) else { return }
        if udpConnection == nil {
            setupUDPConnection()
        }
        udpConnection?.send(content: data, completion: .contentProcessed({ _ in }))
    }
}

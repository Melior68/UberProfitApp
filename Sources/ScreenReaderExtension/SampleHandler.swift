import ReplayKit
import Vision
import Network
import CoreImage
import UIKit

/// Payload compartilhado enviado via UDP local para o App Principal
public struct RideOfferPayload: Codable, Sendable {
    public let appSource: String // "UBER" ou "99"
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
    private let throttleInterval: TimeInterval = 0.40 // 1 frame a cada 0.4s
    private let heartbeatInterval: TimeInterval = 2.0 // Pulso a cada 2.0s para manter status "Leitor Ativo" na UI
    private let debounceInterval: TimeInterval = 12.0 // Ignora a mesma oferta por 12s
    private let udpHost: NWEndpoint.Host = "127.0.0.1"
    private let udpPort: NWEndpoint.Port = 9876

    // MARK: - Estado Interno
    private var lastProcessedTime: TimeInterval = 0
    private var lastHeartbeatTime: TimeInterval = 0
    private var recentOfferHashes: [Int: TimeInterval] = [:]
    private var isProcessingFrame: Bool = false
    private var udpConnection: NWConnection?
    private let processingQueue = DispatchQueue(label: "com.uberprofit.screenreader.vision", qos: .userInteractive)

    // MARK: - Regex Pré-Compiladas (Zero Alocação por Frame)
    private static let priceRegex = try! NSRegularExpression(
        pattern: #"(?<!\+)\b(?:R\$|RS)\s*(\d{1,3}(?:[.,]\d{2}))(?!\s*/)"#,
        options: [.caseInsensitive]
    )
    private static let uberStepRegex = try! NSRegularExpression(
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

        // Envia Heartbeat periódico para o App Principal saber que a extensão está viva e capturando
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

        // Processamento síncrono dentro de autoreleasepool rigoroso para nunca ultrapassar o limite de 50 MB de RAM
        autoreleasepool {
            defer { isProcessingFrame = false }
            performFastOCR(on: pixelBuffer, orientation: cgOrientation, timestamp: Date().timeIntervalSince1970)
        }
    }

    // MARK: - OCR de Baixa Latência com Filtro Anti-AutoLeitura
    private func performFastOCR(on pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, timestamp: TimeInterval) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.011
        // 70% inferiores da tela para cobrir integralmente os cards da Uber e da 99 Motorista
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

        // Ordena de cima para baixo (maior midY no Vision = mais alto na tela)
        let sortedObservations = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }

        var recognizedLines: [RecognizedLine] = []
        recognizedLines.reserveCapacity(sortedObservations.count)

        for obs in sortedObservations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let clean = candidate.string.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }

            // Filtra linhas que pertençam à nossa própria janela PiP ou Notificação caso estejam na parte de baixo
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
        return upper.contains("UBER PROFIT") ||
               upper.contains("UBERPROFIT") ||
               upper.contains("LUCRO R$") ||
               upper.contains("COMB. -R$") ||
               upper.contains("KM TOTAL") ||
               upper.contains("MONITORANDO OFERTAS")
    }

    // MARK: - Parser Inteligente (Uber Driver + 99 Motorista)
    private func parseRideCard(from lines: [RecognizedLine], timestamp: TimeInterval) -> RideOfferPayload? {
        let fullText = lines.map(\.text).joined(separator: "\n")
        let lowerFull = fullText.lowercased()

        // Confirma que existe um botão/indicador de card de oferta real na tela para evitar ler tela de ganhos passados
        let hasOfferContext = lowerFull.contains("aceitar") ||
                              lowerFull.contains("tenho interesse") ||
                              lowerFull.contains("exclusivo") ||
                              lowerFull.contains("uberx") ||
                              lowerFull.contains("priority") ||
                              lowerFull.contains("comfort") ||
                              lowerFull.contains("black") ||
                              lowerFull.contains("flash") ||
                              lowerFull.contains("moto") ||
                              lowerFull.contains("99pop") ||
                              lowerFull.contains("99plus") ||
                              lowerFull.contains("99") ||
                              lowerFull.contains("est. de") ||
                              lowerFull.contains("min (")

        guard hasOfferContext else { return nil }

        // Detecta origem (Uber vs 99)
        let appSource: String
        if lowerFull.contains("99") || lowerFull.contains("negocia") || lowerFull.contains("poupa") {
            appSource = "99"
        } else {
            appSource = "UBER"
        }

        // 1. Extrai Tarifa Principal priorizando a maior altura visual da fonte (BoundingBox Height)
        guard let fare = extractMainFareBRL(from: lines), fare >= 4.0, fare <= 950.0 else {
            return nil
        }

        // 2. Extrai Distâncias e Tempos com proteção contra soma duplicada da linha de resumo da Uber
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
            // Ignora linhas de bônus adicional ("+R$ 2,12 incluída") ou estimativa por km ("Est. de R$1,91/km")
            if lower.contains("incluíd") || lower.contains("incluid") || lower.contains("est. de") || lower.contains("/km") || lower.contains("/h") {
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

        // O preço principal da corrida na Uber e na 99 é sempre desenhado com a maior fonte do card.
        // Se houver candidatos com pelo menos 75% da altura da maior fonte encontrada, pega o maior valor entre eles.
        let maxHeight = candidates.map(\.height).max() ?? 0
        let prominentCandidates = candidates.filter { $0.height >= maxHeight * 0.75 }
        return prominentCandidates.map(\.value).max() ?? candidates.map(\.value).max()
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

        // 2. Verifica os passos detalhados entre parênteses da Uber: ex: "3 min (0.7 km)" e "12 minutos (4.7 km)"
        var parenSteps: [(min: Int, km: Double)] = []
        let stepMatches = Self.uberStepRegex.matches(in: fullText, options: [], range: nsFullRange)
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

        // Se encontrou os 2 passos detalhados da Uber ("3 min (0.7 km)" + "12 minutos (4.7 km)")
        if parenSteps.count >= 2 {
            let pKm = parenSteps[0].km
            let tKm = parenSteps[1].km
            let pMin = parenSteps[0].min
            let tMin = parenSteps[1].min
            let sumKm = pKm + tKm
            let sumMin = pMin + tMin

            // Validação cruzada com a linha de resumo caso ambos existam
            if let summary = summaryResult, summary.km > sumKm {
                return (pKm, summary.km - pKm, summary.km, pMin, max(summary.min - pMin, 1), summary.min)
            }
            return (pKm, tKm, sumKm, pMin, tMin, sumMin)
        }

        // Se o card ainda estava subindo na tela e o OCR leu a linha de resumo ("15 min • 5.4 km") mas só 1 passo entre parênteses:
        // Usa obrigatoriamente a linha de resumo para nunca subestimar a distância da corrida!
        if let summary = summaryResult {
            if let firstStep = parenSteps.first, summary.km > firstStep.km {
                let tripKm = summary.km - firstStep.km
                let tripMin = max(summary.min - firstStep.min, 1)
                return (firstStep.km, tripKm, summary.km, firstStep.min, tripMin, summary.min)
            }
            return (0.0, summary.km, summary.km, 0, summary.min, summary.min)
        }

        // 3. Caso 99 Motorista ou layout sem linha de resumo da Uber
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
                // Distâncias de busca em metros na 99 ou Uber (50m a 999m)
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

import ReplayKit
import Vision
import Network
import CoreImage
import UIKit

/// Payload compartilhado enviado via UDP local para o App Principal
public struct RideOfferPayload: Codable, Sendable {
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

@objc(SampleHandler)
public final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {

    // MARK: - Configurações de Performance e Limites
    private let throttleInterval: TimeInterval = 0.40 // 1 frame a cada 0.4s
    private let debounceInterval: TimeInterval = 12.0 // Ignora a mesma oferta por 12s
    private let udpHost: NWEndpoint.Host = "127.0.0.1"
    private let udpPort: NWEndpoint.Port = 9876

    // MARK: - Estado Interno
    private var lastProcessedTime: TimeInterval = 0
    private var recentOfferHashes: [Int: TimeInterval] = [:]
    private var isProcessingFrame: Bool = false
    private var udpConnection: NWConnection?
    private let processingQueue = DispatchQueue(label: "com.uberprofit.screenreader.vision", qos: .userInteractive)

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

        // Processamento síncrono com autoreleasepool rigoroso para respeitar o limite de 50 MB de RAM das extensões iOS
        autoreleasepool {
            defer { isProcessingFrame = false }
            performFastOCR(on: pixelBuffer, orientation: cgOrientation, timestamp: Date().timeIntervalSince1970)
        }
    }

    // MARK: - OCR de Baixa Latência e Baixa Memória
    private func performFastOCR(on pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, timestamp: TimeInterval) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.012
        // 65% inferiores da tela para cobrir integralmente os cards da Uber Driver e da 99 Motorista
        request.regionOfInterest = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.65)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }

        guard let observations = request.results, !observations.isEmpty else {
            return
        }

        // Ordena de cima para baixo (no Vision, maior Y = mais alto na tela)
        let sortedObservations = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }

        var lines: [String] = []
        lines.reserveCapacity(sortedObservations.count)

        for observation in sortedObservations {
            if let topCandidate = observation.topCandidates(1).first {
                lines.append(topCandidate.string)
            }
        }

        let fullText = lines.joined(separator: "\n")
        guard let payload = parseRideCard(from: fullText, lines: lines, timestamp: timestamp) else {
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

    // MARK: - Extração Inteligente para Uber Driver e 99 Motorista
    private func parseRideCard(from text: String, lines: [String], timestamp: TimeInterval) -> RideOfferPayload? {
        let normalized = text.replacingOccurrences(of: "\u{00A0}", with: " ")

        // Ignora caso o próprio card do PiP tenha sido lido por engano
        if normalized.contains("UBER PROFIT ATIVO") || normalized.contains("LUCRO R$") {
            return nil
        }

        // 1. Extrai a Tarifa Principal em Reais (ignorando "+R$ X,XX" de dinâmico e "R$ X,XX/km" de estimativa)
        guard let fare = extractMainFareBRL(from: lines), fare >= 4.0, fare <= 950.0 else {
            return nil
        }

        // 2. Extrai Distâncias e Tempos evitando duplicar a linha de resumo da Uber ("15 min • 5.4 km • Est. de R$1,91/km")
        let (pickupKm, tripKm, totalKm, pickupMin, tripMin, totalMin) = extractDistancesAndDurations(from: lines, fullText: normalized)

        guard totalKm >= 0.2, totalMin >= 1 else {
            return nil
        }

        return RideOfferPayload(
            fareBRL: fare,
            pickupDistanceKm: pickupKm,
            tripDistanceKm: tripKm,
            totalDistanceKm: totalKm,
            pickupMinutes: pickupMin,
            tripMinutes: tripMin,
            totalMinutes: totalMin,
            rawRecognizedText: normalized,
            timestamp: timestamp
        )
    }

    private func extractMainFareBRL(from lines: [String]) -> Double? {
        // Procura valores em R$ que NÃO sejam bônus "+R$" nem taxa "/km" ou "/h"
        let pattern = #"(?<!\+)\b(?:R\$|RS)\s*(\d{1,3}(?:[.,]\d{2}))(?!\s*/)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        var candidates: [Double] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Ignora linhas de adicional ou estimativa por km
            if trimmed.lowercased().contains("incluíd") || trimmed.lowercased().contains("est. de") {
                continue
            }

            let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            let matches = regex.matches(in: trimmed, options: [], range: nsRange)

            for match in matches {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: trimmed) else { continue }
                let rawValue = trimmed[range].replacingOccurrences(of: ",", with: ".")
                if let value = Double(rawValue), value >= 4.0 {
                    candidates.append(value)
                }
            }
        }

        return candidates.max()
    }

    private func extractDistancesAndDurations(from lines: [String], fullText: String) -> (Double, Double, Double, Int, Int, Int) {
        // CASO 1: Linha de resumo da Uber presente: ex: "15 min • 5.4 km • Est. de R$1,91/km"
        // E/ou linhas detalhadas entre parênteses da Uber: "3 min (0.7 km)" e "12 minutos (4.7 km)"
        var parenSteps: [(min: Int, km: Double)] = []
        let uberStepPattern = #"(?:(\d{1,2})\s*h(?:oras?)?\s*)?(\d{1,3})\s*min(?:utos?)?\s*\(\s*(\d{1,3}(?:[.,]\d{1,2})?)\s*(km|m)\s*\)"#

        if let stepRegex = try? NSRegularExpression(pattern: uberStepPattern, options: [.caseInsensitive]) {
            let nsRange = NSRange(fullText.startIndex..<fullText.endIndex, in: fullText)
            let matches = stepRegex.matches(in: fullText, options: [], range: nsRange)

            for match in matches {
                var hours = 0
                if let hRange = Range(match.range(at: 1), in: fullText), let h = Int(fullText[hRange]) {
                    hours = h
                }
                guard let mRange = Range(match.range(at: 2), in: fullText),
                      let mins = Int(fullText[mRange]),
                      let dRange = Range(match.range(at: 3), in: fullText),
                      let uRange = Range(match.range(at: 4), in: fullText) else { continue }

                let rawDist = fullText[dRange].replacingOccurrences(of: ",", with: ".")
                guard let distVal = Double(rawDist) else { continue }
                let unit = fullText[uRange].lowercased()
                let distKm = (unit == "m") ? (distVal / 1000.0) : distVal
                let totalMins = (hours * 60) + mins

                if distKm > 0 && totalMins > 0 {
                    parenSteps.append((min: totalMins, km: distKm))
                }
            }
        }

        // Se encontrou os 2 passos detalhados da Uber (ex: "3 min (0.7 km)" e "12 minutos (4.7 km)"), usa a soma exata deles!
        if parenSteps.count >= 2 {
            let pKm = parenSteps[0].km
            let tKm = parenSteps[1].km
            let pMin = parenSteps[0].min
            let tMin = parenSteps[1].min
            return (pKm, tKm, pKm + tKm, pMin, tMin, pMin + tMin)
        }

        // CASO 2: Verifica se há a linha de resumo explícita da Uber ("15 min • 5.4 km") mesmo se o OCR perdeu um dos parênteses
        let summaryPattern = #"(\d{1,3})\s*min\s*[•·\-]\s*(\d{1,3}(?:[.,]\d{1,2})?)\s*km"#
        if let sumRegex = try? NSRegularExpression(pattern: summaryPattern, options: [.caseInsensitive]) {
            let nsRange = NSRange(fullText.startIndex..<fullText.endIndex, in: fullText)
            if let match = sumRegex.firstMatch(in: fullText, options: [], range: nsRange),
               let mRange = Range(match.range(at: 1), in: fullText),
               let mins = Int(fullText[mRange]),
               let dRange = Range(match.range(at: 2), in: fullText),
               let km = Double(fullText[dRange].replacingOccurrences(of: ",", with: ".")) {
                return (0.0, km, km, 0, mins, mins)
            }
        }

        // CASO 3: Formato 99 Motorista ou formato genérico sem linha de resumo duplicada
        // Filtra linhas que contenham "/km" (estimativa) para não capturar números errados
        let contentLines = lines.filter { !$0.lowercased().contains("/km") }
        let cleanText = contentLines.joined(separator: "\n")

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
        // Captura tanto "1,8 km" quanto metros na 99 Motorista ("650 m" ou "650m")
        let pattern = #"(?<!/)\b(\d{1,3}(?:[.,]\d{1,2})?)\s*(km|m)\b(?!\s*/)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)

        var results: [Double] = []
        for match in matches {
            guard match.numberOfRanges > 2,
                  let valRange = Range(match.range(at: 1), in: text),
                  let unitRange = Range(match.range(at: 2), in: text) else { continue }

            let rawVal = text[valRange].replacingOccurrences(of: ",", with: ".")
            let unit = text[unitRange].lowercased()
            guard let value = Double(rawVal) else { continue }

            if unit == "m" {
                // Na 99 ou Uber, distâncias em metros vão de 50m a 999m
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
        let pattern = #"(?:(\d{1,2})\s*h(?:oras?)?\s*)?(\d{1,3})\s*min(?:utos?)?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)

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

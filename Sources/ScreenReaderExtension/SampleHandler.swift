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

        // Obtém orientação anexada pelo ReplayKit se disponível
        let orientationRaw = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? UInt32
        let cgOrientation = CGImagePropertyOrientation(rawValue: orientationRaw ?? CGImagePropertyOrientation.up.rawValue) ?? .up

        // Processa de forma síncrona dentro de autoreleasepool rigoroso para não reter CVPixelBuffer além do necessário
        // e manter o consumo de RAM muito abaixo do teto de 50 MB das extensões no iOS.
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
        request.minimumTextHeight = 0.015
        // Coordenadas normalizadas do Vision têm origem (0,0) no canto inferior-esquerdo:
        // y: 0.0 até height: 0.55 foca exatamente nos 55% inferiores da tela onde o card da Uber aparece.
        request.regionOfInterest = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.55)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }

        guard let observations = request.results, !observations.isEmpty else {
            return
        }

        var lines: [String] = []
        lines.reserveCapacity(observations.count)

        for observation in observations {
            if let topCandidate = observation.topCandidates(1).first {
                lines.append(topCandidate.string)
            }
        }

        let fullText = lines.joined(separator: "\n")
        guard let payload = parseUberCard(from: fullText, timestamp: timestamp) else {
            return
        }

        // Debounce de 12 segundos baseado nos valores arredondados da oferta
        let offerHash = computeOfferHash(fare: payload.fareBRL, totalKm: payload.totalDistanceKm, totalMin: payload.totalMinutes)
        pruneExpiredHashes(now: timestamp)

        if let lastSeen = recentOfferHashes[offerHash], (timestamp - lastSeen) < debounceInterval {
            return
        }

        recentOfferHashes[offerHash] = timestamp
        sendOfferViaUDP(payload)
    }

    // MARK: - Extração Regex dos Dados do Card da Uber
    private func parseUberCard(from text: String, timestamp: TimeInterval) -> RideOfferPayload? {
        // Normaliza espaços e quebras para facilitar matching
        let normalized = text.replacingOccurrences(of: "\u{00A0}", with: " ")

        // 1. Extrai Tarifa em Reais: ex: "R$ 24,50", "R$24.50", "R$ 8,90"
        guard let fare = extractMaxFareBRL(from: normalized), fare >= 4.0, fare <= 950.0 else {
            return nil
        }

        // 2. Extrai todas as distâncias em km (busca + viagem)
        // Exemplos nos cards da Uber Brasil:
        // "A 5 min (1,8 km) de distância" e "Viagem de 18 min (9,4 km)"
        // Ou em metros quando muito perto: "(450 m)"
        let distancesKm = extractDistancesInKm(from: normalized)
        guard !distancesKm.isEmpty else {
            return nil
        }

        // 3. Extrai todos os tempos em min / h (busca + viagem)
        let durationsMin = extractDurationsInMinutes(from: normalized)
        guard !durationsMin.isEmpty else {
            return nil
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
        let totalKm = pickupKm + tripKm

        let pickupMin: Int
        let tripMin: Int
        if durationsMin.count >= 2 {
            pickupMin = durationsMin[0]
            tripMin = durationsMin[1]
        } else {
            pickupMin = 0
            tripMin = durationsMin[0]
        }
        let totalMin = pickupMin + tripMin

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

    private func extractMaxFareBRL(from text: String) -> Double? {
        // Captura valores precedidos por R$ (ou RS por falha eventual de OCR no cifrão)
        let pattern = #"(?:R\$|RS)\s*(\d{1,3}(?:[.,]\d{2}))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)

        var parsedFares: [Double] = []
        for match in matches {
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else { continue }
            let rawValue = text[range].replacingOccurrences(of: ",", with: ".")
            if let value = Double(rawValue) {
                parsedFares.append(value)
            }
        }

        // No card da Uber, a tarifa principal da corrida é o maior valor em R$ (caso haja dinâmico "+ R$ 3,50 incluído")
        return parsedFares.max()
    }

    private func extractDistancesInKm(from text: String) -> [Double] {
        // Captura valores em km ("1,8 km", "12.4 km") e em metros ("500 m") quando entre parênteses ou seguidos de distância
        let kmPattern = #"(\d{1,3}(?:[.,]\d{1,2})?)\s*km\b"#
        var results: [Double] = []

        if let regex = try? NSRegularExpression(pattern: kmPattern, options: [.caseInsensitive]) {
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = regex.matches(in: text, options: [], range: nsRange)

            for match in matches {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: text) else { continue }
                let normalizedNumber = text[range].replacingOccurrences(of: ",", with: ".")
                if let km = Double(normalizedNumber), km > 0, km < 600 {
                    results.append(km)
                }
            }
        }

        // Se só encontrou 1 distância em km, verifica se o embarque estava em metros ex: "(400 m)"
        if results.count == 1 {
            let meterPattern = #"\(\s*(\d{2,3})\s*m\s*\)"#
            if let mRegex = try? NSRegularExpression(pattern: meterPattern, options: [.caseInsensitive]) {
                let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
                if let match = mRegex.firstMatch(in: text, options: [], range: nsRange),
                   match.numberOfRanges > 1,
                   let range = Range(match.range(at: 1), in: text),
                   let meters = Double(text[range]) {
                    results.insert(meters / 1000.0, at: 0)
                }
            }
        }

        return Array(results.prefix(2))
    }

    private func extractDurationsInMinutes(from text: String) -> [Int] {
        // Suporta formatos como "5 min", "18 min", "1 h 10 min", "1h 5m"
        var durations: [Int] = []

        let pattern = #"(?:(\d{1,2})\s*h(?:oras?)?\s*)?(\d{1,3})\s*min(?:utos?)?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)

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

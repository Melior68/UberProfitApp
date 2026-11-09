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
    private let throttleInterval: TimeInterval = 0.40
    private let heartbeatInterval: TimeInterval = 2.0
    private let debounceInterval: TimeInterval = 25.0 // 25s para não repetir leitura no mesmo card parado
    private let udpHost: NWEndpoint.Host = "127.0.0.1"
    private let udpPort: NWEndpoint.Port = 9876

    // MARK: - Estado Interno
    private var lastProcessedTime: TimeInterval = 0
    private var lastHeartbeatTime: TimeInterval = 0
    private var recentOfferHashes: [Int: TimeInterval] = [:]
    private var lastValidOfferSeenTime: TimeInterval = 0
    private var didSendClearCard: Bool = true
    private var isProcessingFrame: Bool = false
    private var udpConnection: NWConnection?
    private let processingQueue = DispatchQueue(label: "com.uberprofit.screenreader.vision", qos: .userInteractive)

    // MARK: - Regex Pré-Compiladas (Uber Driver + 99 Motorista)
    private static let priceRegex = try! NSRegularExpression(
        pattern: #"(?<!\+)(?:R\s*\$|RS)\s*(\d{1,3}(?:[.,]\d{2}))(?!\s*/)"#,
        options: [.caseInsensitive]
    )
    // Formato Uber e 99 Pop tradicional: "3 min (0.8 km)" ou "8 min (3,2 km)"
    private static let stepOutsideParenRegex = try! NSRegularExpression(
        pattern: #"(?:(\d{1,2})\s*h(?:oras?)?\s*)?(\d{1,3})\s*min(?:utos?)?\s*\(\s*(\d{1,3}(?:[.,]\d{1,2})?)\s*(km|m)\s*\)"#,
        options: [.caseInsensitive]
    )
    // Formato 99 Negocia / Solicitações: "(3 min 1 km)" ou "(19 min 9,2 km)" (tempo e distância juntos dentro do parêntese)
    private static let stepInsideParenRegex = try! NSRegularExpression(
        pattern: #"\(\s*(?:(\d{1,2})\s*h(?:oras?)?\s*)?(\d{1,3})\s*min(?:utos?)?\s+(\d{1,3}(?:[.,]\d{1,2})?)\s*(km|m)\s*\)"#,
        options: [.caseInsensitive]
    )
    // Linha de resumo da Uber: "15 min • 5.4 km • Est. de R$1,91/km"
    private static let uberSummaryRegex = try! NSRegularExpression(
        pattern: #"(?:(\d{1,2})\s*h(?:oras?)?\s*)?(\d{1,3})\s*min(?:utos?)?\s*[•·\-]\s*(\d{1,3}(?:[.,]\d{1,2})?)\s*(km|m)\b"#,
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

    // MARK: - OCR de Baixa Latência com Proteção Anti-Histórico e Auto-Clear
    private func performFastOCR(on pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, timestamp: TimeInterval) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.011
        // Lê a tela inteira verticalmente (0.05 a 0.90) para detectar se estamos dentro do próprio app UberProfit ou tela de Histórico
        request.regionOfInterest = CGRect(x: 0.0, y: 0.04, width: 1.0, height: 0.86)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }

        guard let observations = request.results, !observations.isEmpty else {
            checkAndClearStaleCard(now: timestamp)
            return
        }

        let sortedObservations = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        let allScreenText = sortedObservations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")

        // BLOQUEIO TOTAL SE O MOTORISTA ESTIVER DENTRO DO PRÓPRIO UBERPROFIT OU EM TELAS DE HISTÓRICO/GANHOS!
        if isInsideOwnAppOrHistoryScreen(allScreenText) {
            return
        }

        // Filtra apenas as linhas dos 68% inferiores da tela (onde ficam os cards de corrida) e ignora o próprio PiP
        var cardLines: [RecognizedLine] = []
        for obs in sortedObservations {
            guard obs.boundingBox.midY <= 0.68,
                  let candidate = obs.topCandidates(1).first else { continue }
            let clean = candidate.string.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !isSelfOverlayLine(clean) else { continue }

            cardLines.append(
                RecognizedLine(
                    text: clean,
                    midY: obs.boundingBox.midY,
                    height: obs.boundingBox.height
                )
            )
        }

        guard !cardLines.isEmpty,
              let payload = parseRideCard(from: cardLines, timestamp: timestamp) else {
            checkAndClearStaleCard(now: timestamp)
            return
        }

        lastValidOfferSeenTime = timestamp
        didSendClearCard = false

        let offerHash = computeOfferHash(fare: payload.fareBRL, totalKm: payload.totalDistanceKm, totalMin: payload.totalMinutes)
        pruneExpiredHashes(now: timestamp)

        if let lastSeen = recentOfferHashes[offerHash], (timestamp - lastSeen) < debounceInterval {
            return
        }

        recentOfferHashes[offerHash] = timestamp
        sendOfferViaUDP(payload)
    }

    private func checkAndClearStaleCard(now: TimeInterval) {
        // Se já se passaram 7 segundos desde que o card da corrida sumiu da tela, limpa o PiP automaticamente!
        if !didSendClearCard && (now - lastValidOfferSeenTime) >= 7.0 {
            didSendClearCard = true
            sendPingStatus(status: "CLEAR_CARD")
        }
    }

    private func isInsideOwnAppOrHistoryScreen(_ screenText: String) -> Bool {
        let upper = screenText.uppercased()
        // 1. Detecta se a tela aberta é o próprio app Uber & 99 Profit Auto (Painel, Metas, Personalizar, Histórico)
        if upper.contains("UBER & 99 PROFIT AUTO") ||
           upper.contains("METAS & CARRO") ||
           upper.contains("MONITORAMENTO AO VIVO") ||
           upper.contains("OFERTAS REGISTRADAS") ||
           upper.contains("TESTAR FUNCIONAMENTO") ||
           upper.contains("SIMULAR CORRIDA") ||
           upper.contains("DIAGNÓSTICO OCR") ||
           upper.contains("COMO FUNCIONA (3 PASSOS)") ||
           upper.contains("2º PLANO SEMPRE ATIVO") {
            return true
        }

        // 2. Detecta se o motorista está olhando o histórico de corridas/ganhos passados dentro da Uber ou da 99
        if upper.contains("HISTÓRICO DE VIAGENS") ||
           upper.contains("HISTÓRICO DE CORRIDAS") ||
           upper.contains("DETALHES DA VIAGEM") ||
           upper.contains("DETALHES DOS GANHOS") ||
           upper.contains("RESUMO DE GANHOS") ||
           upper.contains("VIAGEM CONCLUÍDA") ||
           upper.contains("CORRIDA FINALIZADA") ||
           upper.contains("EXTRATO") {
            return true
        }

        return false
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
               upper.contains("[UBER]") ||
               upper.contains("[99]")
    }

    // MARK: - Parser Rigoroso para Cards de Oferta Reais (Uber Driver + 99 Motorista)
    private func parseRideCard(from lines: [RecognizedLine], timestamp: TimeInterval) -> RideOfferPayload? {
        let fullText = lines.map(\.text).joined(separator: "\n")
        let lowerFull = fullText.lowercased()

        // Se for a gavetinha recolhida "Solicitações (X)" + "Buscando" da 99, precisamos garantir que as 2 linhas
        // (busca + destino) estejam visíveis e não cortadas pela barra "Buscando"
        let isCollapsed99Drawer = lowerFull.contains("solicitações") || lowerFull.contains("solicitacoes") || lowerFull.contains("buscando")

        let is99Card = isCollapsed99Drawer ||
                       lowerFull.contains("99") ||
                       lowerFull.contains("pgto") ||
                       lowerFull.contains("tarifa base") ||
                       lowerFull.contains("cpf verif") ||
                       lowerFull.contains("perfil premium") ||
                       lowerFull.contains("corridas") ||
                       lowerFull.contains("negocia") ||
                       lowerFull.contains("poupa")

        let appSource = is99Card ? "99" : "UBER"

        // 1. Extrai a Tarifa Principal em Reais
        guard let fare = extractMainFareBRL(from: lines), fare >= 4.5, fare <= 950.0 else {
            return nil
        }

        // 2. Extrai Distâncias e Tempos exigindo formato estruturado de card de oferta
        let (pickupKm, tripKm, totalKm, pickupMin, tripMin, totalMin, stepCount) = extractStructuredSteps(from: fullText)

        // Se estiver na gaveta recolhida "Solicitações / Buscando" da 99 e a segunda linha estiver cortada (stepCount < 2),
        // ignora até o motorista abrir o card completo para NUNCA calcular só 1 km (R$ 9,44/km falso)!
        if isCollapsed99Drawer && stepCount < 2 {
            return nil
        }

        guard totalKm >= 0.4, totalMin >= 1 else {
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
               lower.contains("/h") ||
               lower.contains("lucro") ||
               lower.contains("comb") {
                continue
            }

            let nsRange = NSRange(line.text.startIndex..<line.text.endIndex, in: line.text)
            let matches = Self.priceRegex.matches(in: line.text, options: [], range: nsRange)

            for match in matches {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: line.text) else { continue }
                let rawValue = line.text[range].replacingOccurrences(of: ",", with: ".")
                if let value = Double(rawValue), value >= 4.5, value <= 950.0 {
                    candidates.append((value: value, height: line.height))
                }
            }
        }

        guard !candidates.isEmpty else { return nil }

        let maxHeight = candidates.map(\.height).max() ?? 0
        let prominent = candidates.filter { $0.height >= maxHeight * 0.65 }
        return prominent.map(\.value).max() ?? candidates.map(\.value).max()
    }

    private func extractStructuredSteps(from fullText: String) -> (Double, Double, Double, Int, Int, Int, Int) {
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

        // 2. Coleta passos no formato "8 min (3,2 km)" (Uber e 99 Pop) + formato "(3 min 1 km)" (99 Negocia)
        var steps: [(min: Int, km: Double)] = []

        for regex in [Self.stepOutsideParenRegex, Self.stepInsideParenRegex] {
            let matches = regex.matches(in: fullText, options: [], range: nsFullRange)
            for match in matches {
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
                    steps.append((min: totalMins, km: distKm))
                }
            }
        }

        if steps.count >= 2 {
            let pKm = steps[0].km
            let tKm = steps[1].km
            let pMin = steps[0].min
            let tMin = steps[1].min
            let sumKm = pKm + tKm
            let sumMin = pMin + tMin

            if let summary = summaryResult, summary.km > sumKm {
                return (pKm, summary.km - pKm, summary.km, pMin, max(summary.min - pMin, 1), summary.min, 2)
            }
            return (pKm, tKm, sumKm, pMin, tMin, sumMin, 2)
        }

        if let summary = summaryResult {
            if let firstStep = steps.first, summary.km > firstStep.km {
                let tripKm = summary.km - firstStep.km
                let tripMin = max(summary.min - firstStep.min, 1)
                return (firstStep.km, tripKm, summary.km, firstStep.min, tripMin, summary.min, 2)
            }
            return (0.0, summary.km, summary.km, 0, summary.min, summary.min, 2)
        }

        // Se só encontrou 1 passo (ex: card sem resumo ou gaveta cortada), retorna stepCount = 1
        if let onlyStep = steps.first {
            return (0.0, onlyStep.km, onlyStep.km, 0, onlyStep.min, onlyStep.min, 1)
        }

        return (0, 0, 0, 0, 0, 0, 0)
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

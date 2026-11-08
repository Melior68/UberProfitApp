import Foundation

/// Dados brutos recebidos via UDP da extensão `ScreenReaderExtension`
public struct RideOfferPayload: Codable, Sendable, Equatable {
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

    enum CodingKeys: String, CodingKey {
        case appSource, fareBRL, pickupDistanceKm, tripDistanceKm, totalDistanceKm
        case pickupMinutes, tripMinutes, totalMinutes, rawRecognizedText, timestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.appSource = try container.decodeIfPresent(String.self, forKey: .appSource) ?? "UBER"
        self.fareBRL = try container.decode(Double.self, forKey: .fareBRL)
        self.pickupDistanceKm = try container.decode(Double.self, forKey: .pickupDistanceKm)
        self.tripDistanceKm = try container.decode(Double.self, forKey: .tripDistanceKm)
        self.totalDistanceKm = try container.decode(Double.self, forKey: .totalDistanceKm)
        self.pickupMinutes = try container.decode(Int.self, forKey: .pickupMinutes)
        self.tripMinutes = try container.decode(Int.self, forKey: .tripMinutes)
        self.totalMinutes = try container.decode(Int.self, forKey: .totalMinutes)
        self.rawRecognizedText = try container.decode(String.self, forKey: .rawRecognizedText)
        self.timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
    }

    public init(
        appSource: String = "UBER",
        fareBRL: Double,
        pickupDistanceKm: Double,
        tripDistanceKm: Double,
        totalDistanceKm: Double,
        pickupMinutes: Int,
        tripMinutes: Int,
        totalMinutes: Int,
        rawRecognizedText: String,
        timestamp: TimeInterval
    ) {
        self.appSource = appSource
        self.fareBRL = fareBRL
        self.pickupDistanceKm = pickupDistanceKm
        self.tripDistanceKm = tripDistanceKm
        self.totalDistanceKm = totalDistanceKm
        self.pickupMinutes = pickupMinutes
        self.tripMinutes = tripMinutes
        self.totalMinutes = totalMinutes
        self.rawRecognizedText = rawRecognizedText
        self.timestamp = timestamp
    }
}

/// Modo de exibição visual escolhido pelo motorista
public enum VisualAlertMode: String, CaseIterable, Sendable {
    case notificationOnly = "NOTIFICATION"
    case pipOnly = "PIP"
    case both = "BOTH"

    public var title: String {
        switch self {
        case .notificationOnly: return "Só Notificação"
        case .pipOnly: return "Só Janela PiP"
        case .both: return "Notificação + PiP"
        }
    }
}

/// Estilo de fala do alerta de voz
public enum VoiceSpeechStyle: String, CaseIterable, Sendable {
    case full = "FULL"
    case compact = "COMPACT"
    case approvedAndWarningOnly = "GOOD_ONLY"

    public var title: String {
        switch self {
        case .full: return "Completa (Todas)"
        case .compact: return "Curta e Rápida"
        case .approvedAndWarningOnly: return "Falar Só Boas/Atenção"
        }
    }

    public var description: String {
        switch self {
        case .full:
            return "Fala R$/km, R$/hora e Lucro Líquido em todas as corridas."
        case .compact:
            return "Fala apenas R$/km e Lucro Líquido de forma bem rápida."
        case .approvedAndWarningOnly:
            return "Fala voz completa nas Boas/Atenção; nas Recusadas dá apenas 1 bipe discreto."
        }
    }
}

/// Qual valor destacar em fonte gigante no Card / Banner
public enum PrimaryMetricDisplay: String, CaseIterable, Sendable {
    case gross = "GROSS"
    case net = "NET"

    public var title: String {
        switch self {
        case .gross: return "Valor Bruto (Uber/99)"
        case .net: return "Valor Líquido (Livre)"
        }
    }
}

/// Classificação de decisão da corrida
public enum RideVerdict: String, Sendable {
    case approved = "ACEITAR"
    case warning = "ATENÇÃO"
    case rejected = "RECUSAR"

    public var emoji: String {
        switch self {
        case .approved: return "🟢"
        case .warning: return "🟡"
        case .rejected: return "🔴"
        }
    }
}

/// Resultado completo do cálculo de lucratividade
public struct RideAnalysis: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let offer: RideOfferPayload
    public let grossPerKm: Double
    public let grossPerHour: Double
    public let fuelCostBRL: Double
    public let netProfitBRL: Double
    public let netPerKm: Double
    public let netPerHour: Double
    public let verdict: RideVerdict
}

/// Configurações do motorista persistidas em `UserDefaults`
public struct DriverSettings: Sendable, Equatable {
    public var targetBRLPerKm: Double
    public var targetBRLPerHour: Double
    public var carConsumptionKmPerLiter: Double
    public var fuelPriceBRLPerLiter: Double
    public var voiceAlertsEnabled: Bool
    public var evaluateUsingNetProfit: Bool
    public var voiceSpeechStyle: VoiceSpeechStyle
    public var voiceSpeechRate: Double
    public var primaryMetricDisplay: PrimaryMetricDisplay

    public init(
        targetBRLPerKm: Double = 2.00,
        targetBRLPerHour: Double = 40.00,
        carConsumptionKmPerLiter: Double = 10.0,
        fuelPriceBRLPerLiter: Double = 6.35,
        voiceAlertsEnabled: Bool = true,
        evaluateUsingNetProfit: Bool = false,
        voiceSpeechStyle: VoiceSpeechStyle = .full,
        voiceSpeechRate: Double = 0.54,
        primaryMetricDisplay: PrimaryMetricDisplay = .gross
    ) {
        self.targetBRLPerKm = targetBRLPerKm
        self.targetBRLPerHour = targetBRLPerHour
        self.carConsumptionKmPerLiter = carConsumptionKmPerLiter
        self.fuelPriceBRLPerLiter = fuelPriceBRLPerLiter
        self.voiceAlertsEnabled = voiceAlertsEnabled
        self.evaluateUsingNetProfit = evaluateUsingNetProfit
        self.voiceSpeechStyle = voiceSpeechStyle
        self.voiceSpeechRate = voiceSpeechRate
        self.primaryMetricDisplay = primaryMetricDisplay
    }
}

/// Motor de cálculo de rentabilidade da corrida
public struct ProfitCalculator: Sendable {

    public static func evaluate(offer: RideOfferPayload, settings: DriverSettings) -> RideAnalysis {
        let safeDistanceKm = max(offer.totalDistanceKm, 0.1)
        let safeMinutes = max(Double(offer.totalMinutes), 1.0)
        let safeConsumption = max(settings.carConsumptionKmPerLiter, 1.0)

        let grossPerKm = offer.fareBRL / safeDistanceKm
        let grossPerHour = (offer.fareBRL / safeMinutes) * 60.0

        let litersUsed = safeDistanceKm / safeConsumption
        let fuelCostBRL = litersUsed * settings.fuelPriceBRLPerLiter
        let netProfitBRL = offer.fareBRL - fuelCostBRL

        let netPerKm = netProfitBRL / safeDistanceKm
        let netPerHour = (netProfitBRL / safeMinutes) * 60.0

        let referencePerKm = settings.evaluateUsingNetProfit ? netPerKm : grossPerKm
        let referencePerHour = settings.evaluateUsingNetProfit ? netPerHour : grossPerHour

        let meetsKmTarget = referencePerKm >= settings.targetBRLPerKm
        let meetsHourTarget = referencePerHour >= settings.targetBRLPerHour

        let verdict: RideVerdict
        if meetsKmTarget && meetsHourTarget {
            verdict = .approved
        } else if meetsKmTarget || meetsHourTarget || (referencePerKm >= settings.targetBRLPerKm * 0.85 && referencePerHour >= settings.targetBRLPerHour * 0.85) {
            verdict = .warning
        } else {
            verdict = .rejected
        }

        return RideAnalysis(
            offer: offer,
            grossPerKm: grossPerKm,
            grossPerHour: grossPerHour,
            fuelCostBRL: fuelCostBRL,
            netProfitBRL: netProfitBRL,
            netPerKm: netPerKm,
            netPerHour: netPerHour,
            verdict: verdict
        )
    }
}

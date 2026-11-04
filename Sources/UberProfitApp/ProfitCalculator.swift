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

    public init(
        targetBRLPerKm: Double = 2.00,
        targetBRLPerHour: Double = 40.00,
        carConsumptionKmPerLiter: Double = 10.0,
        fuelPriceBRLPerLiter: Double = 6.35,
        voiceAlertsEnabled: Bool = true,
        evaluateUsingNetProfit: Bool = false
    ) {
        self.targetBRLPerKm = targetBRLPerKm
        self.targetBRLPerHour = targetBRLPerHour
        self.carConsumptionKmPerLiter = carConsumptionKmPerLiter
        self.fuelPriceBRLPerLiter = fuelPriceBRLPerLiter
        self.voiceAlertsEnabled = voiceAlertsEnabled
        self.evaluateUsingNetProfit = evaluateUsingNetProfit
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

import Foundation
import SwiftUI
import AVKit

public enum AppSectionTab: String, CaseIterable, Sendable {
    case operation = "Painel"
    case earnings = "Ganhos"
    case goals = "Metas"
    case customize = "Alertas"
    case history = "Histórico"

    public var icon: String {
        switch self {
        case .operation: return "bolt.car.fill"
        case .earnings: return "dollarsign.circle.fill"
        case .goals: return "slider.horizontal.3"
        case .customize: return "paintbrush.pointed.fill"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

@MainActor
public final class ContentViewModel: ObservableObject {
    // Services
    public let keepAlive = BackgroundKeepAlive()
    public let udpListener = UDPListenerManager()
    public let voiceManager = VoiceAlertManager()
    public let pipManager = PiPOverlayManager()
    public let notificationManager = NotificationAlertManager()
    @Published public var config = AppConfiguration()
    public let persistence = RidePersistenceService()

    // State
    @Published public var selectedTab: AppSectionTab = .operation
    @Published public var latestAnalysis: RideAnalysis?
    @Published public var lastSeenAnalysis: RideAnalysis?
    @Published public var history: [RideAnalysis] = []
    @Published public var acceptedRides: [RideAnalysis] = []
    @Published public var selectedItemForOCRDebug: RideAnalysis?
    @Published public var showAddManualRideSheet: Bool = false

    public init() {
        self.history = persistence.loadHistory()
        self.acceptedRides = persistence.loadAcceptedRides()
    }

    public func startBackgroundServices() {
        keepAlive.start()
        udpListener.startListening()
        
        udpListener.onOfferReceived = { [weak self] offer in
            Task { @MainActor in
                self?.handleNewOffer(offer)
            }
        }
        
        udpListener.onRideAcceptedDetected = { [weak self] in
            Task { @MainActor in
                guard let self = self, let latest = self.latestAnalysis else { return }
                // Só salva automaticamente se o usuário habilitou essa opção
                if self.config.autoDetectAcceptedRides {
                    self.acceptRide(latest)
                }
            }
        }
        udpListener.onClearCardRequested = { [weak self] in
            Task { @MainActor in
                self?.latestAnalysis = nil
            }
        }
    }

    private func handleNewOffer(_ offer: RideOfferPayload) {
        let analysis = ProfitCalculator.evaluate(offer: offer, settings: currentSettings)
        self.latestAnalysis = analysis
        self.lastSeenAnalysis = analysis
        self.history.insert(analysis, at: 0)
        persistence.saveHistory(Array(history.prefix(100)))

        if config.voiceAlertsEnabled {
            voiceManager.announce(analysis: analysis, settings: currentSettings)
        }
    }

    public var currentSettings: DriverSettings {
        DriverSettings(
            targetBRLPerKm: config.targetBRLPerKm,
            targetBRLPerHour: config.targetBRLPerHour,
            carConsumptionKmPerLiter: config.carConsumptionKmPerLiter,
            fuelPriceBRLPerLiter: config.fuelPriceBRLPerLiter,
            voiceAlertsEnabled: config.voiceAlertsEnabled,
            evaluateUsingNetProfit: config.evaluateUsingNetProfit,
            voiceSpeechStyle: VoiceSpeechStyle(rawValue: config.voiceSpeechStyleRaw) ?? .full,
            voiceSpeechRate: config.voiceSpeechRate,
            primaryMetricDisplay: PrimaryMetricDisplay(rawValue: config.primaryMetricDisplayRaw) ?? .gross
        )
    }

    public func acceptRide(_ ride: RideAnalysis) {
        if !acceptedRides.contains(where: { $0.id == ride.id }) {
            acceptedRides.append(ride)
            persistence.saveAcceptedRides(acceptedRides)
        }
    }

    public func isRideAlreadyAccepted(_ ride: RideAnalysis) -> Bool {
        acceptedRides.contains(where: { $0.id == ride.id })
    }
}

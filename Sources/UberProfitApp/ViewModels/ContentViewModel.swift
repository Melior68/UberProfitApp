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

    // Modal para adicionar corrida manual na aba Ganhos
    @Published public var showAddManualRideSheet: Bool = false
    @Published public var manualRideApp: String = "UBER"
    @Published public var manualRideFareText: String = ""
    @Published public var manualRideKmText: String = ""
    @Published public var manualRideMinText: String = ""

    public init() {
        self.history = persistence.loadHistory()
        self.acceptedRides = persistence.loadAcceptedRides()
        self.lastSeenAnalysis = self.history.first
    }

    public var currentSettings: DriverSettings {
        DriverSettings(
            targetBRLPerKm: config.targetBRLPerKm,
            targetBRLPerHour: config.targetBRLPerHour,
            minFareBRL: config.minFareBRL,
            maxPickupDistanceKm: config.maxPickupDistanceKm,
            minFareBRL: config.minFareBRL,
            maxPickupDistanceKm: config.maxPickupDistanceKm,
            carConsumptionKmPerLiter: config.carConsumptionKmPerLiter,
            fuelPriceBRLPerLiter: config.fuelPriceBRLPerLiter,
            voiceAlertsEnabled: config.voiceAlertsEnabled,
            evaluateUsingNetProfit: config.evaluateUsingNetProfit,
            voiceSpeechStyle: config.voiceSpeechStyle,
            voiceSpeechRate: config.voiceSpeechRate,
            primaryMetricDisplay: config.primaryMetricDisplay
        )
    }

    public func startBackgroundServices() {
        keepAlive.start()
        notificationManager.requestAuthorizationIfNeeded()
        pipManager.setAutoStartEnabled(config.visualAlertMode != .notificationOnly)

        voiceManager.onSpeechFinished = { [weak self] in
            Task { @MainActor in
                self?.keepAlive.ensureEnginePlaying()
            }
        }

        notificationManager.onAcceptRideFromNotification = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                if let candidate = self.latestAnalysis ?? self.lastSeenAnalysis {
                    self.acceptRide(candidate)
                }
            }
        }

        udpListener.onOfferReceived = { [weak self] offer in
            Task { @MainActor in
                self?.processIncomingOffer(offer)
            }
        }

        udpListener.onClearCardRequested = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                self.latestAnalysis = nil
                self.pipManager.updateCard(with: nil, displayMode: self.config.primaryMetricDisplay)
            }
        }

        udpListener.onRideAcceptedDetected = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                if self.config.autoDetectAcceptedRides, let candidate = self.latestAnalysis ?? self.lastSeenAnalysis {
                    self.acceptRide(candidate)
                }
            }
        }

        udpListener.startListening()
    }

    public func processIncomingOffer(_ offer: RideOfferPayload) {
        let settings = currentSettings
        let analysis = ProfitCalculator.evaluate(offer: offer, settings: settings)
        self.latestAnalysis = analysis
        self.lastSeenAnalysis = analysis
        self.history.insert(analysis, at: 0)
        self.persistence.saveHistory(Array(self.history.prefix(100)))

        self.pipManager.updateCard(with: analysis, displayMode: self.config.primaryMetricDisplay)

        if self.config.visualAlertMode == .notificationOnly || self.config.visualAlertMode == .both {
            self.notificationManager.sendRideBanner(analysis: analysis, displayMode: self.config.primaryMetricDisplay)
        }

        if self.config.voiceAlertsEnabled {
            self.voiceManager.announce(analysis: analysis, settings: settings)
        }
    }

    public func acceptRide(_ ride: RideAnalysis) {
        if !acceptedRides.contains(where: { $0.id == ride.id }) {
            acceptedRides.append(ride)
            persistence.saveAcceptedRides(acceptedRides)
        }
    }

    public func removeAcceptedRide(_ ride: RideAnalysis) {
        acceptedRides.removeAll(where: { $0.id == ride.id })
        persistence.saveAcceptedRides(acceptedRides)
    }

    public func clearTurn() {
        acceptedRides.removeAll()
        config.extraDailyExpenseBRL = 0.0
        persistence.saveAcceptedRides(acceptedRides)
    }

    public func clearHistory() {
        history.removeAll()
        persistence.saveHistory(history)
    }

    public func isRideAlreadyAccepted(_ ride: RideAnalysis) -> Bool {
        acceptedRides.contains(where: { $0.id == ride.id })
    }

    public func saveManualRide() {
        let fare = Double(manualRideFareText.replacingOccurrences(of: ",", with: ".")) ?? 0.0
        let km = Double(manualRideKmText.replacingOccurrences(of: ",", with: ".")) ?? 0.0
        let mins = Int(manualRideMinText) ?? 10

        guard fare > 0, km > 0 else { return }

        let offer = RideOfferPayload(
            appSource: manualRideApp,
            fareBRL: fare,
            pickupDistanceKm: 0.0,
            tripDistanceKm: km,
            totalDistanceKm: km,
            pickupMinutes: 0,
            tripMinutes: max(mins, 1),
            totalMinutes: max(mins, 1),
            rawRecognizedText: "Corrida lançada manualmente pelo motorista.",
            timestamp: Date().timeIntervalSince1970
        )
        let analysis = ProfitCalculator.evaluate(offer: offer, settings: currentSettings)
        acceptRide(analysis)

        manualRideFareText = ""
        manualRideKmText = ""
        manualRideMinText = ""
        showAddManualRideSheet = false
    }

    public func simulateRideOffer(appSource: String, fare: Double, pickupKm: Double, tripKm: Double, pickupMin: Int, tripMin: Int, rawText: String) {
        let mock = RideOfferPayload(
            appSource: appSource,
            fareBRL: fare,
            pickupDistanceKm: pickupKm,
            tripDistanceKm: tripKm,
            totalDistanceKm: pickupKm + tripKm,
            pickupMinutes: pickupMin,
            tripMinutes: tripMin,
            totalMinutes: pickupMin + tripMin,
            rawRecognizedText: rawText,
            timestamp: Date().timeIntervalSince1970
        )
        processIncomingOffer(mock)
    }

    // Formatadores
    public func formatBRL(_ value: Double) -> String {
        String(format: "R$ %.2f", value).replacingOccurrences(of: ".", with: ",")
    }

    public func formatDuration(minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 {
            return String(format: "%dh %02dmin", h, m)
        } else {
            return String(format: "%d min", m)
        }
    }

    public func formatTime(_ timestamp: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    public func color(for verdict: RideVerdict) -> Color {
        switch verdict {
        case .approved: return .green
        case .warning: return .orange
        case .rejected: return .red
        }
    }
}

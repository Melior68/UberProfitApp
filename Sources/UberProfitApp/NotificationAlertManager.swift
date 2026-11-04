import Foundation
import UserNotifications

/// Dispara notificações locais imediatas (Banner no topo da tela do iPhone) com som e resumo completo
/// da corrida assim que o card da Uber ou 99 aparece, respeitando a preferência de métrica (Bruto vs Líquido).
@MainActor
public final class NotificationAlertManager: NSObject, ObservableObject, @preconcurrency UNUserNotificationCenterDelegate {
    @Published public private(set) var isAuthorized: Bool = false

    public override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        requestAuthorizationIfNeeded()
    }

    public func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.isAuthorized = granted
            }
        }
    }

    public func sendRideBanner(analysis: RideAnalysis, displayMode: PrimaryMetricDisplay = .gross) {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()

        let content = UNMutableNotificationContent()
        let shownKm = (displayMode == .net) ? analysis.netPerKm : analysis.grossPerKm
        let shownHour = (displayMode == .net) ? analysis.netPerHour : analysis.grossPerHour

        let kmStr = String(format: "R$ %.2f/km", shownKm).replacingOccurrences(of: ".", with: ",")
        let hourStr = String(format: "R$ %.0f/h", shownHour)
        let netStr = String(format: "R$ %.2f", analysis.netProfitBRL).replacingOccurrences(of: ".", with: ",")
        let fareStr = String(format: "R$ %.2f", analysis.offer.fareBRL).replacingOccurrences(of: ".", with: ",")
        let distStr = String(format: "%.1f km", analysis.offer.totalDistanceKm).replacingOccurrences(of: ".", with: ",")
        let fuelStr = String(format: "-R$ %.2f", analysis.fuelCostBRL).replacingOccurrences(of: ".", with: ",")

        content.title = "\(analysis.verdict.emoji) \(analysis.verdict.rawValue) (\(analysis.offer.appSource)) • \(kmStr) • \(hourStr)"
        content.subtitle = "Lucro Livre: \(netStr) (Gasolina: \(fuelStr))"
        content.body = "Tarifa: \(fareStr)  •  Total: \(distStr) (\(analysis.offer.totalMinutes) min)"
        content.sound = .default
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }

        let request = UNNotificationRequest(
            identifier: "UBER_PROFIT_LIVE_OFFER",
            content: content,
            trigger: nil
        )

        center.add(request, withCompletionHandler: nil)
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

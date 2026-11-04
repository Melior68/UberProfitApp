import Foundation
import UserNotifications

/// Dispara notificações locais imediatas (Banner no topo da tela do iPhone) com som e resumo completo
/// da corrida assim que o card da Uber ou 99 aparece, funcionando mesmo com o PiP desligado.
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

    public func sendRideBanner(analysis: RideAnalysis) {
        let center = UNUserNotificationCenter.current()
        // Remove banner anterior para não empilhar notificações antigas
        center.removeAllDeliveredNotifications()

        let content = UNMutableNotificationContent()
        let kmStr = String(format: "R$ %.2f/km", analysis.grossPerKm).replacingOccurrences(of: ".", with: ",")
        let hourStr = String(format: "R$ %.0f/h", analysis.grossPerHour)
        let netStr = String(format: "R$ %.2f", analysis.netProfitBRL).replacingOccurrences(of: ".", with: ",")
        let fareStr = String(format: "R$ %.2f", analysis.offer.fareBRL).replacingOccurrences(of: ".", with: ",")
        let distStr = String(format: "%.1f km", analysis.offer.totalDistanceKm).replacingOccurrences(of: ".", with: ",")
        let fuelStr = String(format: "-R$ %.2f", analysis.fuelCostBRL).replacingOccurrences(of: ".", with: ",")

        content.title = "\(analysis.verdict.emoji) \(analysis.verdict.rawValue) (\(analysis.offer.appSource)) • \(kmStr) • \(hourStr)"
        content.subtitle = "Lucro Líquido: \(netStr) (Comb: \(fuelStr))"
        content.body = "Tarifa: \(fareStr)  |  Total: \(distStr) em \(analysis.offer.totalMinutes) min"
        content.sound = .default
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }

        let request = UNNotificationRequest(
            identifier: "UBER_PROFIT_LIVE_OFFER",
            content: content,
            trigger: nil // Entrega imediata (milissegundos)
        )

        center.add(request, withCompletionHandler: nil)
    }

    // Garante que o Banner apareça no topo mesmo se o próprio UberProfit estiver aberto na tela
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

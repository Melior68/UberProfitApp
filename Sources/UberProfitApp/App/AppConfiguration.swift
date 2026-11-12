import Foundation
import SwiftUI

public final class AppConfiguration: ObservableObject {
    @AppStorage("targetBRLPerKm") public var targetBRLPerKm: Double = 2.00
    @AppStorage("targetBRLPerHour") public var targetBRLPerHour: Double = 40.00
    @AppStorage("carConsumptionKmPerLiter") public var carConsumptionKmPerLiter: Double = 10.0
    @AppStorage("fuelPriceBRLPerLiter") public var fuelPriceBRLPerLiter: Double = 6.35
    @AppStorage("evaluateUsingNetProfit") public var evaluateUsingNetProfit: Bool = false

    @AppStorage("dailyNetGoalBRL") public var dailyNetGoalBRL: Double = 250.00
    @AppStorage("extraDailyExpenseBRL") public var extraDailyExpenseBRL: Double = 0.00
    @AppStorage("autoDetectAcceptedRides") public var autoDetectAcceptedRides: Bool = true

    @AppStorage("voiceAlertsEnabled") public var voiceAlertsEnabled: Bool = true
    @AppStorage("voiceSpeechStyleRaw") public var voiceSpeechStyleRaw: String = VoiceSpeechStyle.full.rawValue
    @AppStorage("voiceSpeechRate") public var voiceSpeechRate: Double = 0.54
    @AppStorage("visualAlertModeRaw") public var visualAlertModeRaw: String = VisualAlertMode.notificationOnly.rawValue
    @AppStorage("primaryMetricDisplayRaw") public var primaryMetricDisplayRaw: String = PrimaryMetricDisplay.gross.rawValue
    @AppStorage("showQuickGuide") public var showQuickGuide: Bool = true

    public var visualAlertMode: VisualAlertMode {
        get { VisualAlertMode(rawValue: visualAlertModeRaw) ?? .notificationOnly }
        set { visualAlertModeRaw = newValue.rawValue }
    }

    public var voiceSpeechStyle: VoiceSpeechStyle {
        get { VoiceSpeechStyle(rawValue: voiceSpeechStyleRaw) ?? .full }
        set { voiceSpeechStyleRaw = newValue.rawValue }
    }

    public var primaryMetricDisplay: PrimaryMetricDisplay {
        get { PrimaryMetricDisplay(rawValue: primaryMetricDisplayRaw) ?? .gross }
        set { primaryMetricDisplayRaw = newValue.rawValue }
    }

    public var fuelCostPerKm: Double {
        fuelPriceBRLPerLiter / max(carConsumptionKmPerLiter, 1.0)
    }

    public init() {}
}

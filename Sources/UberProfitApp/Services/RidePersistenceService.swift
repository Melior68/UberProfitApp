import Foundation

public final class RidePersistenceService {
    private let savedAcceptedKey = "UberProfit_AcceptedRides_V7"
    private let savedHistoryKey = "UberProfit_OfferHistory_V7"

    public init() {}

    public func loadAcceptedRides() -> [RideAnalysis] {
        guard let data = UserDefaults.standard.data(forKey: savedAcceptedKey),
              let decoded = try? JSONDecoder().decode([RideAnalysis].self, from: data) else { return [] }
        return decoded
    }

    public func saveAcceptedRides(_ rides: [RideAnalysis]) {
        if let encoded = try? JSONEncoder().encode(rides) {
            UserDefaults.standard.set(encoded, forKey: savedAcceptedKey)
        }
    }

    public func loadHistory() -> [RideAnalysis] {
        guard let data = UserDefaults.standard.data(forKey: savedHistoryKey),
              let decoded = try? JSONDecoder().decode([RideAnalysis].self, from: data) else { return [] }
        return decoded
    }

    public func saveHistory(_ history: [RideAnalysis]) {
        if let encoded = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(encoded, forKey: savedHistoryKey)
        }
    }
}

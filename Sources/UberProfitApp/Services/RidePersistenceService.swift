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

    public struct ArchivedTurn: Codable, Identifiable, Sendable {
        public let id: UUID
        public let date: Date
        public let rides: [RideAnalysis]
        public let totalNetProfit: Double

        public init(id: UUID = UUID(), date: Date = Date(), rides: [RideAnalysis], totalNetProfit: Double) {
            self.id = id
            self.date = date
            self.rides = rides
            self.totalNetProfit = totalNetProfit
        }
    }

    public func archiveTurn(_ rides: [RideAnalysis]) {
        guard !rides.isEmpty else { return }
        
        let totalNet = rides.reduce(0) { $0 + $1.netProfitBRL }
        let newTurn = ArchivedTurn(id: UUID(), date: Date(), rides: rides, totalNetProfit: totalNet)
        
        var history = loadArchivedTurns()
        history.insert(newTurn, at: 0)
        
        if let encoded = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(encoded, forKey: "UberProfit_TurnHistory_V1")
        }
    }

    public func loadArchivedTurns() -> [ArchivedTurn] {
        guard let data = UserDefaults.standard.data(forKey: "UberProfit_TurnHistory_V1"),
              let decoded = try? JSONDecoder().decode([ArchivedTurn].self, from: data) else { return [] }
        return decoded
    }
}

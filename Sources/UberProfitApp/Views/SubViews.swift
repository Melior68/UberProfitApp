import SwiftUI
import ReplayKit
import AVKit

// MARK: - Helpers
public func formatBRL(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencySymbol = "R$"
    formatter.minimumFractionDigits = 2
    return formatter.string(from: NSNumber(value: value)) ?? "R$ \(value)"
}

public func formatDuration(minutes: Int) -> String {
    let hours = minutes / 60
    let mins = minutes % 60
    if hours > 0 {
        return "\(hours)h \(mins)min"
    }
    return "\(mins) min"
}

// MARK: - SubViews

public struct CategoryTabBar: View {
    @ObservedObject var viewModel: ContentViewModel
    
    public var body: some View {
        HStack(spacing: 4) {
            ForEach(AppSectionTab.allCases, id: \.rawValue) { tab in
                let isSelected = (viewModel.selectedTab == tab)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        viewModel.selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: tab.icon)
                                .font(.subheadline.bold())
                            if tab == .earnings && !viewModel.acceptedRides.isEmpty {
                                Text("\(viewModel.acceptedRides.count)")
                                    .font(.system(size: 9, weight: .black))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.green)
                                    .clipShape(Capsule())
                                    .offset(x: 10, y: -6)
                            }
                        }
                        Text(tab.rawValue)
                            .font(.caption2.bold())
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(isSelected ? Color.blue.opacity(0.18) : Color.clear)
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
    }
}

public struct OperationTabView: View {
    @ObservedObject var viewModel: ContentViewModel
    
    public var body: some View {
        VStack(spacing: 16) {
            if viewModel.config.showQuickGuide {
                quickHowItWorksCard
            }

            pipPreviewSection

            if let candidate = viewModel.latestAnalysis ?? viewModel.lastSeenAnalysis {
                quickAcceptLastRideBar(for: candidate)
            }
            shiftControlsSection
            shiftStatsSection
        }
    }
    
    private var pipPreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Monitoramento ao Vivo", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(viewModel.udpListener.broadcastActive ? Color.green : (viewModel.udpListener.isListening ? Color.orange : Color.red))
                    .frame(width: 10, height: 10)
            }
            
            ZStack {
                PiPLayerContainerView(displayLayer: viewModel.pipManager.displayLayer)
                    .frame(height: 155)
            }
            .frame(height: 155)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(viewModel.udpListener.broadcastActive ? Color.green.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 2))
        }
    }
    
    private func quickAcceptLastRideBar(for item: RideAnalysis) -> some View {
        let alreadyAccepted = viewModel.isRideAlreadyAccepted(item)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Última: [\(item.offer.appSource)] \(formatBRL(item.offer.fareBRL))")
                    .font(.caption.bold())
            }
            Spacer()
            Button {
                viewModel.acceptRide(item)
            } label: {
                Text(alreadyAccepted ? "Já nos Ganhos" : "Aceitei")
            }
            .disabled(alreadyAccepted)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
    
    private var shiftControlsSection: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(viewModel.udpListener.broadcastActive ? Color.red : Color.blue)
                BroadcastPickerRepresentable()
                    .opacity(0.01)
                Text(viewModel.udpListener.broadcastActive ? "Parar Leitor" : "Iniciar Leitor")
                    .foregroundStyle(.white).bold()
            }
            .frame(height: 56)
            
            Button {
                viewModel.pipManager.togglePiP()
            } label: {
                Text(viewModel.pipManager.isPiPActive ? "Fechar PiP" : "Abrir PiP")
            }
            .buttonStyle(.bordered)
        }
    }
    
    private var shiftStatsSection: some View {
        Text("Resumo do Turno Ativo")
            .font(.caption)
            .padding()
    }
    
    private var quickHowItWorksCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Como Funciona", systemImage: "sparkles")
                    .font(.subheadline.bold())
                    .foregroundStyle(.blue)
                Spacer()
                Button {
                    withAnimation {
                        viewModel.config.showQuickGuide = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(Color.blue.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

public struct EarningsTabView: View {
    @ObservedObject var viewModel: ContentViewModel
    
    private var totalGrossBRL: Double { viewModel.acceptedRides.reduce(0) { $0 + $1.offer.fareBRL } }
    private var totalFuelCostBRL: Double { viewModel.acceptedRides.reduce(0) { $0 + $1.fuelCostBRL } }
    private var totalNetProfitBRL: Double { viewModel.acceptedRides.reduce(0) { $0 + $1.netProfitBRL } }
    private var totalKm: Double { viewModel.acceptedRides.reduce(0) { $0 + $1.offer.totalDistanceKm } }
    private var totalMinutes: Int { viewModel.acceptedRides.reduce(0) { $0 + $1.offer.totalMinutes } }
    
    private var goalProgress: Double {
        let netProfitAfterExtra = totalNetProfitBRL - viewModel.config.extraDailyExpenseBRL
        return min(max(netProfitAfterExtra / viewModel.config.dailyNetGoalBRL, 0), 1.0)
    }

    public var body: some View {
        VStack(spacing: 16) {
            // ... (Banner de Ganhos)
            VStack(alignment: .leading, spacing: 12) {
                Text("Resumo do Turno")
                    .font(.headline)
                
                HStack(spacing: 10) {
                    earningsMetricBox(icon: "road.lanes", title: "KM Total", mainValue: String(format: "%.1f km", totalKm), subValue: "Pickup + Viagem", color: .blue)
                    earningsMetricBox(icon: "clock.fill", title: "Tempo", mainValue: formatDuration(minutes: totalMinutes), subValue: "Em movimento", color: .purple)
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            
            // Lista de Corridas
            VStack(alignment: .leading, spacing: 8) {
                Text("Histórico de Corridas (\(viewModel.acceptedRides.count))")
                    .font(.headline)
                
                ForEach(viewModel.acceptedRides.reversed()) { ride in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(ride.offer.appSource)
                                .font(.caption.bold())
                                .foregroundStyle(ride.offer.appSource == "UBER" ? .blue : .green)
                            Text("\(ride.offer.totalDistanceKm, specifier: "%.1f") km")
                                .font(.caption2)
                        }
                        Spacer()
                        Text(formatBRL(ride.offer.fareBRL))
                            .bold()
                        Text(ride.verdict.emoji)
                    }
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
    
    @ViewBuilder
    private func earningsMetricBox(icon: String, title: String, mainValue: String, subValue: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption2.bold())
                .foregroundStyle(color)
            Text(mainValue)
                .font(.subheadline.bold())
            Text(subValue)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

public struct GoalsAndVehicleTabView: View {
    @ObservedObject var viewModel: ContentViewModel
    
    public var body: some View {
        Form {
            Section(header: Text("Metas de Rentabilidade")) {
                TextField("Meta R$/km", value: $viewModel.config.targetBRLPerKm, format: .number)
                TextField("Meta R$/hora", value: $viewModel.config.targetBRLPerHour, format: .number)
            }
            Section(header: Text("Veículo")) {
                TextField("Consumo (km/L)", value: $viewModel.config.carConsumptionKmPerLiter, format: .number)
                TextField("Preço Combustível (R$)", value: $viewModel.config.fuelPriceBRLPerLiter, format: .number)
            }
        }
    }
}

public struct CustomizationTabView: View {
    @ObservedObject var viewModel: ContentViewModel
    
    public var body: some View {
        Form {
            Section(header: Text("Alertas de Voz")) {
                Toggle("Ativar Voz", isOn: $viewModel.config.voiceAlertsEnabled)
            }
            Section(header: Text("Exibição")) {
                Toggle("Avaliar por Lucro Líquido", isOn: $viewModel.config.evaluateUsingNetProfit)
            }
        }
    }
}

public struct HistoryTabView: View {
    @ObservedObject var viewModel: ContentViewModel
    
    public var body: some View {
        List(viewModel.history) { ride in
            HStack {
                Text(ride.offer.appSource)
                    .font(.caption.bold())
                    .frame(width: 50)
                Spacer()
                Text(formatBRL(ride.offer.fareBRL))
                    .bold()
                Spacer()
                Text(ride.verdict.emoji)
            }
        }
    }
}

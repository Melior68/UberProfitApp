import SwiftUI

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
        Text("Painel de Operação (Em breve)")
            .padding()
    }
}

public struct EarningsTabView: View {
    @ObservedObject var viewModel: ContentViewModel
    
    private var totalGrossBRL: Double { viewModel.acceptedRides.reduce(0) { $0 + $1.offer.fareBRL } }
    private var totalFuelCostBRL: Double { viewModel.acceptedRides.reduce(0) { $0 + $1.fuelCostBRL } }
    private var totalNetProfitBRL: Double { viewModel.acceptedRides.reduce(0) { $0 + $1.netProfitBRL } }
    
    private var goalProgress: Double {
        let netProfitAfterExtra = totalNetProfitBRL - viewModel.config.extraDailyExpenseBRL
        return min(max(netProfitAfterExtra / viewModel.config.dailyNetGoalBRL, 0), 1.0)
    }

    public var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lucro Líquido Hoje")
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.8))
                        Text(formatBRL(totalNetProfitBRL - viewModel.config.extraDailyExpenseBRL))
                            .font(.system(size: 36, weight: .black))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                }
                
                HStack {
                    VStack(spacing: 2) {
                        Text("Total Bruto")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                        Text(formatBRL(totalGrossBRL))
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    
                    VStack(spacing: 2) {
                        Text("Gasolina")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                        Text("-\(formatBRL(totalFuelCostBRL))")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color(red: 1.0, green: 0.85, blue: 0.4))
                    }
                    .frame(maxWidth: .infinity)
                    
                    VStack(spacing: 2) {
                        Text("Gasto Extra")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                        Text("-\(formatBRL(viewModel.config.extraDailyExpenseBRL))")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color(red: 1.0, green: 0.85, blue: 0.4))
                    }
                    .frame(maxWidth: .infinity)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Meta Diária Livre: \(formatBRL(viewModel.config.dailyNetGoalBRL))")
                            .font(.caption2.bold())
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer()
                        Text("\(Int((goalProgress * 100).rounded()))% concluída")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                    }
                    ProgressView(value: goalProgress)
                        .tint(.white)
                        .background(Color.black.opacity(0.25))
                        .clipShape(Capsule())
                }
            }
            .padding(16)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.05, green: 0.52, blue: 0.25), Color(red: 0.04, green: 0.36, blue: 0.20)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 18))

            // Novo Resumo de Performance
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

public struct GoalsTabView: View {
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

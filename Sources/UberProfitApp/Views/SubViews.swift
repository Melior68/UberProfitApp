import SwiftUI
import ReplayKit
import AVKit

// MARK: - Barra de Abas
public struct CategoryTabBar: View {
    @ObservedObject var viewModel: ContentViewModel

    public init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(AppSectionTab.allCases, id: \.self) { tab in
                let isSelected = viewModel.selectedTab == tab
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        viewModel.selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 15, weight: isSelected ? .bold : .regular))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(isSelected ? Color.blue : Color(.tertiarySystemGroupedBackground))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
    }
}

// MARK: - ABA 1: PAINEL DE OPERAÇÃO
public struct OperationTabView: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject private var config: AppConfiguration

    public init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
        self._config = ObservedObject(wrappedValue: viewModel.config)
    }

    public var body: some View {
        VStack(spacing: 16) {
            if config.showQuickGuide {
                quickHowItWorksCard
            }

            pipPreviewSection

            if let candidate = viewModel.latestAnalysis ?? viewModel.lastSeenAnalysis {
                quickAcceptLastRideBar(for: candidate)
            }

            shiftControlsSection
            shiftStatsSection
            testSimulationSection
        }
    }

    private func quickAcceptLastRideBar(for item: RideAnalysis) -> some View {
        let alreadyAccepted = viewModel.isRideAlreadyAccepted(item)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Última Oferta: [\(item.offer.appSource)] \(viewModel.formatBRL(item.offer.fareBRL))")
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                Text(String(format: "%.1f km • %d min • Lucro %@ ", item.offer.totalDistanceKm, item.offer.totalMinutes, viewModel.formatBRL(item.netProfitBRL)).replacingOccurrences(of: ".", with: ","))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                viewModel.acceptRide(item)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: alreadyAccepted ? "checkmark.seal.fill" : "plus.circle.fill")
                    Text(alreadyAccepted ? "Já nos Ganhos" : "Aceitei Corrida")
                }
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(alreadyAccepted ? Color.green.opacity(0.2) : Color.green)
                .foregroundStyle(alreadyAccepted ? Color.green : Color.white)
                .clipShape(Capsule())
            }
            .disabled(alreadyAccepted)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var quickHowItWorksCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Como Funciona (3 Passos)", systemImage: "sparkles")
                    .font(.subheadline.bold())
                    .foregroundStyle(.blue)
                Spacer()
                Button {
                    withAnimation {
                        config.showQuickGuide = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("1. Toque em \"Iniciar Leitor\" abaixo e escolha UberProfit ScreenReader.", systemImage: "1.circle.fill")
                    .font(.caption)
                Label("2. Abra a Uber ou 99: o app calcula o lucro e avisa por voz/PiP.", systemImage: "2.circle.fill")
                    .font(.caption)
                Label("3. Aceitou a corrida? Ela vai para a aba \"Ganhos\" (automático ou 1 toque)!", systemImage: "3.circle.fill")
                    .font(.caption)
            }
            .foregroundStyle(.primary.opacity(0.9))
        }
        .padding(14)
        .background(Color.blue.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
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
                Text(viewModel.udpListener.broadcastActive ? "Leitor Capturando" : (viewModel.udpListener.isListening ? "Pronto p/ Iniciar" : "UDP Offline"))
                    .font(.caption.bold())
                    .foregroundStyle(viewModel.udpListener.broadcastActive ? .green : .secondary)
            }

            ZStack {
                PiPLayerContainerView(displayLayer: viewModel.pipManager.displayLayer)
                    .frame(height: 155)
                    .opacity(config.visualAlertMode == .notificationOnly ? 0.01 : 1.0)

                if config.visualAlertMode == .notificationOnly {
                    nativePreviewCard
                }
            }
            .frame(height: 155)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(viewModel.udpListener.broadcastActive ? Color.green.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 2)
            )
        }
    }

    private var nativePreviewCard: some View {
        let analysis = viewModel.latestAnalysis
        let bgColor: Color = {
            guard let analysis else { return Color(red: 0.08, green: 0.10, blue: 0.14) }
            switch analysis.verdict {
            case .approved: return Color(red: 0.06, green: 0.56, blue: 0.24)
            case .warning: return Color(red: 0.78, green: 0.52, blue: 0.02)
            case .rejected: return Color(red: 0.72, green: 0.10, blue: 0.14)
            }
        }()

        return ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(bgColor)

            if let analysis {
                let shownKm = (config.primaryMetricDisplay == .net) ? analysis.netPerKm : analysis.grossPerKm
                let shownHour = (config.primaryMetricDisplay == .net) ? analysis.netPerHour : analysis.grossPerHour

                VStack(spacing: 10) {
                    Text("\(analysis.offer.appSource) • \(analysis.verdict.rawValue) • LUCRO R$ \(String(format: "%.2f", analysis.netProfitBRL).replacingOccurrences(of: ".", with: ","))")
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.28))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    HStack {
                        Text(String(format: "R$ %.2f/km", shownKm).replacingOccurrences(of: ".", with: ","))
                            .font(.system(size: 30, weight: .black))
                            .foregroundStyle(.white)
                        Spacer()
                        Text(String(format: "R$ %.0f/h", shownHour))
                            .font(.system(size: 30, weight: .black))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16)

                    Text(String(format: "Tarifa R$ %.2f • %.1f km total • %d min • Comb. -R$ %.2f", analysis.offer.fareBRL, analysis.offer.totalDistanceKm, analysis.offer.totalMinutes, analysis.fuelCostBRL).replacingOccurrences(of: ".", with: ","))
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.95))
                }
                .padding(12)
            } else {
                VStack(spacing: 6) {
                    Text("MODO SÓ NOTIFICAÇÃO ATIVO")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                    Text("Sem janela flutuante • Alertando por Banner no Topo e Voz")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
            }
        }
        .frame(height: 155)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(viewModel.udpListener.broadcastActive ? Color.green.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 2)
        )
    }

    private var shiftControlsSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(viewModel.udpListener.broadcastActive ? Color.red : Color.blue)
                    HStack(spacing: 8) {
                        Image(systemName: viewModel.udpListener.broadcastActive ? "stop.circle.fill" : "record.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(viewModel.udpListener.broadcastActive ? "Leitor Ativo" : "1. Iniciar Leitor")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                            Text(viewModel.udpListener.broadcastActive ? "Toque p/ parar" : "Toque p/ ligar")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .padding(.horizontal, 8)

                    BroadcastPickerRepresentable()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .blendMode(.destinationOver)
                }
                .frame(height: 56)

                if config.visualAlertMode != .notificationOnly {
                    Button {
                        viewModel.pipManager.togglePiP()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: viewModel.pipManager.isPiPActive ? "pip.exit" : "pip.enter")
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(viewModel.pipManager.isPiPActive ? "PiP Ativo" : "2. Abrir PiP")
                                    .font(.subheadline.bold())
                                Text(viewModel.pipManager.isPiPActive ? "Toque p/ fechar" : "Janela flutuante")
                                    .font(.caption2)
                                    .opacity(0.85)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(viewModel.pipManager.isPiPActive ? Color.orange : Color.green)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                } else {
                    Button {
                        viewModel.selectedTab = .customize
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "bell.badge.fill")
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Só Notificação")
                                    .font(.subheadline.bold())
                                Text("Toque p/ mudar")
                                    .font(.caption2)
                                    .opacity(0.85)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Color.indigo)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
            }

            HStack {
                Label(
                    viewModel.keepAlive.isRunning ? "2º Plano Sempre Ativo" : "Keep-Alive Parado",
                    systemImage: viewModel.keepAlive.isRunning ? "bolt.shield.fill" : "bolt.slash.fill"
                )
                .font(.caption.bold())
                .foregroundStyle(viewModel.keepAlive.isRunning ? .green : .red)

                Spacer()

                Text(config.voiceAlertsEnabled ? "Voz Ligada" : "Mudo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Alerta de Voz", isOn: $config.voiceAlertsEnabled)
                    .labelsHidden()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var shiftStatsSection: some View {
        let approvedCount = viewModel.history.filter { $0.verdict == .approved }.count
        let warningCount = viewModel.history.filter { $0.verdict == .warning }.count
        let rejectedCount = viewModel.history.filter { $0.verdict == .rejected }.count

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Resumo das Ofertas Recebidas Hoje")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    viewModel.selectedTab = .earnings
                } label: {
                    Text("Ver Ganhos (\(viewModel.acceptedRides.count) aceitas) →")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }
            }

            HStack(spacing: 10) {
                statBadge(title: "Boas", value: "\(approvedCount)", color: .green)
                statBadge(title: "Atenção", value: "\(warningCount)", color: .orange)
                statBadge(title: "Recusadas", value: "\(rejectedCount)", color: .red)
                statBadge(title: "Aceitas", value: "\(viewModel.acceptedRides.count)", color: .blue)
            }
        }
    }

    private func statBadge(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.bold())
                .foregroundStyle(color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var testSimulationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Testar Funcionamento Agora")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    viewModel.simulateRideOffer(
                        appSource: "UBER",
                        fare: 22.80,
                        pickupKm: 0.8,
                        tripKm: 7.2,
                        pickupMin: 3,
                        tripMin: 15,
                        rawText: "UberX Exclusivo\nR$ 22,80\n18 min • 8.0 km • Est. de R$2,85/km\n3 min (0.8 km)\n15 minutos (7.2 km)\nAceitar"
                    )
                } label: {
                    Label("Simular Corrida Boa", systemImage: "checkmark.circle.fill")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button {
                    viewModel.simulateRideOffer(
                        appSource: "99",
                        fare: 10.32,
                        pickupKm: 1.4,
                        tripKm: 6.6,
                        pickupMin: 5,
                        tripMin: 18,
                        rawText: "99Pop\nR$ 10,32\n5 min (1.4 km)\n18 min (6.6 km)\nAceitar"
                    )
                } label: {
                    Label("Simular Corrida Ruim", systemImage: "xmark.circle.fill")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - ABA 2: GANHOS DO TURNO (CORRIDAS ACEITAS)
public struct EarningsTabView: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject private var config: AppConfiguration

    public init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
        self._config = ObservedObject(wrappedValue: viewModel.config)
    }

    public var body: some View {
        let totalGrossBRL = viewModel.acceptedRides.map { $0.offer.fareBRL }.reduce(0, +)
        let totalPickupKm = viewModel.acceptedRides.map { $0.offer.pickupDistanceKm }.reduce(0, +)
        let totalTripKm = viewModel.acceptedRides.map { $0.offer.tripDistanceKm }.reduce(0, +)
        let totalKm = viewModel.acceptedRides.map { $0.offer.totalDistanceKm }.reduce(0, +)
        let totalMinutes = viewModel.acceptedRides.map { $0.offer.totalMinutes }.reduce(0, +)
        let totalLiters = totalKm / max(config.carConsumptionKmPerLiter, 1.0)
        let totalFuelCostBRL = totalLiters * config.fuelPriceBRLPerLiter
        let totalNetProfitBRL = totalGrossBRL - totalFuelCostBRL - config.extraDailyExpenseBRL

        let avgGrossPerKm = totalKm > 0 ? (totalGrossBRL / totalKm) : 0.0
        let avgNetPerKm = totalKm > 0 ? (totalNetProfitBRL / totalKm) : 0.0
        let avgGrossPerHour = totalMinutes > 0 ? ((totalGrossBRL / Double(totalMinutes)) * 60.0) : 0.0
        let avgNetPerHour = totalMinutes > 0 ? ((totalNetProfitBRL / Double(totalMinutes)) * 60.0) : 0.0

        let uberCount = viewModel.acceptedRides.filter { $0.offer.appSource == "UBER" }.count
        let ninenineCount = viewModel.acceptedRides.filter { $0.offer.appSource == "99" }.count
        let goalProgress = config.dailyNetGoalBRL > 0 ? min(max(totalNetProfitBRL / config.dailyNetGoalBRL, 0.0), 1.0) : 0.0

        return VStack(alignment: .leading, spacing: 16) {
            // 1. Card Principal: Lucro Livre no Bolso + Faturamento vs Gastos
            VStack(spacing: 14) {
                HStack {
                    Label("GANHOS DO TURNO", systemImage: "banknote.fill")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Text("\(viewModel.acceptedRides.count) Corridas Aceitas")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.2))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }

                VStack(spacing: 4) {
                    Text("LUCRO LIVRE NO BOLSO")
                        .font(.caption2.bold())
                        .foregroundStyle(.white.opacity(0.85))
                    Text(viewModel.formatBRL(totalNetProfitBRL))
                        .font(.system(size: 36, weight: .black))
                        .foregroundStyle(.white)
                }

                Divider()
                    .background(Color.white.opacity(0.3))

                HStack {
                    VStack(spacing: 2) {
                        Text("Ganho Bruto")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                        Text(viewModel.formatBRL(totalGrossBRL))
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 2) {
                        Text("Gasolina (\(String(format: "%.1f L", totalLiters).replacingOccurrences(of: ".", with: ",")))")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                        Text("-\(viewModel.formatBRL(totalFuelCostBRL))")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color(red: 1.0, green: 0.85, blue: 0.4))
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 2) {
                        Text("Gasto Extra")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                        Text("-\(viewModel.formatBRL(config.extraDailyExpenseBRL))")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color(red: 1.0, green: 0.85, blue: 0.4))
                    }
                    .frame(maxWidth: .infinity)
                }

                // Barra de Progresso da Meta Diária
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Meta Diária Livre: \(viewModel.formatBRL(config.dailyNetGoalBRL))")
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

            // 2. Grade de KM Rodados, Tempo e Médias
            VStack(alignment: .leading, spacing: 12) {
                Text("Resumo de KM Rodados, Tempo e Médias")
                    .font(.subheadline.bold())

                HStack(spacing: 10) {
                    earningsMetricBox(
                        icon: "road.lanes",
                        title: "KM Total Rodado",
                        mainValue: String(format: "%.1f km", totalKm).replacingOccurrences(of: ".", with: ","),
                        subValue: String(format: "Busca: %.1f km • Viagem: %.1f km", totalPickupKm, totalTripKm).replacingOccurrences(of: ".", with: ","),
                        color: .blue
                    )
                    earningsMetricBox(
                        icon: "clock.fill",
                        title: "Tempo em Corridas",
                        mainValue: viewModel.formatDuration(minutes: totalMinutes),
                        subValue: "Uber: \(uberCount) • 99: \(ninenineCount)",
                        color: .purple
                    )
                }

                HStack(spacing: 10) {
                    earningsMetricBox(
                        icon: "speedometer",
                        title: "Média por KM",
                        mainValue: "\(viewModel.formatBRL(avgGrossPerKm))/km",
                        subValue: "Livre: \(viewModel.formatBRL(avgNetPerKm))/km",
                        color: .green
                    )
                    earningsMetricBox(
                        icon: "hourglass",
                        title: "Média por Hora",
                        mainValue: String(format: "R$ %.0f/h", avgGrossPerHour),
                        subValue: String(format: "Livre: R$ %.0f/h", avgNetPerHour),
                        color: .orange
                    )
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            // 3. Ações Rápidas: Lançar Corrida Manual, Detecção Automática, Meta Diária e Gasto Extra
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button {
                        viewModel.showAddManualRideSheet = true
                    } label: {
                        Label("Lançar Corrida Manual", systemImage: "plus.circle.fill")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)

                    if let last = viewModel.latestAnalysis ?? viewModel.lastSeenAnalysis, !viewModel.isRideAlreadyAccepted(last) {
                        Button {
                            viewModel.acceptRide(last)
                        } label: {
                            Label("Aceitei a Última (\(viewModel.formatBRL(last.offer.fareBRL)))", systemImage: "checkmark.circle.fill")
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                }

                Toggle(isOn: $config.autoDetectAcceptedRides) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Detectar Corrida Aceita Automaticamente")
                            .font(.subheadline.bold())
                        Text("Salva nos Ganhos quando a tela da Uber/99 muda da oferta para 'A caminho / Iniciar viagem'.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Meta Diária de Lucro Livre")
                            .font(.caption.bold())
                        Spacer()
                        Text(viewModel.formatBRL(config.dailyNetGoalBRL))
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                    }
                    Slider(value: $config.dailyNetGoalBRL, in: 50.0...600.0, step: 10.0)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Gasto Extra Hoje (Lanche / Aluguel / Lavagem)")
                            .font(.caption.bold())
                        Spacer()
                        Text(viewModel.formatBRL(config.extraDailyExpenseBRL))
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                    }
                    Slider(value: $config.extraDailyExpenseBRL, in: 0.0...250.0, step: 5.0)
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            // 4. Lista de Corridas Aceitas no Turno
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Corridas Aceitas (\(viewModel.acceptedRides.count))")
                        .font(.subheadline.bold())
                    Spacer()
                    if !viewModel.acceptedRides.isEmpty {
                        Button("Finalizar Turno", role: .destructive) {
                            viewModel.finishTurn()
                        }
                        .font(.caption.bold())
                    }
                }

                if viewModel.acceptedRides.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "car.circle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Nenhuma corrida aceita registrada ainda.")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        Text("Quando você aceitar uma corrida na Uber ou 99, ela aparecerá aqui automaticamente (ou toque em 'Aceitei' no Painel / Histórico).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .padding(.horizontal, 12)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    ForEach(viewModel.acceptedRides) { item in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(item.offer.appSource)
                                        .font(.caption2.weight(.heavy))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(item.offer.appSource == "99" ? Color.orange.opacity(0.2) : Color.blue.opacity(0.2))
                                        .foregroundStyle(item.offer.appSource == "99" ? .orange : .blue)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))

                                    Text(viewModel.formatTime(item.offer.timestamp))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    Text(String(format: "• %.1f km • %d min", item.offer.totalDistanceKm, item.offer.totalMinutes).replacingOccurrences(of: ".", with: ","))
                                        .font(.caption.bold())
                                        .foregroundStyle(.primary)
                                }

                                Text("Bruto: \(viewModel.formatBRL(item.offer.fareBRL))  •  Gasolina: -\(viewModel.formatBRL(item.fuelCostBRL))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text("+\(viewModel.formatBRL(item.netProfitBRL))")
                                    .font(.subheadline.weight(.black))
                                    .foregroundStyle(.green)
                                Text("\(viewModel.formatBRL(item.grossPerKm))/km")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                            }

                            Button(role: .destructive) {
                                viewModel.removeAcceptedRide(item)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .padding(8)
                                    .background(Color.red.opacity(0.1))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }

    private func earningsMetricBox(icon: String, title: String, mainValue: String, subValue: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption.bold())
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }
            Text(mainValue)
                .font(.headline.weight(.black))
                .foregroundStyle(.primary)
            Text(subValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - ABA 3: METAS & CARRO
public struct GoalsAndVehicleTabView: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject private var config: AppConfiguration

    public init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
        self._config = ObservedObject(wrappedValue: viewModel.config)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Suas Metas Mínimas")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Meta Mínima por KM")
                        Spacer()
                        Text(String(format: "R$ %.2f / km", config.targetBRLPerKm).replacingOccurrences(of: ".", with: ","))
                            .font(.subheadline.bold())
                            .foregroundStyle(.green)
                    }
                    Slider(value: $config.targetBRLPerKm, in: 1.00...5.00, step: 0.05)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Meta Mínima por Hora")
                        Spacer()
                        Text(String(format: "R$ %.0f / h", config.targetBRLPerHour))
                            .font(.subheadline.bold())
                            .foregroundStyle(.green)
                    }
                    Slider(value: $config.targetBRLPerHour, in: 20.0...120.0, step: 2.0)
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Consumo & Combustível")
                        .font(.headline)
                    Spacer()
                    Text(String(format: "Gasto: R$ %.2f/km", config.fuelCostPerKm).replacingOccurrences(of: ".", with: ","))
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.18))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Consumo do Seu Carro")
                        Spacer()
                        Text(String(format: "%.1f km/L", config.carConsumptionKmPerLiter).replacingOccurrences(of: ".", with: ","))
                            .font(.subheadline.bold())
                            .foregroundStyle(.blue)
                    }
                    Slider(value: $config.carConsumptionKmPerLiter, in: 5.0...22.0, step: 0.5)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Preço do Litro (Gasolina/Etanol)")
                        Spacer()
                        Text(String(format: "R$ %.2f / L", config.fuelPriceBRLPerLiter).replacingOccurrences(of: ".", with: ","))
                            .font(.subheadline.bold())
                            .foregroundStyle(.orange)
                    }
                    Slider(value: $config.fuelPriceBRLPerLiter, in: 3.00...9.00, step: 0.05)
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $config.evaluateUsingNetProfit) {
                    Text("Avaliar Meta pelo Lucro Líquido")
                        .font(.subheadline.bold())
                }

                let requiredGross = config.targetBRLPerKm + config.fuelCostPerKm
                let netLeftover = max(config.targetBRLPerKm - config.fuelCostPerKm, 0)

                if config.evaluateUsingNetProfit {
                    Text(
                        String(
                            format: "MODO RIGOROSO ATIVO: Como seu carro gasta R$ %.2f/km de combustível, para sobrar R$ %.2f/km livres no bolso, o app só dará VERDE se a corrida na tela da Uber/99 pagar pelo menos R$ %.2f/km bruto!",
                            config.fuelCostPerKm,
                            config.targetBRLPerKm,
                            requiredGross
                        ).replacingOccurrences(of: ".", with: ",")
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Text(
                        String(
                            format: "MODO PADRÃO ATIVO: O app dará VERDE sempre que a corrida na tela da Uber/99 pagar a partir de R$ %.2f/km bruto (descontando R$ %.2f/km de gasolina, sobram R$ %.2f/km livres no seu bolso).",
                            config.targetBRLPerKm,
                            config.fuelCostPerKm,
                            netLeftover
                        ).replacingOccurrences(of: ".", with: ",")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

// MARK: - ABA 4: PERSONALIZAÇÃO DE ALERTAS
public struct CustomizationTabView: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject private var config: AppConfiguration

    public init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
        self._config = ObservedObject(wrappedValue: viewModel.config)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Como Exibir o Alerta na Tela", systemImage: "rectangle.on.rectangle")
                    .font(.headline)

                Picker("Modo Visual", selection: $config.visualAlertModeRaw) {
                    ForEach(VisualAlertMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: config.visualAlertModeRaw) { newValue in
                    let isNotificationOnly = (newValue == VisualAlertMode.notificationOnly.rawValue)
                    viewModel.pipManager.setAutoStartEnabled(!isNotificationOnly)
                    if isNotificationOnly {
                        viewModel.notificationManager.requestAuthorizationIfNeeded()
                    }
                }

                Text(
                    config.visualAlertMode == .notificationOnly
                    ? "• Só Notificação: Não abre janela PiP. Mostra apenas um Banner rápido no topo quando a corrida toca."
                    : (config.visualAlertMode == .pipOnly
                       ? "• Só Janela PiP: Mantém o card colorido flutuando em cima do mapa da Uber/99."
                       : "• Ambos: Mantém a janela PiP e também dispara o Banner no topo.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 10) {
                Label("Número Principal em Destaque", systemImage: "textformat.size")
                    .font(.headline)

                Picker("Métrica Principal", selection: $config.primaryMetricDisplayRaw) {
                    ForEach(PrimaryMetricDisplay.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: config.primaryMetricDisplayRaw) { _ in
                    if let latest = viewModel.latestAnalysis {
                        viewModel.pipManager.updateCard(with: latest, displayMode: config.primaryMetricDisplay)
                    }
                }

                Text(
                    config.primaryMetricDisplay == .gross
                    ? "Mostra o R$/km Bruto (igual ao da tela da Uber/99) em letras grandes e o Lucro Líquido no cabeçalho."
                    : "Mostra já o R$/km Líquido (descontando a gasolina) diretamente nas letras gigantes e na voz."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 12) {
                Label("Personalizar Alerta de Voz", systemImage: "waveform.and.mic")
                    .font(.headline)

                Toggle("Ativar Voz Automática", isOn: $config.voiceAlertsEnabled)

                if config.voiceAlertsEnabled {
                    Divider()

                    Text("Estilo da Fala:")
                        .font(.subheadline.bold())

                    ForEach(VoiceSpeechStyle.allCases, id: \.rawValue) { style in
                        Button {
                            config.voiceSpeechStyleRaw = style.rawValue
                        } label: {
                            HStack {
                                Image(systemName: config.voiceSpeechStyle == style ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(config.voiceSpeechStyle == style ? .blue : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(style.title)
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.primary)
                                    Text(style.description)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(10)
                            .background(config.voiceSpeechStyle == style ? Color.blue.opacity(0.10) : Color(.tertiarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Velocidade da Voz")
                            Spacer()
                            Text(config.voiceSpeechRate < 0.50 ? "Pausada" : (config.voiceSpeechRate > 0.58 ? "Rápida" : "Normal"))
                                .font(.caption.bold())
                                .foregroundStyle(.blue)
                        }
                        Slider(value: $config.voiceSpeechRate, in: 0.44...0.64, step: 0.02)
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

// MARK: - ABA 5: HISTÓRICO DE CORRIDAS LIDAS
public struct HistoryTabView: View {
    @ObservedObject var viewModel: ContentViewModel

    public init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.history.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Nenhuma oferta lida ainda neste turno.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                HStack {
                    Text("\(viewModel.history.count) Ofertas Registradas")
                        .font(.subheadline.bold())
                    Spacer()
                    Button("Limpar Histórico", role: .destructive) {
                        viewModel.clearHistory()
                    }
                    .font(.caption.bold())
                }

                ForEach(viewModel.history) { item in
                    let accepted = viewModel.isRideAlreadyAccepted(item)
                    VStack(spacing: 8) {
                        Button {
                            viewModel.selectedItemForOCRDebug = item
                        } label: {
                            HStack {
                                Circle()
                                    .fill(viewModel.color(for: item.verdict))
                                    .frame(width: 12, height: 12)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(String(format: "[%@] R$ %.2f • %.1f km • %d min", item.offer.appSource, item.offer.fareBRL, item.offer.totalDistanceKm, item.offer.totalMinutes).replacingOccurrences(of: ".", with: ","))
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.primary)
                                    Text(String(format: "Lucro Livre: R$ %.2f (Comb: -R$ %.2f)", item.netProfitBRL, item.fuelCostBRL).replacingOccurrences(of: ".", with: ","))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(String(format: "R$ %.2f/km", item.grossPerKm).replacingOccurrences(of: ".", with: ","))
                                        .font(.subheadline.bold())
                                        .foregroundStyle(viewModel.color(for: item.verdict))
                                    Text(String(format: "R$ %.0f/h", item.grossPerHour))
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        HStack {
                            Text(viewModel.formatTime(item.offer.timestamp))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                viewModel.acceptRide(item)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: accepted ? "checkmark.circle.fill" : "plus.circle.fill")
                                    Text(accepted ? "Salva em Ganhos" : "Aceitei essa Corrida")
                                }
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(accepted ? Color.green.opacity(0.18) : Color.green)
                                .foregroundStyle(accepted ? Color.green : Color.white)
                                .clipShape(Capsule())
                            }
                            .disabled(accepted)
                        }
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

// MARK: - Modais Auxiliares
public struct AddManualRideSheetView: View {
    @ObservedObject var viewModel: ContentViewModel

    public init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Qual Aplicativo?") {
                    Picker("Aplicativo", selection: $viewModel.manualRideApp) {
                        Text("Uber").tag("UBER")
                        Text("99").tag("99")
                        Text("Particular / Outro").tag("EXTRA")
                    }
                    .pickerStyle(.segmented)
                }

                Section("Dados da Corrida Realizada") {
                    HStack {
                        Text("Valor Recebido (R$)")
                        Spacer()
                        TextField("Ex: 18,50", text: $viewModel.manualRideFareText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Distância Total (km)")
                        Spacer()
                        TextField("Ex: 6,5", text: $viewModel.manualRideKmText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Tempo Total (minutos)")
                        Spacer()
                        TextField("Ex: 15", text: $viewModel.manualRideMinText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("Lançar Corrida Aceita")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        viewModel.showAddManualRideSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        viewModel.saveManualRide()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.medium])
    }
}

public struct OCRDebugSheetView: View {
    public let item: RideAnalysis

    public init(item: RideAnalysis) {
        self.item = item
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Texto Exato Capturado da Tela (\(item.offer.appSource)):")
                        .font(.headline)
                    Text(item.offer.rawRecognizedText)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
            .navigationTitle("Diagnóstico OCR")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

// MARK: - ABA 6: HISTÓRICO DE TURNOS FECHADOS
public struct TurnHistoryTabView: View {
    @ObservedObject var viewModel: ContentViewModel

    public init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.archivedTurns.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Nenhum turno arquivado ainda.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                HStack {
                    Text("\(viewModel.archivedTurns.count) Turnos Encerrados")
                        .font(.subheadline.bold())
                    Spacer()
                }

                VStack(spacing: 10) {
                    ForEach(viewModel.archivedTurns) { turn in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(turn.date, style: .date)
                                    .font(.headline)
                                Spacer()
                                Text(turn.date, style: .time)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            HStack {
                                Label(viewModel.formatBRL(turn.totalNetProfit), systemImage: "dollarsign.circle.fill")
                                    .bold()
                                    .foregroundStyle(.green)
                                Spacer()
                                Text("\(turn.rides.count) corridas")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }
}

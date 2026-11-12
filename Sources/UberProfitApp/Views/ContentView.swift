import SwiftUI
import ReplayKit
import AVKit

/// Wrapper UIViewRepresentable para exibir a `AVSampleBufferDisplayLayer` necessária ao Picture-in-Picture
public struct PiPLayerContainerView: UIViewRepresentable {
    public let displayLayer: AVSampleBufferDisplayLayer

    public init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    public func makeUIView(context: Context) -> PiPHostView {
        let view = PiPHostView()
        view.setDisplayLayer(displayLayer)
        return view
    }

    public func updateUIView(_ uiView: PiPHostView, context: Context) {
        uiView.updateFrame()
    }

    public final class PiPHostView: UIView {
        private weak var hostedLayer: AVSampleBufferDisplayLayer?

        public func setDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
            hostedLayer?.removeFromSuperlayer()
            layer.frame = bounds
            self.layer.addSublayer(layer)
            self.hostedLayer = layer
        }

        public override func layoutSubviews() {
            super.layoutSubviews()
            updateFrame()
        }

        public func updateFrame() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}

/// Botão nativo do ReplayKit (`RPSystemBroadcastPickerView`) para iniciar/parar a captura de tela em 1 toque
public struct BroadcastPickerRepresentable: UIViewRepresentable {
    public init() {}

    public func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 220, height: 54))
        picker.showsMicrophoneButton = false
        picker.preferredExtension = nil
        return picker
    }

    public func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

private enum AppSectionTab: String, CaseIterable {
    case operation = "Painel"
    case earnings = "Ganhos"
    case goals = "Metas"
    case customize = "Alertas"
    case history = "Histórico"

    var icon: String {
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
public struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CategoryTabBar(viewModel: viewModel)

                ScrollView {
                    VStack(spacing: 16) {
                        switch viewModel.selectedTab {
                        case .operation:
                            OperationTabView(viewModel: viewModel)
                        case .earnings:
                            EarningsTabView(viewModel: viewModel)
                        case .goals:
                            GoalsAndVehicleTabView(viewModel: viewModel)
                        case .customize:
                            CustomizationTabView(viewModel: viewModel)
                        case .history:
                            HistoryTabView(viewModel: viewModel)
                        }
                    }
                    .padding()
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Uber & 99 Profit Auto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation {
                            viewModel.config.showQuickGuide.toggle()
                            viewModel.selectedTab = .operation
                        }
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                }
            }
            .onAppear {
                viewModel.startBackgroundServices()
            }
        }
    }
}

    // MARK: - Barra de Abas Organizadora (5 Abas)
    private var categoryTabBar: some View {
        HStack(spacing: 4) {
            ForEach(AppSectionTab.allCases, id: \.rawValue) { tab in
                let isSelected = (selectedTab == tab)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: tab.icon)
                                .font(.subheadline.bold())
                            if tab == .earnings && !acceptedRides.isEmpty {
                                Text("\(acceptedRides.count)")
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

    // MARK: - ABA 1: PAINEL DE OPERAÇÃO
    private var operationTabView: some View {
        VStack(spacing: 16) {
            if showQuickGuide {
                quickHowItWorksCard
            }

            pipPreviewSection

            if let candidate = latestAnalysis ?? lastSeenAnalysis {
                quickAcceptLastRideBar(for: candidate)
            }

            shiftControlsSection
            shiftStatsSection
            testSimulationSection
        }
    }

    private func quickAcceptLastRideBar(for item: RideAnalysis) -> some View {
        let alreadyAccepted = isRideAlreadyAccepted(item)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Última Oferta: [\(item.offer.appSource)] \(formatBRL(item.offer.fareBRL))")
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                Text(String(format: "%.1f km • %d min • Lucro %@ ", item.offer.totalDistanceKm, item.offer.totalMinutes, formatBRL(item.netProfitBRL)).replacingOccurrences(of: ".", with: ","))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                acceptRide(item)
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
                        showQuickGuide = false
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
                    .fill(udpListener.broadcastActive ? Color.green : (udpListener.isListening ? Color.orange : Color.red))
                    .frame(width: 10, height: 10)
                Text(udpListener.broadcastActive ? "Leitor Capturando" : (udpListener.isListening ? "Pronto p/ Iniciar" : "UDP Offline"))
                    .font(.caption.bold())
                    .foregroundStyle(udpListener.broadcastActive ? .green : .secondary)
            }

            ZStack {
                PiPLayerContainerView(displayLayer: pipManager.displayLayer)
                    .frame(height: 155)
                    .opacity(visualAlertMode == .notificationOnly ? 0.01 : 1.0)

                if visualAlertMode == .notificationOnly {
                    nativePreviewCard
                }
            }
            .frame(height: 155)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(udpListener.broadcastActive ? Color.green.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 2)
            )
        }
    }

    private var nativePreviewCard: some View {
        let analysis = latestAnalysis
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
                let shownKm = (primaryMetricDisplay == .net) ? analysis.netPerKm : analysis.grossPerKm
                let shownHour = (primaryMetricDisplay == .net) ? analysis.netPerHour : analysis.grossPerHour

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
                .stroke(udpListener.broadcastActive ? Color.green.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 2)
        )
    }

    private var shiftControlsSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(udpListener.broadcastActive ? Color.red : Color.blue)
                    HStack(spacing: 8) {
                        Image(systemName: udpListener.broadcastActive ? "stop.circle.fill" : "record.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(udpListener.broadcastActive ? "Leitor Ativo" : "1. Iniciar Leitor")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                            Text(udpListener.broadcastActive ? "Toque p/ parar" : "Toque p/ ligar")
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

                if visualAlertMode != .notificationOnly {
                    Button {
                        pipManager.togglePiP()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: pipManager.isPiPActive ? "pip.exit" : "pip.enter")
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(pipManager.isPiPActive ? "PiP Ativo" : "2. Abrir PiP")
                                    .font(.subheadline.bold())
                                Text(pipManager.isPiPActive ? "Toque p/ fechar" : "Janela flutuante")
                                    .font(.caption2)
                                    .opacity(0.85)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(pipManager.isPiPActive ? Color.orange : Color.green)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                } else {
                    Button {
                        selectedTab = .customize
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
                    keepAlive.isRunning ? "2º Plano Sempre Ativo" : "Keep-Alive Parado",
                    systemImage: keepAlive.isRunning ? "bolt.shield.fill" : "bolt.slash.fill"
                )
                .font(.caption.bold())
                .foregroundStyle(keepAlive.isRunning ? .green : .red)

                Spacer()

                Text(voiceAlertsEnabled ? "Voz Ligada" : "Mudo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Alerta de Voz", isOn: $voiceAlertsEnabled)
                    .labelsHidden()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var shiftStatsSection: some View {
        let approvedCount = history.filter { $0.verdict == .approved }.count
        let warningCount = history.filter { $0.verdict == .warning }.count
        let rejectedCount = history.filter { $0.verdict == .rejected }.count

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Resumo das Ofertas Recebidas Hoje")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    selectedTab = .earnings
                } label: {
                    Text("Ver Ganhos (\(acceptedRides.count) aceitas) →")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }
            }

            HStack(spacing: 10) {
                statBadge(title: "Boas", value: "\(approvedCount)", color: .green)
                statBadge(title: "Atenção", value: "\(warningCount)", color: .orange)
                statBadge(title: "Recusadas", value: "\(rejectedCount)", color: .red)
                statBadge(title: "Aceitas", value: "\(acceptedRides.count)", color: .blue)
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
                    let mock = RideOfferPayload(
                        appSource: "UBER",
                        fareBRL: 22.80,
                        pickupDistanceKm: 0.8,
                        tripDistanceKm: 7.2,
                        totalDistanceKm: 8.0,
                        pickupMinutes: 3,
                        tripMinutes: 15,
                        totalMinutes: 18,
                        rawRecognizedText: "UberX Exclusivo\nR$ 22,80\n18 min • 8.0 km • Est. de R$2,85/km\n3 min (0.8 km)\n15 minutos (7.2 km)\nAceitar",
                        timestamp: Date().timeIntervalSince1970
                    )
                    processIncomingOffer(mock)
                } label: {
                    Label("Simular Corrida Boa", systemImage: "checkmark.circle.fill")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button {
                    let mock = RideOfferPayload(
                        appSource: "99",
                        fareBRL: 10.32,
                        pickupDistanceKm: 1.4,
                        tripDistanceKm: 6.6,
                        totalDistanceKm: 8.0,
                        pickupMinutes: 5,
                        tripMinutes: 18,
                        totalMinutes: 23,
                        rawRecognizedText: "99Pop\nR$ 10,32\n5 min (1.4 km)\n18 min (6.6 km)\nAceitar",
                        timestamp: Date().timeIntervalSince1970
                    )
                    processIncomingOffer(mock)
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

    // MARK: - ABA 2: GANHOS DO TURNO (CORRIDAS ACEITAS)
    private var earningsTabView: some View {
        let totalGrossBRL = acceptedRides.map { $0.offer.fareBRL }.reduce(0, +)
        let totalPickupKm = acceptedRides.map { $0.offer.pickupDistanceKm }.reduce(0, +)
        let totalTripKm = acceptedRides.map { $0.offer.tripDistanceKm }.reduce(0, +)
        let totalKm = acceptedRides.map { $0.offer.totalDistanceKm }.reduce(0, +)
        let totalMinutes = acceptedRides.map { $0.offer.totalMinutes }.reduce(0, +)
        let totalLiters = totalKm / max(carConsumptionKmPerLiter, 1.0)
        let totalFuelCostBRL = totalLiters * fuelPriceBRLPerLiter
        let totalNetProfitBRL = totalGrossBRL - totalFuelCostBRL - extraDailyExpenseBRL

        let avgGrossPerKm = totalKm > 0 ? (totalGrossBRL / totalKm) : 0.0
        let avgNetPerKm = totalKm > 0 ? (totalNetProfitBRL / totalKm) : 0.0
        let avgGrossPerHour = totalMinutes > 0 ? ((totalGrossBRL / Double(totalMinutes)) * 60.0) : 0.0
        let avgNetPerHour = totalMinutes > 0 ? ((totalNetProfitBRL / Double(totalMinutes)) * 60.0) : 0.0

        let uberCount = acceptedRides.filter { $0.offer.appSource == "UBER" }.count
        let ninenineCount = acceptedRides.filter { $0.offer.appSource == "99" }.count
        let goalProgress = dailyNetGoalBRL > 0 ? min(max(totalNetProfitBRL / dailyNetGoalBRL, 0.0), 1.0) : 0.0

        return VStack(alignment: .leading, spacing: 16) {
            // 1. Card Principal: Lucro Livre no Bolso + Faturamento vs Gastos
            VStack(spacing: 14) {
                HStack {
                    Label("GANHOS DO TURNO", systemImage: "banknote.fill")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Text("\(acceptedRides.count) Corridas Aceitas")
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
                    Text(formatBRL(totalNetProfitBRL))
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
                        Text(formatBRL(totalGrossBRL))
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 2) {
                        Text("Gasolina (\(String(format: "%.1f L", totalLiters).replacingOccurrences(of: ".", with: ",")))")
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
                        Text("-\(formatBRL(extraDailyExpenseBRL))")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color(red: 1.0, green: 0.85, blue: 0.4))
                    }
                    .frame(maxWidth: .infinity)
                }

                // Barra de Progresso da Meta Diária
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Meta Diária Livre: \(formatBRL(dailyNetGoalBRL))")
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

            // 2. Grade de Quilometragem, Tempo e Médias Reais
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
                        mainValue: formatDuration(minutes: totalMinutes),
                        subValue: "Uber: \(uberCount) • 99: \(ninenineCount)",
                        color: .purple
                    )
                }

                HStack(spacing: 10) {
                    earningsMetricBox(
                        icon: "speedometer",
                        title: "Média por KM",
                        mainValue: "\(formatBRL(avgGrossPerKm))/km",
                        subValue: "Livre: \(formatBRL(avgNetPerKm))/km",
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
                        showAddManualRideSheet = true
                    } label: {
                        Label("Lançar Corrida Manual", systemImage: "plus.circle.fill")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)

                    if let last = latestAnalysis ?? lastSeenAnalysis, !isRideAlreadyAccepted(last) {
                        Button {
                            acceptRide(last)
                        } label: {
                            Label("Aceitei a Última (\(formatBRL(last.offer.fareBRL)))", systemImage: "checkmark.circle.fill")
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                }

                Toggle(isOn: $autoDetectAcceptedRides) {
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
                        Text(formatBRL(dailyNetGoalBRL))
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                    }
                    Slider(value: $dailyNetGoalBRL, in: 50.0...600.0, step: 10.0)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Gasto Extra Hoje (Lanche / Aluguel / Lavagem)")
                            .font(.caption.bold())
                        Spacer()
                        Text(formatBRL(extraDailyExpenseBRL))
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                    }
                    Slider(value: $extraDailyExpenseBRL, in: 0.0...250.0, step: 5.0)
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            // 4. Lista de Corridas Aceitas no Turno
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Corridas Aceitas (\(acceptedRides.count))")
                        .font(.subheadline.bold())
                    Spacer()
                    if !acceptedRides.isEmpty {
                        Button("Zerar Turno", role: .destructive) {
                            acceptedRides.removeAll()
                            extraDailyExpenseBRL = 0.0
                            savePersistedData()
                        }
                        .font(.caption.bold())
                    }
                }

                if acceptedRides.isEmpty {
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
                    ForEach(acceptedRides) { item in
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

                                    Text(formatTime(item.offer.timestamp))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    Text(String(format: "• %.1f km • %d min", item.offer.totalDistanceKm, item.offer.totalMinutes).replacingOccurrences(of: ".", with: ","))
                                        .font(.caption.bold())
                                        .foregroundStyle(.primary)
                                }

                                Text("Bruto: \(formatBRL(item.offer.fareBRL))  •  Gasolina: -\(formatBRL(item.fuelCostBRL))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text("+\(formatBRL(item.netProfitBRL))")
                                    .font(.subheadline.weight(.black))
                                    .foregroundStyle(.green)
                                Text("\(formatBRL(item.grossPerKm))/km")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                            }

                            Button(role: .destructive) {
                                removeAcceptedRide(item)
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

    private var addManualRideSheet: some View {
        NavigationStack {
            Form {
                Section("Qual Aplicativo?") {
                    Picker("Aplicativo", selection: $manualRideApp) {
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
                        TextField("Ex: 18,50", text: $manualRideFareText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Distância Total (km)")
                        Spacer()
                        TextField("Ex: 6,5", text: $manualRideKmText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Tempo Total (minutos)")
                        Spacer()
                        TextField("Ex: 15", text: $manualRideMinText)
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
                        showAddManualRideSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        saveManualRide()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func saveManualRide() {
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

    // MARK: - ABA 3: METAS & CARRO
    private var goalsAndVehicleTabView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Suas Metas Mínimas")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Meta Mínima por KM")
                        Spacer()
                        Text(String(format: "R$ %.2f / km", targetBRLPerKm).replacingOccurrences(of: ".", with: ","))
                            .font(.subheadline.bold())
                            .foregroundStyle(.green)
                    }
                    Slider(value: $targetBRLPerKm, in: 1.00...5.00, step: 0.05)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Meta Mínima por Hora")
                        Spacer()
                        Text(String(format: "R$ %.0f / h", targetBRLPerHour))
                            .font(.subheadline.bold())
                            .foregroundStyle(.green)
                    }
                    Slider(value: $targetBRLPerHour, in: 20.0...120.0, step: 2.0)
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
                    Text(String(format: "Gasto: R$ %.2f/km", fuelCostPerKm).replacingOccurrences(of: ".", with: ","))
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
                        Text(String(format: "%.1f km/L", carConsumptionKmPerLiter).replacingOccurrences(of: ".", with: ","))
                            .font(.subheadline.bold())
                            .foregroundStyle(.blue)
                    }
                    Slider(value: $carConsumptionKmPerLiter, in: 5.0...22.0, step: 0.5)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Preço do Litro (Gasolina/Etanol)")
                        Spacer()
                        Text(String(format: "R$ %.2f / L", fuelPriceBRLPerLiter).replacingOccurrences(of: ".", with: ","))
                            .font(.subheadline.bold())
                            .foregroundStyle(.orange)
                    }
                    Slider(value: $fuelPriceBRLPerLiter, in: 3.00...9.00, step: 0.05)
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $evaluateUsingNetProfit) {
                    Text("Avaliar Meta pelo Lucro Líquido")
                        .font(.subheadline.bold())
                }

                let requiredGross = targetBRLPerKm + fuelCostPerKm
                let netLeftover = max(targetBRLPerKm - fuelCostPerKm, 0)

                if evaluateUsingNetProfit {
                    Text(
                        String(
                            format: "MODO RIGOROSO ATIVO: Como seu carro gasta R$ %.2f/km de combustível, para sobrar R$ %.2f/km livres no bolso, o app só dará VERDE se a corrida na tela da Uber/99 pagar pelo menos R$ %.2f/km bruto!",
                            fuelCostPerKm,
                            targetBRLPerKm,
                            requiredGross
                        ).replacingOccurrences(of: ".", with: ",")
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Text(
                        String(
                            format: "MODO PADRÃO ATIVO: O app dará VERDE sempre que a corrida na tela da Uber/99 pagar a partir de R$ %.2f/km bruto (descontando R$ %.2f/km de gasolina, sobram R$ %.2f/km livres no seu bolso).",
                            targetBRLPerKm,
                            fuelCostPerKm,
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

    // MARK: - ABA 4: PERSONALIZAÇÃO DE ALERTAS
    private var customizationTabView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Como Exibir o Alerta na Tela", systemImage: "rectangle.on.rectangle")
                    .font(.headline)

                Picker("Modo Visual", selection: $visualAlertModeRaw) {
                    ForEach(VisualAlertMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: visualAlertModeRaw) { newValue in
                    let isNotificationOnly = (newValue == VisualAlertMode.notificationOnly.rawValue)
                    pipManager.setAutoStartEnabled(!isNotificationOnly)
                    if isNotificationOnly {
                        notificationManager.requestAuthorizationIfNeeded()
                    }
                }

                Text(
                    visualAlertMode == .notificationOnly
                    ? "• Só Notificação: Não abre janela PiP. Mostra apenas um Banner rápido no topo quando a corrida toca."
                    : (visualAlertMode == .pipOnly
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

                Picker("Métrica Principal", selection: $primaryMetricDisplayRaw) {
                    ForEach(PrimaryMetricDisplay.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: primaryMetricDisplayRaw) { _ in
                    if let latest = latestAnalysis {
                        pipManager.updateCard(with: latest, displayMode: primaryMetricDisplay)
                    }
                }

                Text(
                    primaryMetricDisplay == .gross
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

                Toggle("Ativar Voz Automática", isOn: $voiceAlertsEnabled)

                if voiceAlertsEnabled {
                    Divider()

                    Text("Estilo da Fala:")
                        .font(.subheadline.bold())

                    ForEach(VoiceSpeechStyle.allCases, id: \.rawValue) { style in
                        Button {
                            voiceSpeechStyleRaw = style.rawValue
                        } label: {
                            HStack {
                                Image(systemName: voiceSpeechStyle == style ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(voiceSpeechStyle == style ? .blue : .secondary)
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
                            .background(voiceSpeechStyle == style ? Color.blue.opacity(0.10) : Color(.tertiarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Velocidade da Voz")
                            Spacer()
                            Text(voiceSpeechRate < 0.50 ? "Pausada" : (voiceSpeechRate > 0.58 ? "Rápida" : "Normal"))
                                .font(.caption.bold())
                                .foregroundStyle(.blue)
                        }
                        Slider(value: $voiceSpeechRate, in: 0.44...0.64, step: 0.02)
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - ABA 5: HISTÓRICO DE CORRIDAS LIDAS (COM BOTÃO 1-TOQUE "ACEITEI")
    private var historyTabView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if history.isEmpty {
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
                    Text("\(history.count) Ofertas Registradas")
                        .font(.subheadline.bold())
                    Spacer()
                    Button("Limpar Histórico", role: .destructive) {
                        history.removeAll()
                        savePersistedData()
                    }
                    .font(.caption.bold())
                }

                ForEach(history) { item in
                    let accepted = isRideAlreadyAccepted(item)
                    VStack(spacing: 8) {
                        Button {
                            selectedItemForOCRDebug = item
                        } label: {
                            HStack {
                                Circle()
                                    .fill(color(for: item.verdict))
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
                                        .foregroundStyle(color(for: item.verdict))
                                    Text(String(format: "R$ %.0f/h", item.grossPerHour))
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        HStack {
                            Text(formatTime(item.offer.timestamp))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                acceptRide(item)
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

    private func ocrDebugSheet(for item: RideAnalysis) -> some View {
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

    // MARK: - Gerenciamento de Corridas Aceitas e Persistência
    private func isRideAlreadyAccepted(_ ride: RideAnalysis) -> Bool {
        acceptedRides.contains {
            $0.id == ride.id ||
            (abs($0.offer.fareBRL - ride.offer.fareBRL) < 0.01 &&
             abs($0.offer.totalDistanceKm - ride.offer.totalDistanceKm) < 0.05 &&
             abs($0.offer.timestamp - ride.offer.timestamp) < 60.0)
        }
    }

    private func acceptRide(_ ride: RideAnalysis) {
        guard !isRideAlreadyAccepted(ride) else { return }
        withAnimation {
            acceptedRides.insert(ride, at: 0)
        }
        savePersistedData()
    }

    private func removeAcceptedRide(_ ride: RideAnalysis) {
        withAnimation {
            acceptedRides.removeAll { $0.id == ride.id }
        }
        savePersistedData()
    }

    private func savePersistedData() {
        if let encodedAccepted = try? JSONEncoder().encode(acceptedRides) {
            UserDefaults.standard.set(encodedAccepted, forKey: savedAcceptedKey)
        }
        let recentHistory = Array(history.prefix(80))
        if let encodedHistory = try? JSONEncoder().encode(recentHistory) {
            UserDefaults.standard.set(encodedHistory, forKey: savedHistoryKey)
        }
    }

    private func loadPersistedData() {
        if let data = UserDefaults.standard.data(forKey: savedAcceptedKey),
           let decoded = try? JSONDecoder().decode([RideAnalysis].self, from: data) {
            acceptedRides = decoded
        }
        if let data = UserDefaults.standard.data(forKey: savedHistoryKey),
           let decoded = try? JSONDecoder().decode([RideAnalysis].self, from: data) {
            history = decoded
            lastSeenAnalysis = decoded.first
        }
    }

    // MARK: - Inicialização e Pipeline de Ofertas
    private func startBackgroundServices() {
        keepAlive.start()
        notificationManager.requestAuthorizationIfNeeded()
        pipManager.setAutoStartEnabled(visualAlertMode != .notificationOnly)

        voiceManager.onSpeechFinished = { [weak keepAlive] in
            keepAlive?.ensureEnginePlaying()
        }

        notificationManager.onAcceptRideFromNotification = {
            if let candidate = latestAnalysis ?? lastSeenAnalysis {
                acceptRide(candidate)
            }
        }

        udpListener.onOfferReceived = { offer in
            processIncomingOffer(offer)
        }
        udpListener.onClearCardRequested = {
            latestAnalysis = nil
            pipManager.updateCard(with: nil, displayMode: primaryMetricDisplay)
        }
        udpListener.onRideAcceptedDetected = {
            if autoDetectAcceptedRides, let candidate = latestAnalysis ?? lastSeenAnalysis {
                acceptRide(candidate)
            }
        }
        udpListener.startListening()
    }

    private func processIncomingOffer(_ offer: RideOfferPayload) {
        let settings = currentSettings
        let analysis = ProfitCalculator.evaluate(offer: offer, settings: settings)
        latestAnalysis = analysis
        lastSeenAnalysis = analysis
        history.insert(analysis, at: 0)
        savePersistedData()

        pipManager.updateCard(with: analysis, displayMode: primaryMetricDisplay)

        if visualAlertMode == .notificationOnly || visualAlertMode == .both {
            notificationManager.sendRideBanner(analysis: analysis, displayMode: primaryMetricDisplay)
        }

        voiceManager.announce(analysis: analysis, settings: settings)
    }

    // MARK: - Formatadores Auxiliares
    private func formatBRL(_ value: Double) -> String {
        String(format: "R$ %.2f", value).replacingOccurrences(of: ".", with: ",")
    }

    private func formatDuration(minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes) min"
        }
        let h = minutes / 60
        let m = minutes % 60
        return m > 0 ? "\(h)h \(m)min" : "\(h)h"
    }

    private func formatTime(_ timestamp: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    private func color(for verdict: RideVerdict) -> Color {
        switch verdict {
        case .approved: return .green
        case .warning: return .orange
        case .rejected: return .red
        }
    }
}

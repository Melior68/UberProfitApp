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
    case goals = "Metas & Carro"
    case customize = "Personalizar"
    case history = "Histórico"

    var icon: String {
        switch self {
        case .operation: return "bolt.car.fill"
        case .goals: return "slider.horizontal.3"
        case .customize: return "paintbrush.pointed.fill"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

@MainActor
public struct ContentView: View {
    // Metas e Veículo
    @AppStorage("targetBRLPerKm") private var targetBRLPerKm: Double = 2.00
    @AppStorage("targetBRLPerHour") private var targetBRLPerHour: Double = 40.00
    @AppStorage("carConsumptionKmPerLiter") private var carConsumptionKmPerLiter: Double = 10.0
    @AppStorage("fuelPriceBRLPerLiter") private var fuelPriceBRLPerLiter: Double = 6.35
    @AppStorage("evaluateUsingNetProfit") private var evaluateUsingNetProfit: Bool = false

    // Personalização de Alertas e Voz
    @AppStorage("voiceAlertsEnabled") private var voiceAlertsEnabled: Bool = true
    @AppStorage("voiceSpeechStyleRaw") private var voiceSpeechStyleRaw: String = VoiceSpeechStyle.full.rawValue
    @AppStorage("voiceSpeechRate") private var voiceSpeechRate: Double = 0.54
    @AppStorage("visualAlertModeRaw") private var visualAlertModeRaw: String = VisualAlertMode.notificationOnly.rawValue
    @AppStorage("primaryMetricDisplayRaw") private var primaryMetricDisplayRaw: String = PrimaryMetricDisplay.gross.rawValue
    @AppStorage("showQuickGuide") private var showQuickGuide: Bool = true

    @StateObject private var keepAlive = BackgroundKeepAlive()
    @StateObject private var udpListener = UDPListenerManager()
    @StateObject private var voiceManager = VoiceAlertManager()
    @StateObject private var pipManager = PiPOverlayManager()
    @StateObject private var notificationManager = NotificationAlertManager()

    @State private var selectedTab: AppSectionTab = .operation
    @State private var latestAnalysis: RideAnalysis?
    @State private var history: [RideAnalysis] = []
    @State private var selectedItemForOCRDebug: RideAnalysis?

    public init() {}

    private var visualAlertMode: VisualAlertMode {
        VisualAlertMode(rawValue: visualAlertModeRaw) ?? .notificationOnly
    }

    private var voiceSpeechStyle: VoiceSpeechStyle {
        VoiceSpeechStyle(rawValue: voiceSpeechStyleRaw) ?? .full
    }

    private var primaryMetricDisplay: PrimaryMetricDisplay {
        PrimaryMetricDisplay(rawValue: primaryMetricDisplayRaw) ?? .gross
    }

    private var fuelCostPerKm: Double {
        fuelPriceBRLPerLiter / max(carConsumptionKmPerLiter, 1.0)
    }

    private var currentSettings: DriverSettings {
        DriverSettings(
            targetBRLPerKm: targetBRLPerKm,
            targetBRLPerHour: targetBRLPerHour,
            carConsumptionKmPerLiter: carConsumptionKmPerLiter,
            fuelPriceBRLPerLiter: fuelPriceBRLPerLiter,
            voiceAlertsEnabled: voiceAlertsEnabled,
            evaluateUsingNetProfit: evaluateUsingNetProfit,
            voiceSpeechStyle: voiceSpeechStyle,
            voiceSpeechRate: voiceSpeechRate,
            primaryMetricDisplay: primaryMetricDisplay
        )
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Barra de Navegação de Categorias no Topo (Design Limpo e Organizado)
                categoryTabBar

                ScrollView {
                    VStack(spacing: 16) {
                        switch selectedTab {
                        case .operation:
                            operationTabView
                        case .goals:
                            goalsAndVehicleTabView
                        case .customize:
                            customizationTabView
                        case .history:
                            historyTabView
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
                            showQuickGuide.toggle()
                            selectedTab = .operation
                        }
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                }
            }
            .onAppear {
                startBackgroundServices()
            }
            .sheet(item: $selectedItemForOCRDebug) { item in
                ocrDebugSheet(for: item)
            }
        }
    }

    // MARK: - Barra de Abas Organizadora
    private var categoryTabBar: some View {
        HStack(spacing: 6) {
            ForEach(AppSectionTab.allCases, id: \.rawValue) { tab in
                let isSelected = (selectedTab == tab)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.subheadline.bold())
                        Text(tab.rawValue)
                            .font(.caption2.bold())
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
        .padding(.horizontal, 12)
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
            shiftControlsSection
            shiftStatsSection
            testSimulationSection
        }
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
                Label("2. Escolha se prefere receber só Notificação no topo ou Janela Flutuante (PiP).", systemImage: "2.circle.fill")
                    .font(.caption)
                Label("3. Abra a Uber ou 99 Motorista: assim que tocar corrida, o cálculo e a voz disparam sozinhos!", systemImage: "3.circle.fill")
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

            if visualAlertMode == .notificationOnly {
                nativePreviewCard
            } else {
                PiPLayerContainerView(displayLayer: pipManager.displayLayer)
                    .frame(height: 155)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(udpListener.broadcastActive ? Color.green.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 2)
                    )
            }
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
        let avgKm = history.isEmpty ? 0.0 : (history.map(\.grossPerKm).reduce(0, +) / Double(history.count))

        return VStack(alignment: .leading, spacing: 8) {
            Text("Resumo das Ofertas Recebidas Hoje")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                statBadge(title: "Boas", value: "\(approvedCount)", color: .green)
                statBadge(title: "Atenção", value: "\(warningCount)", color: .orange)
                statBadge(title: "Recusadas", value: "\(rejectedCount)", color: .red)
                statBadge(
                    title: "Média/km",
                    value: String(format: "R$ %.2f", avgKm).replacingOccurrences(of: ".", with: ","),
                    color: .blue
                )
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

    // MARK: - ABA 2: METAS & CARRO
    private var goalsAndVehicleTabView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Card de Metas
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

            // Card do Veículo e Combustível
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

            // Explicação Clara da Chave: Meta Bruta vs Meta pelo Lucro Líquido
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

    // MARK: - ABA 3: PERSONALIZAÇÃO
    private var customizationTabView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Formato do Alerta Visual
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

            // Qual número mostrar grande (Bruto vs Líquido)
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

            // Personalização da Voz
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

    // MARK: - ABA 4: HISTÓRICO DE CORRIDAS LIDAS
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
                    Text("\(history.count) Ofertas Registradas (Toque p/ ver OCR)")
                        .font(.subheadline.bold())
                    Spacer()
                    Button("Limpar Tudo", role: .destructive) {
                        history.removeAll()
                    }
                    .font(.caption.bold())
                }

                ForEach(history) { item in
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
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
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

    // MARK: - Inicialização e Pipeline de Ofertas
    private func startBackgroundServices() {
        keepAlive.start()
        notificationManager.requestAuthorizationIfNeeded()
        pipManager.setAutoStartEnabled(visualAlertMode != .notificationOnly)

        voiceManager.onSpeechFinished = { [weak keepAlive] in
            keepAlive?.ensureEnginePlaying()
        }

        udpListener.onOfferReceived = { offer in
            processIncomingOffer(offer)
        }
        udpListener.startListening()
    }

    private func processIncomingOffer(_ offer: RideOfferPayload) {
        let settings = currentSettings
        let analysis = ProfitCalculator.evaluate(offer: offer, settings: settings)
        latestAnalysis = analysis
        history.insert(analysis, at: 0)

        pipManager.updateCard(with: analysis, displayMode: primaryMetricDisplay)

        if visualAlertMode == .notificationOnly || visualAlertMode == .both {
            notificationManager.sendRideBanner(analysis: analysis, displayMode: primaryMetricDisplay)
        }

        voiceManager.announce(analysis: analysis, settings: settings)
    }

    private func color(for verdict: RideVerdict) -> Color {
        switch verdict {
        case .approved: return .green
        case .warning: return .orange
        case .rejected: return .red
        }
    }
}

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

@MainActor
public struct ContentView: View {
    @AppStorage("targetBRLPerKm") private var targetBRLPerKm: Double = 2.00
    @AppStorage("targetBRLPerHour") private var targetBRLPerHour: Double = 40.00
    @AppStorage("carConsumptionKmPerLiter") private var carConsumptionKmPerLiter: Double = 10.0
    @AppStorage("fuelPriceBRLPerLiter") private var fuelPriceBRLPerLiter: Double = 6.35
    @AppStorage("voiceAlertsEnabled") private var voiceAlertsEnabled: Bool = true
    @AppStorage("evaluateUsingNetProfit") private var evaluateUsingNetProfit: Bool = false
    @AppStorage("visualAlertModeRaw") private var visualAlertModeRaw: String = VisualAlertMode.both.rawValue

    @StateObject private var keepAlive = BackgroundKeepAlive()
    @StateObject private var udpListener = UDPListenerManager()
    @StateObject private var voiceManager = VoiceAlertManager()
    @StateObject private var pipManager = PiPOverlayManager()
    @StateObject private var notificationManager = NotificationAlertManager()

    @State private var latestAnalysis: RideAnalysis?
    @State private var history: [RideAnalysis] = []
    @State private var selectedItemForOCRDebug: RideAnalysis?

    public init() {}

    private var visualAlertMode: VisualAlertMode {
        VisualAlertMode(rawValue: visualAlertModeRaw) ?? .both
    }

    private var currentSettings: DriverSettings {
        DriverSettings(
            targetBRLPerKm: targetBRLPerKm,
            targetBRLPerHour: targetBRLPerHour,
            carConsumptionKmPerLiter: carConsumptionKmPerLiter,
            fuelPriceBRLPerLiter: fuelPriceBRLPerLiter,
            voiceAlertsEnabled: voiceAlertsEnabled,
            evaluateUsingNetProfit: evaluateUsingNetProfit
        )
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // Preview ao vivo do Card
                    pipPreviewSection

                    // Botões de Controle do Turno (Status Real do Leitor + Modo de Alerta)
                    shiftControlsSection

                    // Seletor: Só Notificação, Só PiP ou Ambos
                    alertModeSection

                    // Resumo Estatístico do Turno (se houver corridas lidas)
                    if !history.isEmpty {
                        shiftStatsSection
                    }

                    // Sliders de Metas e Custos do Veículo
                    settingsSlidersSection

                    // Simulador para testar Voz, Notificação Banner e PiP
                    testSimulationSection

                    // Histórico recente de ofertas lidas (com toque para ver OCR bruto)
                    if !history.isEmpty {
                        recentOffersSection
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Uber & 99 Profit Auto")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                startBackgroundServices()
            }
            .sheet(item: $selectedItemForOCRDebug) { item in
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Texto Bruto Lido pelo OCR:")
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
                    .navigationTitle("Diagnóstico OCR (\(item.offer.appSource))")
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium])
            }
        }
    }

    // MARK: - Seções da Interface
    private var pipPreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Painel em Tempo Real", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(udpListener.broadcastActive ? Color.green : (udpListener.isListening ? Color.orange : Color.red))
                    .frame(width: 10, height: 10)
                Text(udpListener.broadcastActive ? "Leitor Capturando" : (udpListener.isListening ? "UDP 9876 Pronto" : "UDP Offline"))
                    .font(.caption.bold())
                    .foregroundStyle(udpListener.broadcastActive ? .green : .secondary)
            }

            PiPLayerContainerView(displayLayer: pipManager.displayLayer)
                .frame(height: 155)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(udpListener.broadcastActive ? Color.green.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 2)
                )
        }
    }

    private var shiftControlsSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Botão 1: Muda automaticamente quando o Leitor de Tela já está ligado!
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

                // Botão 2: Abrir/Fechar PiP (ou Testar Banner se estiver no modo Só Notificação)
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
                        notificationManager.requestAuthorizationIfNeeded()
                        if let latest = latestAnalysis {
                            notificationManager.sendRideBanner(analysis: latest)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "bell.badge.fill")
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Modo Banner")
                                    .font(.subheadline.bold())
                                Text("Sem janela PiP")
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
                    keepAlive.isRunning ? "Keep-Alive em Segundo Plano Ativo" : "Keep-Alive Parado",
                    systemImage: keepAlive.isRunning ? "bolt.shield.fill" : "bolt.slash.fill"
                )
                .font(.caption.bold())
                .foregroundStyle(keepAlive.isRunning ? .green : .red)

                Spacer()

                Toggle("Alerta de Voz", isOn: $voiceAlertsEnabled)
                    .labelsHidden()
                Image(systemName: voiceAlertsEnabled ? "speaker.wave.3.fill" : "speaker.slash.fill")
                    .foregroundStyle(voiceAlertsEnabled ? .blue : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var alertModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Formato do Alerta Visual na Tela")
                .font(.subheadline.bold())

            Picker("Modo Visual", selection: $visualAlertModeRaw) {
                ForEach(VisualAlertMode.allCases, id: \.rawValue) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: visualAlertModeRaw) { newValue in
                if newValue == VisualAlertMode.notificationOnly.rawValue {
                    pipManager.stopPiPIfActive()
                    notificationManager.requestAuthorizationIfNeeded()
                }
            }

            Text(
                visualAlertMode == .notificationOnly
                ? "Envia apenas uma Notificação (Banner no topo) quando a corrida toca, deixando o mapa 100% livre."
                : (visualAlertMode == .pipOnly
                   ? "Usa apenas a janela flutuante Picture-in-Picture sobre a Uber/99."
                   : "Usa ambos: atualiza a janela PiP e também dispara o Banner de Notificação no topo.")
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var shiftStatsSection: some View {
        let approvedCount = history.filter { $0.verdict == .approved }.count
        let warningCount = history.filter { $0.verdict == .warning }.count
        let rejectedCount = history.filter { $0.verdict == .rejected }.count
        let avgKm = history.map(\.grossPerKm).reduce(0, +) / Double(max(history.count, 1))

        return HStack(spacing: 12) {
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

    private var settingsSlidersSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Metas & Custo do Veículo")
                    .font(.headline)
                Spacer()
                CostPerKmBadge(consumption: carConsumptionKmPerLiter, fuelPrice: fuelPriceBRLPerLiter)
            }

            // Meta de R$/km
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

            // Meta de R$/hora
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

            Divider()

            // Consumo km/L
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Consumo do Carro")
                    Spacer()
                    Text(String(format: "%.1f km/L", carConsumptionKmPerLiter).replacingOccurrences(of: ".", with: ","))
                        .font(.subheadline.bold())
                        .foregroundStyle(.blue)
                }
                Slider(value: $carConsumptionKmPerLiter, in: 5.0...22.0, step: 0.5)
            }

            Divider()

            // Preço do Combustível
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Preço do Combustível")
                    Spacer()
                    Text(String(format: "R$ %.2f / L", fuelPriceBRLPerLiter).replacingOccurrences(of: ".", with: ","))
                        .font(.subheadline.bold())
                        .foregroundStyle(.orange)
                }
                Slider(value: $fuelPriceBRLPerLiter, in: 3.00...9.00, step: 0.05)
            }

            Divider()

            Toggle(isOn: $evaluateUsingNetProfit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Avaliar Meta pelo Lucro Líquido")
                        .font(.subheadline)
                    Text("Se ativo, exige a meta de R$/km já descontando a gasolina")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var testSimulationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Testar Alertas (Voz + Banner + PiP)")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Simular Uber Boa") {
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
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button("Simular 99 Ruim") {
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
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recentOffersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Últimas Ofertas Lidas (Toque p/ ver OCR)")
                    .font(.headline)
                Spacer()
                Button("Limpar") {
                    history.removeAll()
                }
                .font(.caption)
            }

            ForEach(history.prefix(12)) { item in
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
                            Text(String(format: "Líquido: R$ %.2f (Comb: -R$ %.2f)", item.netProfitBRL, item.fuelCostBRL).replacingOccurrences(of: ".", with: ","))
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

    // MARK: - Inicialização e Pipeline de Ofertas
    private func startBackgroundServices() {
        keepAlive.start()
        notificationManager.requestAuthorizationIfNeeded()

        voiceManager.onSpeechFinished = { [weak keepAlive] in
            keepAlive?.ensureEnginePlaying()
        }

        udpListener.onOfferReceived = { offer in
            processIncomingOffer(offer)
        }
        udpListener.startListening()
    }

    private func processIncomingOffer(_ offer: RideOfferPayload) {
        let analysis = ProfitCalculator.evaluate(offer: offer, settings: currentSettings)
        latestAnalysis = analysis
        history.insert(analysis, at: 0)

        // Atualiza card do PiP (sempre atualiza o preview e o PiP se ativo)
        pipManager.updateCard(with: analysis)

        // Se o motorista escolheu "Só Notificação" ou "Notificação + PiP", envia o Banner imediato
        if visualAlertMode == .notificationOnly || visualAlertMode == .both {
            notificationManager.sendRideBanner(analysis: analysis)
        }

        // Alerta de voz + bipe
        voiceManager.announce(analysis: analysis, enabled: voiceAlertsEnabled)
    }

    private func color(for verdict: RideVerdict) -> Color {
        switch verdict {
        case .approved: return .green
        case .warning: return .orange
        case .rejected: return .red
        }
    }
}

private struct CostPerKmBadge: View {
    let consumption: Double
    let fuelPrice: Double

    var body: some View {
        let costPerKm = fuelPrice / max(consumption, 1.0)
        Text(String(format: "Custo: R$ %.2f/km", costPerKm).replacingOccurrences(of: ".", with: ","))
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.15))
            .foregroundStyle(.orange)
            .clipShape(Capsule())
    }
}

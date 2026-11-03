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

/// Botão nativo do ReplayKit (`RPSystemBroadcastPickerView`) para iniciar a captura de tela em 1 toque
public struct BroadcastPickerRepresentable: UIViewRepresentable {
    public init() {}

    public func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        picker.showsMicrophoneButton = false
        // Como no Sideloadly/SideStore o Bundle ID ganha sufixo do time gratuito, deixamos nil
        // ou filtramos automaticamente para permitir selecionar a ScreenReaderExtension sem travas.
        picker.preferredExtension = nil
        return picker
    }

    public func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

@MainActor
public struct ContentView: View {
    @AppStorage("targetBRLPerKm") private var targetBRLPerKm: Double = 2.00
    @AppStorage("targetBRLPerHour") private var targetBRLPerHour: Double = 40.00
    @AppStorage("carConsumptionKmPerLiter") private var carConsumptionKmPerLiter: Double = 11.5
    @AppStorage("fuelPriceBRLPerLiter") private var fuelPriceBRLPerLiter: Double = 5.89
    @AppStorage("voiceAlertsEnabled") private var voiceAlertsEnabled: Bool = true

    @StateObject private var keepAlive = BackgroundKeepAlive()
    @StateObject private var udpListener = UDPListenerManager()
    @StateObject private var voiceManager = VoiceAlertManager()
    @StateObject private var pipManager = PiPOverlayManager()

    @State private var latestAnalysis: RideAnalysis?
    @State private var history: [RideAnalysis] = []

    public init() {}

    private var currentSettings: DriverSettings {
        DriverSettings(
            targetBRLPerKm: targetBRLPerKm,
            targetBRLPerHour: targetBRLPerHour,
            carConsumptionKmPerLiter: carConsumptionKmPerLiter,
            fuelPriceBRLPerLiter: fuelPriceBRLPerLiter,
            voiceAlertsEnabled: voiceAlertsEnabled
        )
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // Preview ao vivo do Card do PiP
                    pipPreviewSection

                    // Botões de Controle do Turno (Broadcast + PiP + KeepAlive)
                    shiftControlsSection

                    // Sliders de Metas e Custos do Veículo
                    settingsSlidersSection

                    // Botão de Simulação para testar Voz e PiP antes de sair
                    testSimulationSection

                    // Histórico recente de ofertas lidas no turno
                    if !history.isEmpty {
                        recentOffersSection
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("UberProfit Auto")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                startBackgroundServices()
            }
        }
    }

    // MARK: - Seções da Interface
    private var pipPreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Card Flutuante (PiP)", systemImage: "pip")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(udpListener.isListening ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(udpListener.isListening ? "UDP 9876 Ativo" : "UDP Offline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PiPLayerContainerView(displayLayer: pipManager.displayLayer)
                .frame(height: 155)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
        }
    }

    private var shiftControlsSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.blue)
                    HStack {
                        Image(systemName: "record.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                        Text("1. Iniciar Leitor de Tela")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                    }
                    BroadcastPickerRepresentable()
                        .frame(width: 220, height: 52)
                        .blendMode(.destinationOver)
                }
                .frame(height: 54)

                Button {
                    pipManager.togglePiP()
                } label: {
                    HStack {
                        Image(systemName: pipManager.isPiPActive ? "pip.exit" : "pip.enter")
                        Text(pipManager.isPiPActive ? "Fechar PiP" : "2. Abrir PiP")
                            .font(.subheadline.bold())
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(pipManager.isPiPActive ? Color.orange : Color.green)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
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

    private var settingsSlidersSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Metas & Custo do Veículo")
                .font(.headline)

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
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var testSimulationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Testar Alertas e PiP (Simulador)")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Simular Corrida Boa") {
                    let mock = RideOfferPayload(
                        fareBRL: 26.40,
                        pickupDistanceKm: 1.5,
                        tripDistanceKm: 9.5,
                        totalDistanceKm: 11.0,
                        pickupMinutes: 4,
                        tripMinutes: 20,
                        totalMinutes: 24,
                        rawRecognizedText: "Simulação Boa",
                        timestamp: Date().timeIntervalSince1970
                    )
                    processIncomingOffer(mock)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button("Simular Corrida Ruim") {
                    let mock = RideOfferPayload(
                        fareBRL: 11.20,
                        pickupDistanceKm: 3.2,
                        tripDistanceKm: 6.8,
                        totalDistanceKm: 10.0,
                        pickupMinutes: 8,
                        tripMinutes: 19,
                        totalMinutes: 27,
                        rawRecognizedText: "Simulação Ruim",
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
            Text("Últimas Ofertas Lidas")
                .font(.headline)

            ForEach(history.prefix(8)) { item in
                HStack {
                    Circle()
                        .fill(color(for: item.verdict))
                        .frame(width: 12, height: 12)
                    VStack(alignment: .leading) {
                        Text(String(format: "R$ %.2f • %.1f km • %d min", item.offer.fareBRL, item.offer.totalDistanceKm, item.offer.totalMinutes).replacingOccurrences(of: ".", with: ","))
                            .font(.subheadline.bold())
                        Text(String(format: "Líquido: R$ %.2f (Comb: -R$ %.2f)", item.netProfitBRL, item.fuelCostBRL).replacingOccurrences(of: ".", with: ","))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(String(format: "R$ %.2f/km", item.grossPerKm).replacingOccurrences(of: ".", with: ","))
                            .font(.subheadline.bold())
                        Text(String(format: "R$ %.0f/h", item.grossPerHour))
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Inicialização e Pipeline de Ofertas
    private func startBackgroundServices() {
        keepAlive.start()
        udpListener.onOfferReceived = { offer in
            processIncomingOffer(offer)
        }
        udpListener.startListening()
    }

    private func processIncomingOffer(_ offer: RideOfferPayload) {
        let analysis = ProfitCalculator.evaluate(offer: offer, settings: currentSettings)
        latestAnalysis = analysis
        history.insert(analysis, at: 0)
        pipManager.updateCard(with: analysis)
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

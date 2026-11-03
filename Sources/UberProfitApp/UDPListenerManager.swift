import Foundation
import Network

/// Gerencia um socket UDP local (`127.0.0.1:9876`) para receber instantaneamente os pacotes JSON
/// enviados pela `ScreenReaderExtension`, eliminando qualquer dependência de App Groups pagos.
@MainActor
public final class UDPListenerManager: ObservableObject {
    @Published public private(set) var isListening: Bool = false
    @Published public private(set) var broadcastActive: Bool = false
    @Published public private(set) var lastPacketTime: Date?

    public var onOfferReceived: ((RideOfferPayload) -> Void)?

    private var listener: NWListener?
    private let port: NWEndpoint.Port = 9876
    private let listenerQueue = DispatchQueue(label: "com.uberprofit.udplistener", qos: .userInteractive)

    public init() {}

    public func startListening() {
        guard listener == nil else { return }

        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true

            let nwListener = try NWListener(using: params, on: port)

            nwListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isListening = true
                    case .failed, .cancelled:
                        self.isListening = false
                        self.listener = nil
                    default:
                        break
                    }
                }
            }

            nwListener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.listenerQueue ?? .global(qos: .userInteractive))
                self?.receiveLoop(on: connection)
            }

            nwListener.start(queue: listenerQueue)
            self.listener = nwListener
        } catch {
            self.isListening = false
        }
    }

    public func stopListening() {
        listener?.cancel()
        listener = nil
        isListening = false
    }

    nonisolated private func receiveLoop(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data, !data.isEmpty {
                self?.handleIncomingData(data)
            }
            if error == nil {
                self?.receiveLoop(on: connection)
            } else {
                connection.cancel()
            }
        }
    }

    nonisolated private func handleIncomingData(_ data: Data) {
        if let offer = try? JSONDecoder().decode(RideOfferPayload.self, from: data) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastPacketTime = Date()
                self.broadcastActive = true
                self.onOfferReceived?(offer)
            }
            return
        }

        if let statusDict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let status = statusDict["status"] {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastPacketTime = Date()
                if status == "BROADCAST_STARTED" || status == "BROADCAST_RESUMED" {
                    self.broadcastActive = true
                } else if status == "BROADCAST_FINISHED" {
                    self.broadcastActive = false
                }
            }
        }
    }
}

import Foundation
import Network

/// Connects to kanata's TCP server and reports layer changes.
class KanataClient {
    private var connection: NWConnection?
    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "\(Constants.bundleID).tcp")
    private var reconnectDelay: TimeInterval = 1.0
    private var shouldReconnect = true

    /// Called on the main queue when the layer changes.
    var onLayerChange: ((String) -> Void)?

    /// Called on the main queue when connection state changes.
    var onConnectionChange: ((Bool) -> Void)?

    init(host: String = Constants.defaultHost, port: UInt16 = Constants.defaultPort) {
        self.host = host
        self.port = port
    }

    func start() {
        shouldReconnect = true
        connect()
    }

    func stop() {
        shouldReconnect = false
        connection?.cancel()
        connection = nil
    }

    func sendReload() {
        guard let conn = connection, conn.state == .ready else { return }
        let message = "{\"Reload\":{}}\n"
        let data = message.data(using: .utf8)!
        conn.send(content: data, completion: .contentProcessed { error in
            if let error {
                print("reload send error: \(error)")
            }
        })
    }

    private func connect() {
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.reconnectDelay = 1.0
                DispatchQueue.main.async { self.onConnectionChange?(true) }
                self.readLine(from: conn)

            case .failed, .cancelled:
                DispatchQueue.main.async { self.onConnectionChange?(false) }
                self.scheduleReconnect()

            case .waiting:
                // Port not listening yet — cancel and retry
                conn.cancel()

            default:
                break
            }
        }

        conn.start(queue: queue)
        connection = conn
    }

    private func readLine(from conn: NWConnection) {
        // Read until newline (kanata sends newline-delimited JSON)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                // May receive multiple lines in one read
                if let text = String(data: data, encoding: .utf8) {
                    for line in text.split(separator: "\n") {
                        self.parseLine(String(line))
                    }
                }
            }

            if isComplete || error != nil {
                conn.cancel()
                return
            }

            // Continue reading
            self.readLine(from: conn)
        }
    }

    private func parseLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let layerChange = json["LayerChange"] as? [String: Any],
              let newLayer = layerChange["new"] as? String
        else { return }

        DispatchQueue.main.async {
            self.onLayerChange?(newLayer)
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }

        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 10.0) // exponential backoff, max 10s

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.shouldReconnect else { return }
            self.connect()
        }
    }
}

import Foundation
import Network
import Shared

/// Connects to kanata's TCP server and reports layer changes.
@MainActor
class KanataClient {
    private var connection: NWConnection?
    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "\(Constants.bundleID).tcp")
    private var reconnectDelay: TimeInterval = Timing.initialReconnectDelay
    private var shouldReconnect = true
    private var reconnectTask: Task<Void, Never>?

    var onLayerChange: ((String) -> Void)?
    var onConfigReload: (() -> Void)?
    var onHoldActivated: ((String) -> Void)?
    var onTapActivated: ((String) -> Void)?
    /// `(ok, timedOut)` for a reload sent with `wait: true`.
    var onReloadResult: ((Bool, Bool) -> Void)?
    var onError: ((String) -> Void)?
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
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.cancel()
        connection = nil
    }

    /// Asks kanata to reload its config. With `wait`, kanata answers with a
    /// `ReloadResult` once the reload completes (or times out, 5 s by default).
    func sendReload(wait: Bool = false) {
        guard let conn = connection, conn.state == .ready else { return }
        let message = wait ? "{\"Reload\":{\"wait\":true}}\n" : "{\"Reload\":{}}\n"
        let data = message.data(using: .utf8)!
        conn.send(content: data, completion: .contentProcessed { error in
            if let error {
                print("reload send error: \(error)")
            }
        })
    }

    private func connect() {
        connection?.cancel()
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleState(state, conn: conn)
            }
        }

        conn.start(queue: queue)
        connection = conn
    }

    private func handleState(_ state: NWConnection.State, conn: NWConnection) {
        // A connection we cancelled in connect()/stop() still delivers its
        // terminal state — reacting to it would schedule a phantom reconnect.
        guard conn === connection else { return }
        switch state {
        case .ready:
            reconnectDelay = Timing.initialReconnectDelay
            onConnectionChange?(true)
            readLine(from: conn)

        case .failed, .cancelled:
            onConnectionChange?(false)
            scheduleReconnect()

        case .waiting:
            // Port not listening yet — cancel and retry
            conn.cancel()

        default:
            break
        }
    }

    private func readLine(from conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: Timing.tcpBufferSize) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let data, !data.isEmpty,
                   let text = String(data: data, encoding: .utf8) {
                    for line in text.split(separator: "\n") {
                        self.parseLine(String(line))
                    }
                }

                if isComplete || error != nil {
                    conn.cancel()
                    return
                }

                self.readLine(from: conn)
            }
        }
    }

    private func parseLine(_ line: String) {
        guard let event = KanataEvent.parse(line) else { return }
        switch event {
        case .layerChange(let layer):
            onLayerChange?(layer)
        case .configReload:
            onConfigReload?()
        case .holdActivated(let key):
            onHoldActivated?(key)
        case .tapActivated(let key):
            onTapActivated?(key)
        case .reloadResult(let ok, let timedOut):
            onReloadResult?(ok, timedOut)
        case .error(let msg):
            onError?(msg)
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        reconnectTask?.cancel()

        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, Timing.maxReconnectDelay)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }
}

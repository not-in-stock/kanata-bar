import XCTest
@testable import KanataBarLib

/// A minimal TCP server using POSIX sockets for testing KanataClient.
private final class MockTCPServer {
    private var serverFD: Int32 = -1
    private var clientFDs: [Int32] = []
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "MockTCPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // let OS pick
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let addrSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, addrSize) }
        }
        guard bindResult == 0 else {
            close(fd)
            throw NSError(domain: "MockTCPServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "bind() failed: \(errno)"])
        }

        guard listen(fd, 5) == 0 else {
            close(fd)
            throw NSError(domain: "MockTCPServer", code: 3, userInfo: [NSLocalizedDescriptionKey: "listen() failed"])
        }

        // Get assigned port
        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &addrLen) }
        }

        self.serverFD = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)

        // Non-blocking accept
        fcntl(fd, F_SETFL, O_NONBLOCK)
    }

    /// Accept pending connections (call from RunLoop).
    func acceptPending() {
        while true {
            let fd = accept(serverFD, nil, nil)
            if fd < 0 { break }
            clientFDs.append(fd)
        }
    }

    func send(_ string: String) {
        acceptPending()
        let data = Array(string.utf8)
        for fd in clientFDs {
            _ = Darwin.send(fd, data, data.count, 0)
        }
    }

    /// Read data sent by the client.
    func receive(timeout: TimeInterval = 1.0) -> String? {
        acceptPending()
        var buf = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        for fd in clientFDs {
            fcntl(fd, F_SETFL, O_NONBLOCK)
            while Date() < deadline {
                let n = recv(fd, &buf, buf.count, 0)
                if n > 0 { return String(bytes: buf[..<n], encoding: .utf8) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }
        return nil
    }

    func closeClients() {
        for fd in clientFDs {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        clientFDs.removeAll()
    }

    func stop() {
        closeClients()
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
    }

    deinit { stop() }
}

// MARK: - Helpers

/// Spins the main RunLoop until `condition` returns true or `timeout` expires.
private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

@MainActor
final class KanataClientTests: XCTestCase {

    // MARK: - Connection

    func testConnectsAndReportsConnected() throws {
        let server = try MockTCPServer()
        defer { server.stop() }

        let client = KanataClient(port: server.port)
        var connected: Bool?
        client.onConnectionChange = { connected = $0 }
        client.start()
        defer { client.stop() }

        waitUntil { connected == true }
        XCTAssertEqual(connected, true)
    }

    func testReportsDisconnectedOnServerClose() throws {
        let server = try MockTCPServer()
        defer { server.stop() }

        let client = KanataClient(port: server.port)
        var states: [Bool] = []
        client.onConnectionChange = { states.append($0) }
        client.start()
        defer { client.stop() }

        waitUntil { states.contains(true) }
        // Send data first to ensure receive loop is active, then close
        server.send("\n")
        server.closeClients()
        waitUntil(timeout: 5.0) { states.contains(false) }

        XCTAssertTrue(states.contains(true))
        XCTAssertTrue(states.contains(false))
    }

    // MARK: - Layer Changes

    func testLayerChangeCallback() throws {
        let server = try MockTCPServer()
        defer { server.stop() }

        let client = KanataClient(port: server.port)
        var connected = false
        var layer: String?
        client.onConnectionChange = { connected = $0 }
        client.onLayerChange = { layer = $0 }
        client.start()
        defer { client.stop() }

        waitUntil { connected }
        server.send(#"{"LayerChange":{"new":"nav"}}"# + "\n")
        waitUntil { layer != nil }

        XCTAssertEqual(layer, "nav")
    }

    func testMultipleLayerChanges() throws {
        let server = try MockTCPServer()
        defer { server.stop() }

        let client = KanataClient(port: server.port)
        var connected = false
        var layers: [String] = []
        client.onConnectionChange = { connected = $0 }
        client.onLayerChange = { layers.append($0) }
        client.start()
        defer { client.stop() }

        waitUntil { connected }
        server.send(#"{"LayerChange":{"new":"nav"}}"# + "\n")
        waitUntil { layers.count >= 1 }
        server.send(#"{"LayerChange":{"new":"sym"}}"# + "\n")
        waitUntil { layers.count >= 2 }

        XCTAssertEqual(layers, ["nav", "sym"])
    }

    func testMultipleEventsInOneTCPPacket() throws {
        let server = try MockTCPServer()
        defer { server.stop() }

        let client = KanataClient(port: server.port)
        var connected = false
        var layers: [String] = []
        client.onConnectionChange = { connected = $0 }
        client.onLayerChange = { layers.append($0) }
        client.start()
        defer { client.stop() }

        waitUntil { connected }
        let batch = #"{"LayerChange":{"new":"a"}}"# + "\n"
            + #"{"LayerChange":{"new":"b"}}"# + "\n"
        server.send(batch)
        waitUntil { layers.count >= 2 }

        XCTAssertEqual(layers, ["a", "b"])
    }

    // MARK: - Config Reload

    func testConfigReloadCallback() throws {
        let server = try MockTCPServer()
        defer { server.stop() }

        let client = KanataClient(port: server.port)
        var connected = false
        var reloaded = false
        client.onConnectionChange = { connected = $0 }
        client.onConfigReload = { reloaded = true }
        client.start()
        defer { client.stop() }

        waitUntil { connected }
        server.send(#"{"ConfigFileReload":{}}"# + "\n")
        waitUntil { reloaded }

        XCTAssertTrue(reloaded)
    }

    // MARK: - Send Reload

    func testSendReload() throws {
        let server = try MockTCPServer()
        defer { server.stop() }

        let client = KanataClient(port: server.port)
        var connected = false
        client.onConnectionChange = { connected = $0 }
        client.start()
        defer { client.stop() }

        waitUntil { connected }
        client.sendReload()

        let received = server.receive()
        XCTAssertEqual(received, "{\"Reload\":{}}\n")
    }

    // MARK: - Reconnect

    func testReconnectsAfterServerClose() throws {
        let server = try MockTCPServer()
        defer { server.stop() }

        let client = KanataClient(port: server.port)
        var connectCount = 0
        client.onConnectionChange = { if $0 { connectCount += 1 } }
        client.start()
        defer { client.stop() }

        waitUntil { connectCount == 1 }
        server.send("\n")
        server.closeClients()
        // Client should reconnect (1s initial delay + detect time)
        waitUntil(timeout: 5.0) { connectCount == 2 }

        XCTAssertEqual(connectCount, 2)
    }

    // MARK: - Stop

    func testStopPreventsReconnect() throws {
        let server = try MockTCPServer()
        defer { server.stop() }

        let client = KanataClient(port: server.port)
        var connected = false
        client.onConnectionChange = { connected = $0 }
        client.start()

        waitUntil { connected }
        client.stop()
        server.closeClients()

        // Wait a bit — should NOT reconnect
        var reconnected = false
        client.onConnectionChange = { if $0 { reconnected = true } }
        waitUntil(timeout: 1.5) { reconnected }

        XCTAssertFalse(reconnected)
    }

    // MARK: - Unknown Events

    func testUnknownEventIgnored() throws {
        let server = try MockTCPServer()
        defer { server.stop() }

        let client = KanataClient(port: server.port)
        var connected = false
        var layer: String?
        client.onConnectionChange = { connected = $0 }
        client.onLayerChange = { layer = $0 }
        client.start()
        defer { client.stop() }

        waitUntil { connected }
        server.send(#"{"FakeEvent":{}}"# + "\n")
        server.send(#"{"LayerChange":{"new":"after"}}"# + "\n")
        waitUntil { layer != nil }

        XCTAssertEqual(layer, "after")
    }
}

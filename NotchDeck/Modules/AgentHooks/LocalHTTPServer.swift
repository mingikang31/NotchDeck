import Foundation
import Network

/// A parsed HTTP/1.1 request (just what the hook endpoints need).
nonisolated struct HTTPRequest: Equatable, Sendable {
    var method: String
    var path: String
    /// Lower-cased header names.
    var headers: [String: String]
    var body: Data

    enum ParseResult: Equatable {
        case incomplete
        case complete(HTTPRequest)
        case invalid(String)
    }

    static let maxBodyBytes = 8 * 1024 * 1024 // Write tool payloads can carry whole files

    /// Parses `buffer` if it holds a full request (headers + Content-Length body).
    static func parse(_ buffer: Data) -> ParseResult {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 64 * 1024 ? .invalid("Headers too large") : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid("Headers aren't UTF-8")
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid("Bad request line") }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid("Bad Content-Length") }
        guard length <= maxBodyBytes else { return .invalid("Body too large") }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .incomplete }
        let body = buffer[bodyStart..<(bodyStart + length)]
        return .complete(HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: String(requestLine[1]),
            headers: headers,
            body: Data(body)
        ))
    }
}

nonisolated struct HTTPResponse: Sendable {
    var status: Int
    var body: Data

    static func json(_ object: [String: Any], status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    /// 200 with an empty body: for a Claude Code hook this means "no decision".
    static let empty = HTTPResponse(status: 200, body: Data())

    func serialized() -> Data {
        let reason = switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 413: "Payload Too Large"
        default: "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// One in-flight request. The handler must call `respond` exactly once (later calls are ignored);
/// `onCancel` fires if the client hangs up first (e.g. the user answered in the terminal).
nonisolated final class HTTPExchange: @unchecked Sendable {
    let request: HTTPRequest
    private let connection: NWConnection
    private let lock = NSLock()
    private var answered = false
    private var clientGone = false
    private var cancelHandlers: [@Sendable () -> Void] = []

    init(request: HTTPRequest, connection: NWConnection) {
        self.request = request
        self.connection = connection
    }

    func respond(_ response: HTTPResponse) {
        lock.lock()
        guard !answered, !clientGone else { lock.unlock(); return }
        answered = true
        lock.unlock()
        connection.send(content: response.serialized(), completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    /// Runs `handler` if the client disconnects before we answer, immediately if it already has.
    func onCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if answered { lock.unlock(); return }
        if clientGone { lock.unlock(); handler(); return }
        cancelHandlers.append(handler)
        lock.unlock()
    }

    /// Called when the peer disconnects before we answered.
    func clientWentAway() {
        lock.lock()
        guard !answered, !clientGone else { lock.unlock(); return }
        clientGone = true
        let handlers = cancelHandlers
        cancelHandlers = []
        lock.unlock()
        connection.cancel()
        handlers.forEach { $0() }
    }
}

/// Minimal HTTP/1.1 server bound to the loopback interface only (never reachable from the network).
nonisolated final class LocalHTTPServer: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case stopped
        case running(port: UInt16)
        case failed(String)
    }

    private let queue = DispatchQueue(label: "com.notchdeck.hookserver")
    private var listener: NWListener?
    private let handler: @Sendable (HTTPExchange) -> Void
    private let stateChanged: @Sendable (State) -> Void

    init(handler: @escaping @Sendable (HTTPExchange) -> Void, stateChanged: @escaping @Sendable (State) -> Void = { _ in }) {
        self.handler = handler
        self.stateChanged = stateChanged
    }

    func start(port: UInt16) {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                stateChanged(.failed("Invalid port \(port)"))
                return
            }
            let parameters = NWParameters.tcp
            // Bind to 127.0.0.1 only: other machines can't connect, whatever the firewall says.
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            parameters.allowLocalEndpointReuse = true
            do {
                let listener = try NWListener(using: parameters)
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready: self?.stateChanged(.running(port: port))
                    case .failed(let error): self?.stateChanged(.failed(Self.describe(error, port: port)))
                    case .cancelled: self?.stateChanged(.stopped)
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                stateChanged(.failed(Self.describe(error, port: port)))
            }
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
        }
    }

    private static func describe(_ error: Error, port: UInt16) -> String {
        if case NWError.posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is already in use by another app. Choose another port."
        }
        return error.localizedDescription
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                let exchange = HTTPExchange(request: request, connection: connection)
                self.watchForHangUp(connection, exchange: exchange)
                self.handler(exchange)
            case .invalid(let reason):
                HTTPExchange(request: HTTPRequest(method: "", path: "", headers: [:], body: Data()), connection: connection)
                    .respond(.json(["error": reason], status: reason.contains("large") ? 413 : 400))
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    /// The client (Claude Code) keeps the request open while waiting; if it closes the connection
    /// (it timed out, or the user answered in the terminal), drop the pending approval.
    private func watchForHangUp(_ connection: NWConnection, exchange: HTTPExchange) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: exchange.clientWentAway()
            default: break
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
            if isComplete || error != nil { exchange.clientWentAway() }
        }
    }
}

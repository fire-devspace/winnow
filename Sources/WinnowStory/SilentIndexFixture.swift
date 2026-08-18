import Foundation
import Network

/// The run-local implementation of Winnow's documented
/// `GET /tweaks/{height}` contract. It serves only public 33-byte tweak points
/// from the protected run file; no wallet key, script, or address is accepted.
public final class SilentIndexFixture: @unchecked Sendable {
    public enum FixtureError: LocalizedError {
        case invalidPort
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidPort: "Invalid silent-index port."
            case let .failed(reason): "Silent-index fixture failed: \(reason)"
            }
        }
    }

    private let tweaksURL: URL
    private let queue = DispatchQueue(label: "org.winnow.story.silent-index")
    private var listener: NWListener?

    public init(tweaksURL: URL) { self.tweaksURL = tweaksURL }

    public func start(port: UInt16) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw FixtureError.invalidPort }
        let listener = try NWListener(using: .tcp, on: nwPort)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: FixtureError.failed(error.localizedDescription))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() { listener?.cancel() }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let firstLine = request.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            let components = firstLine.split(separator: " ")
            let path = components.count >= 2 ? String(components[1]) : ""
            let response = self.response(path: path)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    public func response(path: String) -> Data {
        guard path.hasPrefix("/tweaks/"),
              let height = UInt32(path.dropFirst("/tweaks/".count)) else {
            return http(status: "404 Not Found", body: Data("[]".utf8))
        }
        let all: [String: [String]]
        if let data = try? Data(contentsOf: tweaksURL),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            all = decoded
        } else {
            all = [:]
        }
        let body = (try? JSONEncoder().encode(all[String(height)] ?? [])) ?? Data("[]".utf8)
        return http(status: "200 OK", body: body)
    }

    private func http(status: String, body: Data) -> Data {
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        return response
    }
}

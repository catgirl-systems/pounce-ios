import Foundation

/// binary as unpadded base64url, the only form pounce-sync accepts.
struct B64: Codable, Hashable, Sendable {
    var data: Data

    init(_ data: Data) { self.data = data }

    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let data = Data(base64URL: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "base64url"))
        }
        self.data = data
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(data.base64URL)
    }
}

struct WireKey: Codable, Sendable {
    var recipientID: B64
    var epoch: UInt32
    var blob: B64
    var signerID: B64
    var sig: B64
}

struct WireRecord: Codable, Sendable {
    var id: B64
    var rev: UInt64
    var seq: UInt64
    var blob: B64?
}

struct WireEntry: Codable, Sendable {
    var entry: B64
    var sig: B64
}

/// pounce-sync's http api. https only, except loopback so a local server can be
/// tried from a mac.
struct SyncAPI: Sendable {
    let origin: URL
    let session: URLSession

    init(origin: URL, session: URLSession = .shared) throws(SyncError) {
        guard let scheme = origin.scheme?.lowercased(), let host = origin.host(), origin.path().isEmpty,
            scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host))
        else { throw .badServerURL }
        self.origin = origin
        self.session = session
    }

    /// the origin exactly as the server binds it into login signatures.
    var originText: String {
        var text = "\(origin.scheme?.lowercased() ?? "https")://\(origin.host() ?? "")"
        if let port = origin.port { text += ":\(port)" }
        return text
    }

    private struct Empty: Codable {}

    private struct ErrorBody: Decodable {
        var error: String
    }

    private func send(
        _ method: String, _ path: String, token: String? = nil, headers: [String: String] = [:], body: Data? = nil,
        timeout: TimeInterval = 30
    ) async throws(SyncError) -> (Int, Data) {
        guard let url = URL(string: originText + path) else { throw .badServerURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SyncError.malformed }
            return (http.statusCode, data)
        } catch let error as SyncError {
            throw error
        } catch is CancellationError {
            throw .network("cancelled")
        } catch {
            throw .network(error.localizedDescription)
        }
    }

    /// expects one of `ok` statuses, otherwise turns the reply into `.server`.
    private func call<Reply: Decodable>(
        _ method: String, _ path: String, token: String? = nil, headers: [String: String] = [:],
        body: (some Encodable)? = Empty?.none, ok: Set<Int> = [200], timeout: TimeInterval = 30,
        as: Reply.Type = Reply.self
    ) async throws(SyncError) -> (Int, Reply?) {
        var payload: Data?
        if let body {
            do { payload = try JSONEncoder().encode(body) } catch { throw .malformed }
        }
        let (status, data) = try await send(
            method, path, token: token, headers: headers, body: payload, timeout: timeout)
        guard ok.contains(status) else { throw failure(status, data) }
        if status == 204 || Reply.self == Empty.self { return (status, nil) }
        do { return (status, try JSONDecoder().decode(Reply.self, from: data)) } catch { throw .malformed }
    }

    private func failure(_ status: Int, _ data: Data) -> SyncError {
        .server(status: status, code: (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "unknown")
    }

    // MARK: accounts and sessions

    func createAccount(id: Data, invite: Data?, entry: Data, sig: Data, keys: [WireKey]) async throws(SyncError) {
        struct Body: Encodable {
            var accountID: B64
            var invite: B64?
            var entry: B64
            var sig: B64
            var keys: [WireKey]
        }
        _ = try await call(
            "POST", "/v1/accounts",
            body: Body(accountID: B64(id), invite: invite.map(B64.init), entry: B64(entry), sig: B64(sig), keys: keys),
            ok: [201], as: Empty.self)
    }

    func challenge(account: Data, device: Data) async throws(SyncError) -> Data {
        struct Body: Encodable { var accountID, deviceID: B64 }
        struct Reply: Decodable { var nonce: B64 }
        let (_, reply) = try await call(
            "POST", "/v1/auth/challenge", body: Body(accountID: B64(account), deviceID: B64(device)), as: Reply.self)
        guard let reply else { throw .malformed }
        return reply.nonce.data
    }

    func login(account: Data, device: Data, nonce: Data, sig: Data) async throws(SyncError) -> String {
        struct Body: Encodable { var accountID, deviceID, nonce, sig: B64 }
        struct Reply: Decodable { var token: B64 }
        let (_, reply) = try await call(
            "POST", "/v1/auth/session",
            body: Body(accountID: B64(account), deviceID: B64(device), nonce: B64(nonce), sig: B64(sig)),
            as: Reply.self)
        guard let reply else { throw .malformed }
        return reply.token.data.base64URL
    }

    func deleteAccount(token: String, sig: Data) async throws(SyncError) {
        struct Body: Encodable { var sig: B64 }
        _ = try await call("DELETE", "/v1/account", token: token, body: Body(sig: B64(sig)), ok: [204], as: Empty.self)
    }

    // MARK: roster and keys

    func roster(token: String, from: UInt64) async throws(SyncError) -> (head: UInt64, entries: [WireEntry]) {
        struct Reply: Decodable {
            struct Item: Decodable {
                var index: UInt64
                var entry: B64
                var sig: B64
            }
            var entries: [Item]
            var head: UInt64
        }
        let (_, reply) = try await call("GET", "/v1/roster?from=\(from)", token: token, as: Reply.self)
        guard let reply else { throw .malformed }
        for (offset, item) in reply.entries.enumerated() where item.index != from + UInt64(offset) {
            throw .rosterInvalid
        }
        return (reply.head, reply.entries.map { WireEntry(entry: $0.entry, sig: $0.sig) })
    }

    /// nil when `head` is stale: someone else appended first.
    func appendRoster(token: String, head: UInt64, entries: [WireEntry], keys: [WireKey])
        async throws(SyncError) -> UInt64?
    {
        struct Body: Encodable {
            var entries: [WireEntry]
            var keys: [WireKey]
        }
        struct Reply: Decodable { var head: UInt64 }
        let (status, reply) = try await call(
            "POST", "/v1/roster", token: token, headers: ["If-Match": "\"\(head)\""],
            body: Body(entries: entries, keys: keys), ok: [200, 412], as: Reply.self)
        return status == 412 ? nil : reply?.head
    }

    /// nil when no key was wrapped for this device at that epoch.
    func key(token: String, epoch: UInt32) async throws(SyncError) -> WireKey? {
        do {
            let (_, reply) = try await call("GET", "/v1/keys/\(epoch)", token: token, as: WireKey.self)
            return reply
        } catch .server(status: 404, _) {
            return nil
        }
    }

    // MARK: records

    func changes(token: String, since: UInt64, limit: Int = 500, wait: Int = 0)
        async throws(SyncError) -> (records: [WireRecord], more: Bool, next: UInt64)
    {
        struct Reply: Decodable {
            var changes: [WireRecord]
            var more: Bool
            var nextSince: UInt64
        }
        let (_, reply) = try await call(
            "GET", "/v1/changes?since=\(since)&limit=\(limit)&wait=\(wait)", token: token,
            timeout: TimeInterval(wait + 30), as: Reply.self)
        guard let reply else { throw .malformed }
        return (reply.changes, reply.more, reply.nextSince)
    }

    struct Write: Encodable {
        var id: B64
        var ifMatch: UInt64
        var blob: B64
    }

    enum BatchResult {
        case written([WireRecord])
        /// the writes whose revision was stale, with the record as it is now.
        case stale([(id: Data, current: WireRecord?)])
    }

    func batch(token: String, writes: [Write]) async throws(SyncError) -> BatchResult {
        struct Body: Encodable { var writes: [Write] }
        guard let body = try? JSONEncoder().encode(Body(writes: writes)) else { throw .malformed }
        let (status, data) = try await send("POST", "/v1/batch", token: token, body: body, timeout: 60)
        do {
            switch status {
            case 200:
                struct Reply: Decodable { var results: [WireRecord] }
                return .written(try JSONDecoder().decode(Reply.self, from: data).results)
            case 412:
                struct Reply: Decodable {
                    struct Failure: Decodable {
                        var id: B64
                        var current: WireRecord?
                    }
                    var failed: [Failure]
                }
                return .stale(try JSONDecoder().decode(Reply.self, from: data).failed.map { ($0.id.data, $0.current) })
            default:
                throw failure(status, data)
            }
        } catch let error as SyncError {
            throw error
        } catch {
            throw .malformed
        }
    }

    // MARK: pairing

    func createPairing(token: String, authTokenHash: Data) async throws(SyncError) -> Data {
        struct Body: Encodable { var authTokenHash: B64 }
        struct Reply: Decodable { var pairingID: B64 }
        let (_, reply) = try await call(
            "POST", "/v1/pairing", token: token, body: Body(authTokenHash: B64(authTokenHash)), ok: [201],
            as: Reply.self)
        guard let reply else { throw .malformed }
        return reply.pairingID.data
    }

    func joinPairing(id: Data, authToken: Data, payload: Data) async throws(SyncError) {
        struct Body: Encodable { var authToken, payload: B64 }
        _ = try await call(
            "POST", "/v1/pairing/\(id.base64URL)/join", body: Body(authToken: B64(authToken), payload: B64(payload)),
            ok: [204], as: Empty.self)
    }

    func pairingPayload(token: String, id: Data) async throws(SyncError) -> Data? {
        struct Reply: Decodable { var payload: B64 }
        let (_, reply) = try await call(
            "GET", "/v1/pairing/\(id.base64URL)", token: token, ok: [200, 204], as: Reply.self)
        return reply?.payload.data
    }

    func pairingNonce(token: String, id: Data, nonce: Data, sig: Data) async throws(SyncError) {
        struct Body: Encodable { var nonce, sig: B64 }
        _ = try await call(
            "POST", "/v1/pairing/\(id.base64URL)/nonce", token: token, body: Body(nonce: B64(nonce), sig: B64(sig)),
            ok: [204], as: Empty.self)
    }

    func pollPairing(id: Data, authToken: Data) async throws(SyncError) -> (nonce: Data, sig: Data, signer: Data)? {
        struct Body: Encodable { var authToken: B64 }
        struct Reply: Decodable { var nonce, sig, signerID: B64 }
        let (_, reply) = try await call(
            "POST", "/v1/pairing/\(id.base64URL)/poll", body: Body(authToken: B64(authToken)), ok: [200, 204],
            as: Reply.self)
        return reply.map { ($0.nonce.data, $0.sig.data, $0.signerID.data) }
    }
}

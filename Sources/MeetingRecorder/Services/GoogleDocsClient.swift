import Foundation
import AppKit
import CryptoKit
import Network
import os.log

/// Saves meeting notes as Google Docs in a "Meeting Notes" Drive folder.
///
/// Sign-in: OAuth 2.0 for desktop apps — system browser + loopback redirect
/// (http://127.0.0.1:<port>) + PKCE. Scope is `drive.file` only: the app can see
/// just the files it created, and Google needs no app review for it.
/// The doc is made by uploading the same Markdown the other destinations use;
/// Drive converts it to a real Google Doc (headings, bullets, checkboxes).
final class GoogleDocsClient: @unchecked Sendable {
    private let logger = Logger(subsystem: "MeetingRecorder", category: "GoogleDocsClient")
    static let scope = "https://www.googleapis.com/auth/drive.file"
    private static let folderName = "Meeting Notes"

    /// Injected into Info.plist by scripts/package.sh from signing/google-oauth.json.
    private let clientID = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String ?? ""
    private let clientSecret = Bundle.main.object(forInfoDictionaryKey: "GoogleClientSecret") as? String ?? ""
    /// False in builds made without the OAuth file (e.g. a plain `swift build`).
    var isAvailable: Bool { !clientID.isEmpty }

    var refreshToken = ""
    var folderID = ""
    /// Called when a new folder is created so the caller can persist its ID.
    var onFolderCreated: ((String) -> Void)?

    private let tokenLock = NSLock()
    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast

    enum GoogleError: LocalizedError {
        case notConfigured, cancelled, timedOut, http(Int, String), invalidResponse
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Google sign-in isn't set up in this build."
            case .cancelled: return "Google sign-in was cancelled."
            case .timedOut: return "Google sign-in timed out. Try Connect Google again."
            case .http(let code, let body): return "Google error \(code): \(body.prefix(200))"
            case .invalidResponse: return "Unexpected response from Google."
            }
        }
    }

    // MARK: - Sign-in

    /// Opens Google sign-in in the browser and returns a refresh token.
    func signIn() async throws -> String {
        guard isAvailable else { throw GoogleError.notConfigured }
        let verifier = Self.randomURLSafe(bytes: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(bytes: 16)

        let receiver = LoopbackReceiver(expectedState: state)
        let port = try await receiver.start()
        defer { receiver.stop() }
        let redirectURI = "http://127.0.0.1:\(port)"

        var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        auth.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"), // → refresh token
            .init(name: "prompt", value: "consent"),      // always return one, even on reconnect
        ]
        await MainActor.run { _ = NSWorkspace.shared.open(auth.url!) }

        let code = try await receiver.waitForCode(timeout: 300)
        let tokens = try await tokenRequest([
            "code": code, "code_verifier": verifier, "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ])
        guard let refresh = tokens["refresh_token"] as? String else { throw GoogleError.invalidResponse }
        storeAccessToken(tokens)
        logger.info("Google connected")
        return refresh
    }

    /// Best-effort revoke so the app disappears from the user's Google account.
    func revoke(_ token: String) {
        guard !token.isEmpty else { return }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(["token": token])
        URLSession.shared.dataTask(with: request).resume()
        tokenLock.withLock { accessToken = nil; accessTokenExpiry = .distantPast }
    }

    // MARK: - Create the doc

    /// Uploads `markdown` as a new Google Doc and returns its web link.
    func createDoc(title: String, markdown: String) async throws -> URL {
        let token = try await validAccessToken()
        do {
            return try await upload(title: title, markdown: markdown, token: token, folder: try await ensureFolder(token: token))
        } catch GoogleError.http(404, _) where !folderID.isEmpty {
            // The folder was deleted in Drive: forget it, make a new one, retry once.
            folderID = ""
            return try await upload(title: title, markdown: markdown, token: token, folder: try await ensureFolder(token: token))
        }
    }

    private func ensureFolder(token: String) async throws -> String {
        if !folderID.isEmpty { return folderID }
        // Reuse the app's existing folder (after a reconnect/reinstall) instead of making
        // a duplicate. drive.file only lists files this app created, so this finds ours.
        var search = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        search.queryItems = [
            .init(name: "q", value: "name = '\(Self.folderName)' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"),
            .init(name: "fields", value: "files(id)"),
            .init(name: "pageSize", value: "1"),
        ]
        var lookup = URLRequest(url: search.url!)
        lookup.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let existing = ((try? await send(lookup))?["files"] as? [[String: Any]])?.first?["id"] as? String {
            folderID = existing
            onFolderCreated?(existing)
            return existing
        }
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": Self.folderName, "mimeType": "application/vnd.google-apps.folder",
        ])
        let json = try await send(request)
        guard let id = json["id"] as? String else { throw GoogleError.invalidResponse }
        folderID = id
        onFolderCreated?(id)
        return id
    }

    private func upload(title: String, markdown: String, token: String, folder: String) async throws -> URL {
        let boundary = "mt-\(UUID().uuidString)"
        let metadata = try JSONSerialization.data(withJSONObject: [
            "name": title, "parents": [folder],
            "mimeType": "application/vnd.google-apps.document", // convert on import
        ])
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadata)
        body.append("\r\n--\(boundary)\r\nContent-Type: text/markdown; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(markdown.data(using: .utf8)!)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,webViewLink")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let json = try await send(request)
        guard let link = (json["webViewLink"] as? String).flatMap(URL.init(string:)) else { throw GoogleError.invalidResponse }
        logger.info("Google Doc created")
        return link
    }

    // MARK: - Tokens

    private func validAccessToken() async throws -> String {
        if let cached = tokenLock.withLock({ accessTokenExpiry > Date().addingTimeInterval(60) ? accessToken : nil }) {
            return cached
        }
        guard !refreshToken.isEmpty else { throw GoogleError.notConfigured }
        let tokens = try await tokenRequest(["refresh_token": refreshToken, "grant_type": "refresh_token"])
        guard let token = storeAccessToken(tokens) else { throw GoogleError.invalidResponse }
        return token
    }

    @discardableResult
    private func storeAccessToken(_ tokens: [String: Any]) -> String? {
        guard let token = tokens["access_token"] as? String else { return nil }
        let lifetime = (tokens["expires_in"] as? Double) ?? 3600
        tokenLock.withLock {
            accessToken = token
            accessTokenExpiry = Date().addingTimeInterval(lifetime)
        }
        return token
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(fields.merging(["client_id": clientID, "client_secret": clientSecret]) { a, _ in a })
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(decoding: data, as: UTF8.self)
            logger.error("Google HTTP \(http.statusCode, privacy: .public): \(text.prefix(300), privacy: .public)")
            throw GoogleError.http(http.statusCode, text)
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Helpers

    private static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").data(using: .utf8)!
    }

    static func randomURLSafe(bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URLEncoded
    }
}

extension Data {
    /// RFC 4648 §5, no padding — what PKCE and OAuth state expect.
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One-shot HTTP listener on 127.0.0.1 that catches Google's redirect
/// (`GET /?code=…&state=…`), answers with a "you can close this tab" page,
/// and hands back the code.
private final class LoopbackReceiver: @unchecked Sendable {
    private let expectedState: String
    private let queue = DispatchQueue(label: "google-oauth-loopback")
    private var listener: NWListener?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var pending: Result<String, Error>?
    private var startResumed = false

    init(expectedState: String) { self.expectedState = expectedState }

    /// Starts listening on a free loopback port and returns it.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            // State updates arrive on `queue`, so `startResumed` needs no lock.
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.startResumed else { return }
                switch state {
                case .ready:
                    self.startResumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    self.startResumed = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForCode(timeout: TimeInterval) async throws -> String {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(GoogleDocsClient.GoogleError.timedOut)) }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let pending = self.pending { continuation.resume(with: pending) } else { self.codeContinuation = continuation }
            }
        }
    }

    func stop() { listener?.cancel(); listener = nil }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            // First line: "GET /?code=…&state=… HTTP/1.1"
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let items = URLComponents(string: "http://127.0.0.1\(target)")?.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value }

            let result: Result<String, Error>?
            if let code = value("code"), value("state") == self.expectedState {
                result = .success(code)
            } else if value("error") != nil {
                result = .failure(GoogleDocsClient.GoogleError.cancelled)
            } else {
                result = nil // e.g. a /favicon.ico request — ignore
            }

            let message = result.map { if case .success = $0 { return "Connected to Google. You can close this tab and go back to Meeting Transcriber." } else { return "Google sign-in was cancelled. You can close this tab." } } ?? ""
            let html = "<!doctype html><meta charset=utf-8><title>Meeting Transcriber</title><body style=\"font:16px -apple-system;padding:48px\">\(message)</body>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
            if let result { self.finish(result) }
        }
    }

    /// Runs on `queue`.
    private func finish(_ result: Result<String, Error>) {
        guard pending == nil else { return }
        pending = result
        codeContinuation?.resume(with: result)
        codeContinuation = nil
    }
}

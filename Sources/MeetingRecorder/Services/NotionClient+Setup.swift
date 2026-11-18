import Foundation

// MARK: - Notion auto-setup: "Meeting Transcription" project + Meetings database inside it
// Separate file so it does not collide with the main NotionClient.
// Uses NotionClient's internal `apiToken` / `databaseID`; re-declares the
// base constants here because they are `private` to NotionClient.swift.

private let notionBaseURL = "https://api.notion.com/v1"
private let notionAPIVersion = "2022-06-28"

// Minimal /search response shape
private struct SearchResponse: Decodable {
    struct RT: Decodable {
        struct T: Decodable { let content: String }
        let type: String
        let text: T?
    }
    struct Result: Decodable {
        let object: String
        let id: String
        let title: [RT]?
    }
    let results: [Result]
}

extension NotionClient {

    // MARK: - Token

    /// Verifies the integration secret is valid (GET /users/me). No database needed.
    func verifyToken() async -> Bool {
        guard !apiToken.isEmpty else { return false }
        var request = URLRequest(url: URL(string: "\(notionBaseURL)/users/me")!)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue(notionAPIVersion, forHTTPHeaderField: "Notion-Version")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    /// Throwing variant for Connect, so the UI can tell a bad secret (401)
    /// apart from being offline (URLError) or another API error.
    private func requireValidToken() async throws {
        guard !apiToken.isEmpty else { throw NotionError.unauthorized }
        var request = URLRequest(url: URL(string: "\(notionBaseURL)/users/me")!)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue(notionAPIVersion, forHTTPHeaderField: "Notion-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NotionError.invalidResponse }
        if http.statusCode == 401 { throw NotionError.unauthorized }
        if http.statusCode != 200 {
            throw NotionError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "Unknown error")
        }
    }

    // MARK: - Project page ("Meeting Transcription")

    /// Searches for an existing top-level page titled "Meeting Transcription".
    /// Fails soft: returns nil on any problem so the caller can just create one.
    private func findProjectPage() async -> String? {
        guard !apiToken.isEmpty else { return nil }
        let body = """
        { "query": "Meeting Transcription",
          "filter": { "property": "object", "value": "page" },
          "page": { "size": 50 } }
        """
        var request = URLRequest(url: URL(string: "\(notionBaseURL)/search")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(notionAPIVersion, forHTTPHeaderField: "Notion-Version")
        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
            for result in decoded.results {
                guard result.object == "page" else { continue }
                let title = result.title?.first(where: { $0.type == "text" })?.text?.content ?? ""
                if title == "Meeting Transcription" { return result.id }
            }
            return nil
        } catch { return nil }
    }

    private func createProjectPage() async throws -> String {
        let body = """
        { "parent": { "type": "workspace", "workspace": true },
          "title": [ { "type": "text", "text": { "content": "Meeting Transcription" } } ] }
        """
        var request = URLRequest(url: URL(string: "\(notionBaseURL)/pages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(notionAPIVersion, forHTTPHeaderField: "Notion-Version")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NotionError.invalidResponse }
        if http.statusCode == 401 { throw NotionError.unauthorized }
        if http.statusCode != 200 {
            let text = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NotionError.apiError(http.statusCode, text)
        }
        struct PageResp: Decodable { let id: String }
        return try JSONDecoder().decode(PageResp.self, from: data).id
    }

    /// Ensures a "Meeting Transcription" project page exists; returns its ID.
    private func ensureProjectPage() async throws -> String {
        if let existing = await findProjectPage() { return existing }
        return try await createProjectPage()
    }

    // MARK: - Meetings database (inside the project)

    private struct BlockChild: Decodable {
        struct DB: Decodable {
            struct RT: Decodable {
                struct T: Decodable { let content: String }
                let type: String
                let text: T?
            }
            let id: String
            let title: [RT]?
        }
        let type: String
        let database: DB?
    }
    private struct ChildrenResponse: Decodable { let results: [BlockChild] }

    /// Ensures a "Meetings" database exists inside the given project page; returns its ID.
    private func ensureMeetingsDatabase(projectPageID: String) async throws -> String {
        // 1) reuse an existing "Meetings" database that is a child of the project
        var childrenRequest = URLRequest(url: URL(string: "\(notionBaseURL)/blocks/\(projectPageID)/children")!)
        childrenRequest.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        childrenRequest.setValue(notionAPIVersion, forHTTPHeaderField: "Notion-Version")
        do {
            let (childrenData, childrenResponse) = try await URLSession.shared.data(for: childrenRequest)
            if (childrenResponse as? HTTPURLResponse)?.statusCode == 200,
               let decoded = try? JSONDecoder().decode(ChildrenResponse.self, from: childrenData) {
                for child in decoded.results where child.type == "child_database" || child.type == "database" {
                    guard let db = child.database else { continue }
                    let title = db.title?.first(where: { $0.type == "text" })?.text?.content ?? ""
                    if title == "Meetings" { return db.id }
                }
            }
        } catch { /* fall through to create */ }

        // 2) create it inside the project
        let body = """
        {
          "parent": { "type": "page_id", "page_id": "\(projectPageID)" },
          "title": [ { "type": "text", "text": { "content": "Meetings" } } ],
          "properties": {
            "title":  { "title": {} },
            "date":   { "date": {} },
            "status": { "select": { "options": [ { "name": "Done" } ] } }
          }
        }
        """
        var createRequest = URLRequest(url: URL(string: "\(notionBaseURL)/databases")!)
        createRequest.httpMethod = "POST"
        createRequest.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createRequest.setValue(notionAPIVersion, forHTTPHeaderField: "Notion-Version")
        createRequest.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: createRequest)
        guard let http = response as? HTTPURLResponse else { throw NotionError.invalidResponse }
        if http.statusCode == 401 { throw NotionError.unauthorized }
        if http.statusCode != 200 {
            let text = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NotionError.apiError(http.statusCode, text)
        }
        struct DBResp: Decodable { let id: String }
        return try JSONDecoder().decode(DBResp.self, from: data).id
    }

    // MARK: - One-tap connect

    /// One-tap connect: verify the secret, ensure the "Meeting Transcription" project
    /// exists, ensure the "Meetings" database lives inside it, and point
    /// `databaseID` at it. Repeat connects never create duplicates.
    @discardableResult
    func connectAndSetup() async throws -> String {
        try await requireValidToken()
        let projectID = try await ensureProjectPage()
        let databaseID = try await ensureMeetingsDatabase(projectPageID: projectID)
        self.databaseID = databaseID
        return databaseID
    }
    // (The "use an existing database" manual path was removed — connect is
    //  one secret + auto setup only.)
}

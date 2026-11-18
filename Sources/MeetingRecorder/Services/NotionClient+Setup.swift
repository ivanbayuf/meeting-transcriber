import Foundation

// MARK: - Setup a Meetings database inside the user's shared page

private let notionBaseURL = "https://api.notion.com/v1"
private let notionAPIVersion = "2022-06-28"

extension NotionClient {
    /// Validates an integration secret, checks access to the selected page, and
    /// creates (or reuses) its Meetings database. Returns a dashless ID.
    @discardableResult
    func connectAndSetup(pageID: String) async throws -> String {
        try await requireValidToken()
        try await requirePageAccess(pageID: pageID)
        let databaseID = try await ensureMeetingsDatabase(pageID: pageID)
        self.databaseID = databaseID.replacingOccurrences(of: "-", with: "")
        return self.databaseID
    }

    private func request(_ path: String, method: String = "GET", body: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(notionBaseURL)\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue(notionAPIVersion, forHTTPHeaderField: "Notion-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body.data(using: .utf8)
        }
        return request
    }

    private func requireValidToken() async throws {
        guard !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotionError.unauthorized
        }
        let (_, response) = try await URLSession.shared.data(for: request("/users/me"))
        guard let http = response as? HTTPURLResponse else { throw NotionError.invalidResponse }
        if http.statusCode == 401 { throw NotionError.unauthorized }
        guard http.statusCode == 200 else { throw NotionError.apiError(http.statusCode, "") }
    }

    private func requirePageAccess(pageID: String) async throws {
        let (data, response) = try await URLSession.shared.data(for: request("/blocks/\(pageID)/children"))
        guard let http = response as? HTTPURLResponse else { throw NotionError.invalidResponse }
        if http.statusCode == 401 { throw NotionError.unauthorized }
        let text = String(data: data, encoding: .utf8) ?? ""
        if http.statusCode == 404 {
            if text.contains("restricted_resource") { throw NotionError.apiError(http.statusCode, text) }
            throw NotionError.databaseNotFound
        }
        guard http.statusCode == 200 else { throw NotionError.apiError(http.statusCode, text) }
    }

    private struct ChildrenResponse: Decodable {
        struct Child: Decodable {
            struct ChildDatabase: Decodable {
                let title: String
            }
            struct Database: Decodable {
                struct RichText: Decodable {
                    struct Text: Decodable { let content: String }
                    let type: String
                    let text: Text?
                }
                let id: String
                let title: [RichText]?
            }
            let type: String
            let id: String
            let database: Database?
            let child_database: ChildDatabase?
        }
        let results: [Child]
    }

    private func ensureMeetingsDatabase(pageID: String) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request("/blocks/\(pageID)/children"))
        guard let http = response as? HTTPURLResponse else { throw NotionError.invalidResponse }
        if http.statusCode == 401 { throw NotionError.unauthorized }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard http.statusCode == 200 else { throw NotionError.apiError(http.statusCode, text) }
        let children = try JSONDecoder().decode(ChildrenResponse.self, from: data)
        for child in children.results where child.type == "child_database" || child.type == "database" {
            if let database = child.database {
                let title = database.title?.first(where: { $0.type == "text" })?.text?.content ?? ""
                if title == "Meetings" { return database.id.replacingOccurrences(of: "-", with: "") }
            } else if child.child_database?.title == "Meetings" {
                return child.id.replacingOccurrences(of: "-", with: "")
            }
        }

        let body = """
        {
          "parent": { "type": "page_id", "page_id": "\(pageID)" },
          "title": [ { "type": "text", "text": { "content": "Meetings" } } ],
          "properties": {
            "title": { "title": {} },
            "date": { "date": {} },
            "status": { "select": { "options": [ { "name": "Done" } ] } }
          }
        }
        """
        let (createdData, createdResponse) = try await URLSession.shared.data(for: request("/databases", method: "POST", body: body))
        guard let createdHTTP = createdResponse as? HTTPURLResponse else { throw NotionError.invalidResponse }
        if createdHTTP.statusCode == 401 { throw NotionError.unauthorized }
        let createdText = String(data: createdData, encoding: .utf8) ?? ""
        guard createdHTTP.statusCode == 200 else { throw NotionError.apiError(createdHTTP.statusCode, createdText) }
        struct DatabaseResponse: Decodable { let id: String }
        return try JSONDecoder().decode(DatabaseResponse.self, from: createdData).id.replacingOccurrences(of: "-", with: "")
    }
}

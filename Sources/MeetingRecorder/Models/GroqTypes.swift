import Foundation

struct GroqChatRequest: Codable {
    let model: String
    let messages: [GroqMessage]
    let temperature: Double
    let maxTokens: Int
    let responseFormat: GroqResponseFormat
    
    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }
}

struct GroqMessage: Codable {
    let role: String
    let content: String
}

struct GroqResponseFormat: Codable {
    let type: String
}

struct GroqChatResponse: Codable {
    let choices: [GroqChoice]
}

struct GroqChoice: Codable {
    let message: GroqMessage
}

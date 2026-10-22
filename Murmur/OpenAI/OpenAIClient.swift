import Foundation

/// Minimal client for the three OpenAI endpoints Murmur uses. Requests go straight from the
/// Mac to api.openai.com — there is no Murmur server in between.
struct OpenAIClient {
    let apiKey: String

    static let baseURL = URL(string: "https://api.openai.com/v1/")!

    /// One shared, ephemeral session: nothing is cached to disk, and the HTTP/2 connection
    /// is reused between requests (see `warmUp`).
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "Murmur/1.0 (macOS)"]
        return URLSession(configuration: configuration)
    }()

    // MARK: Models

    struct ModelInfo: Decodable, Hashable {
        let id: String
        let created: Int?
    }

    func listModels() async throws -> [ModelInfo] {
        struct ListResponse: Decodable { let data: [ModelInfo] }
        let request = makeRequest("models", method: "GET")
        let data = try await send(request)
        return try decode(ListResponse.self, from: data).data
    }

    /// Opens (or keeps alive) the TLS connection while the user is still speaking, so the
    /// upload starts immediately when they finish. Also a cheap API key check.
    func warmUp(model: String) async {
        var request = makeRequest("models/\(model)", method: "GET")
        request.timeoutInterval = 10
        _ = try? await send(request)
    }

    // MARK: Transcription

    struct TranscriptionResponse: Decodable {
        struct Language: Decodable { let code: String }
        struct Usage: Decodable {
            let type: String
            let seconds: Double?
            let input_tokens: Int?
            let output_tokens: Int?
        }
        let text: String
        let languages: [Language]?
        let usage: Usage?
    }

    func transcribe(fileURL: URL, model: String, language: String?, vocabulary: [String], timeout: TimeInterval) async throws -> TranscriptionResponse {
        var form = MultipartForm()
        form.addField("model", model)
        form.addField("response_format", "json")

        let usesHints = model.hasPrefix("gpt-transcribe")
        if let language, !language.isEmpty {
            // gpt-transcribe takes a list of expected languages; older models a single code.
            form.addField(usesHints ? "languages[]" : "language", language)
        }
        if !vocabulary.isEmpty {
            if usesHints {
                for term in vocabulary.prefix(100) { form.addField("keywords[]", term) }
            } else {
                form.addField("prompt", "Vocabulary: " + vocabulary.joined(separator: ", ") + ".")
            }
        }
        let audio = try Data(contentsOf: fileURL)
        form.addFile("file", filename: fileURL.lastPathComponent, mimeType: "audio/mp4", data: audio)

        var request = makeRequest("audio/transcriptions", method: "POST")
        request.timeoutInterval = timeout
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()

        let data = try await send(request)
        return try decode(TranscriptionResponse.self, from: data)
    }

    // MARK: Responses

    struct ResponseResult: Decodable {
        struct OutputItem: Decodable {
            struct Content: Decodable {
                let type: String
                let text: String?
            }
            let type: String
            let content: [Content]?
        }
        struct Usage: Decodable {
            struct InputDetails: Decodable { let cached_tokens: Int? }
            let input_tokens: Int
            let output_tokens: Int
            let input_tokens_details: InputDetails?
        }
        let status: String?
        let output: [OutputItem]
        let usage: Usage?

        var outputText: String {
            output
                .filter { $0.type == "message" }
                .flatMap { $0.content ?? [] }
                .filter { $0.type == "output_text" }
                .compactMap(\.text)
                .joined()
        }
    }

    /// Calls the Responses API. `instructions` becomes the system/developer message; `input`
    /// is the user message. `store: false` keeps the exchange out of OpenAI's stored responses.
    func createResponse(model: String, instructions: String, input: String, reasoningEffort: String?) async throws -> ResponseResult {
        var body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input,
            "store": false,
        ]
        if let reasoningEffort { body["reasoning"] = ["effort": reasoningEffort] }

        var request = makeRequest("responses", method: "POST")
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(request)
        return try decode(ResponseResult.self, from: data)
    }

    // MARK: Plumbing

    private func makeRequest(_ path: String, method: String) -> URLRequest {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        guard !apiKey.isEmpty else { throw OpenAIError.missingAPIKey }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let error as URLError {
            throw OpenAIError.from(urlError: error)
        }
        guard let http = response as? HTTPURLResponse else { throw OpenAIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let error = OpenAIError.from(status: http.statusCode, body: data)
            Log.openAI.error("\(request.url?.path ?? "", privacy: .public) failed: HTTP \(http.statusCode)")
            throw error
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw OpenAIError.invalidResponse
        }
    }
}

/// multipart/form-data body builder for file uploads.
struct MultipartForm {
    private let boundary = "murmur-" + UUID().uuidString
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }

    mutating func addFile(_ name: String, filename: String, mimeType: String, data: Data) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.append("\r\n")
    }

    func finalized() -> Data {
        var result = body
        result.append("--\(boundary)--\r\n")
        return result
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

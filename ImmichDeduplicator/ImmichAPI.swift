import Foundation

struct ImmichAPI {
    let baseURL: URL
    let apiKey: String
    let session: URLSession

    init(settings: AppSettings, session: URLSession = .shared) throws {
        let trimmed = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw CleanupError.invalidServerURL
        }

        self.baseURL = url
        self.apiKey = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func fetchDuplicates() async throws -> [ImmichDuplicateGroup] {
        var request = try makeRequest(path: "/duplicates", method: "GET")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode([ImmichDuplicateGroup].self, from: data)
    }

    func resolveDuplicates(_ groups: [DuplicateResolveGroup]) async throws {
        guard !groups.isEmpty else {
            return
        }

        var request = try makeRequest(path: "/duplicates/resolve", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(DuplicateResolveRequest(groups: groups))

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CleanupError.invalidServerURL
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, endpointPath].filter { !$0.isEmpty }.joined(separator: "/")

        guard let url = components.url else {
            throw CleanupError.invalidServerURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            return
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CleanupError.serverError(httpResponse.statusCode, body)
        }
    }
}

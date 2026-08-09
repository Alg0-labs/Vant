import Foundation

enum BackendError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case server(String)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Couldn't build the backend request URL."
        case .invalidResponse:
            return "The backend returned an unexpected response."
        case .server(let message):
            return message
        case .network(let error):
            return error.localizedDescription
        }
    }
}

/// Talks to the local Go backend over HTTP.
///
/// `apiV1Base` is the single source of truth for the backend's versioned
/// API prefix — every request is built from it, so a version bump
/// (`/api/v1` → `/api/v2`) is a one-line change here and nowhere else.
final class BackendClient {
    static let apiV1Base = "http://127.0.0.1:8080/api/v1"

    /// Multipart field name the audio file is uploaded under. Must match
    /// `audioFormField` in the backend's handlers.go.
    private static let audioFormField = "audio"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Uploads the recording at `audioFileURL` to `POST /api/v1/dictate`
    /// and returns the cleaned transcript.
    func dictate(audioFileURL: URL) async throws -> String {
        guard let url = URL(string: "\(BackendClient.apiV1Base)/dictate") else {
            throw BackendError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try multipartBody(boundary: boundary, audioFileURL: audioFileURL)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BackendError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let decodedError = try? JSONDecoder().decode(ErrorPayload.self, from: data) {
                throw BackendError.server(decodedError.error)
            }
            throw BackendError.server("Backend returned status \(httpResponse.statusCode).")
        }

        let decoded = try JSONDecoder().decode(DictatePayload.self, from: data)
        return decoded.text
    }

    private func multipartBody(boundary: String, audioFileURL: URL) throws -> Data {
        let audioData = try Data(contentsOf: audioFileURL)

        var body = Data()
        body.append("--\(boundary)\r\n".utf8Data)
        body.append(
            "Content-Disposition: form-data; name=\"\(BackendClient.audioFormField)\"; filename=\"\(audioFileURL.lastPathComponent)\"\r\n"
                .utf8Data
        )
        body.append("Content-Type: audio/mp4\r\n\r\n".utf8Data)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".utf8Data)
        return body
    }
}

private struct DictatePayload: Decodable {
    let text: String
}

private struct ErrorPayload: Decodable {
    let error: String
}

private extension String {
    var utf8Data: Data { Data(utf8) }
}

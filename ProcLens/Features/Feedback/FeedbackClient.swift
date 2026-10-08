import Foundation

/// POSTs a report to the Cloudflare Worker relay (`feedback-relay/`), which holds the only GitHub credential
/// (a PAT scoped to canberkys/proclens Issues) and creates the issue server-side. Nothing secret ships in the app:
/// `clientToken` is NOT a secret, it only filters casual hits on the relay URL (the Worker's own comment says the
/// same). Real abuse protection is GitHub's per-token rate limit and the PAT being able to create issues only.
struct FeedbackClient: Sendable {
    static let relayURL = URL(string: "https://proclens-feedback-relay.ck-7fa.workers.dev")!
    static let clientToken = "3bc3d1b2158b558f5e1c23004737c4bab8b6ad006f595b77"
    static let issuesNewURL = "https://github.com/canberkys/proclens/issues/new"

    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case bug = "Bug"
        case feature = "Feature request"
        var id: String { rawValue }
        var apiValue: String { self == .bug ? "bug" : "feature" }
    }

    struct Created: Equatable, Sendable {
        let number: Int?
        let url: URL?
    }

    struct Failure: Error, Equatable, Sendable { let message: String }

    var relayURL = Self.relayURL
    var session: URLSession = .shared

    func makeRequest(kind: Kind, title: String, description: String, diagnostics: String?) -> URLRequest {
        var request = URLRequest(url: relayURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.clientToken, forHTTPHeaderField: "X-ProcLens-Client")
        var body: [String: String] = [
            "type": kind.apiValue,
            "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
            "description": description.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        if let diagnostics { body["diagnostics"] = diagnostics }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    func send(kind: Kind, title: String, description: String, diagnostics: String?) async throws -> Created {
        let request = makeRequest(kind: kind, title: title, description: description, diagnostics: diagnostics)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure(message: "Couldn't reach the feedback service: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { throw Failure(message: "No response from the feedback service.") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if (200..<300).contains(http.statusCode), json?["ok"] as? Bool == true {
            return Created(number: json?["issueNumber"] as? Int, url: (json?["issueUrl"] as? String).flatMap(URL.init))
        }
        throw Failure(message: (json?["error"] as? String) ?? "The feedback service returned status \(http.statusCode).")
    }

    /// Browser fallback: a pre-filled GitHub "new issue" page. The body is truncated so the URL stays loadable.
    static func browserFallbackURL(title: String, body: String) -> URL? {
        var c = URLComponents(string: issuesNewURL)
        c?.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: String(body.prefix(6000)))]
        return c?.url
    }
}

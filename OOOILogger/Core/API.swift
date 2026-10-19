import Foundation

struct APIError: LocalizedError {
    let message: String
    let status: Int          // 0 = could not reach Home Assistant
    var errorDescription: String? { message }
    var offline: Bool { status == 0 }
    static let unreachable = APIError(message: "Cannot reach Home Assistant. Check your connection.", status: 0)
}

/// Talks to the add-on's direct port (for example http://homeassistant:8199) over Tailscale.
final class API {
    static let shared = API()
    private let session: URLSession

    private init() {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 180
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        session = URLSession(configuration: c)
    }

    var baseString: String {
        get { UserDefaults.standard.string(forKey: "serverURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "serverURL") }
    }
    /// The add-on's oooi_auth cookie, kept after logging in with app_password.
    var token: String {
        get { UserDefaults.standard.string(forKey: "authToken") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "authToken") }
    }

    static func normalize(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return "" }
        if !v.lowercased().hasPrefix("http://") && !v.lowercased().hasPrefix("https://") { v = "http://" + v }
        while v.hasSuffix("/") { v.removeLast() }
        return v
    }
    var base: URL? { baseString.isEmpty ? nil : URL(string: baseString + "/") }
    var configured: Bool { base != nil }

    func url(_ path: String) -> URL? { base.flatMap { URL(string: path, relativeTo: $0)?.absoluteURL } }

    func raw(_ method: String, _ path: String, body: Data? = nil, contentType: String? = nil,
             headers: [String: String] = [:], timeout: TimeInterval = 15) async throws -> (Data, HTTPURLResponse) {
        guard let u = url(path) else { throw APIError(message: "Add your Home Assistant address in Settings.", status: 0) }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = method
        req.httpBody = body
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if !token.isEmpty { req.setValue("oooi_auth=\(token)", forHTTPHeaderField: "Cookie") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw APIError.unreachable }
        guard let http = resp as? HTTPURLResponse else { throw APIError.unreachable }
        return (data, http)
    }

    /// JSON request; throws the add-on's own error text on failure.
    @discardableResult
    func call(_ method: String, _ path: String, json: Any? = nil, body: Data? = nil, contentType: String? = nil,
              headers: [String: String] = [:], timeout: TimeInterval = 15) async throws -> JSON {
        var b = body, ct = contentType
        if let json { b = try JSONSerialization.data(withJSONObject: json); ct = "application/json" }
        let (data, http) = try await raw(method, path, body: b, contentType: ct, headers: headers, timeout: timeout)
        let j = (try? JSONSerialization.jsonObject(with: data)) as? JSON ?? [:]
        if http.statusCode == 401 { throw APIError(message: (j["error"] as? String) ?? "Log in again.", status: 401) }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(message: (j["error"] as? String) ?? "Request failed (\(http.statusCode))", status: http.statusCode)
        }
        return j
    }

    /// POST api/login and keep the cookie it sets.
    func login(password: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["password": password])
        let (data, http) = try await raw("POST", "api/login", body: body, contentType: "application/json")
        if http.statusCode != 200 {
            let j = (try? JSONSerialization.jsonObject(with: data)) as? JSON ?? [:]
            throw APIError(message: (j["error"] as? String) ?? "Login failed (\(http.statusCode))", status: http.statusCode)
        }
        if let sc = http.value(forHTTPHeaderField: "Set-Cookie"),
           let r = sc.range(of: "oooi_auth=") {
            token = String(sc[r.upperBound...].prefix { $0 != ";" && $0 != "," })
        } else {
            token = ""   // no app_password on the add-on
        }
    }
}

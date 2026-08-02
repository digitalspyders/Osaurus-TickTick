//
//  Tools.swift
//  osaurus-ticktick
//
//  All 14 tool implementations. Each tool:
//    1. Parses + validates its args (throwing EnvelopeFailure on bad input)
//    2. Builds a TickTickClient from the injected secrets/config
//    3. Calls the API
//    4. Returns a canonical envelope string
//

import Foundation
import OsaurusPluginABI
import OsaurusPluginKit
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Shared payload decoding

/// The two underscore-prefixed blocks Osaurus injects into every tool
/// payload: `_secrets` (configured credentials) and `_config` (plugin
/// settings). Both are optional.
struct InjectedPayload: Decodable {
    let _secrets: [String: String]?
    let _config: [String: AnyCodable]?
}

/// Minimal loose-typed JSON value so `_config` can carry bools/strings.
struct AnyCodable: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) { value = b }
        else if let s = try? container.decode(String.self) { value = s }
        else if let i = try? container.decode(Int.self) { value = i }
        else if let d = try? container.decode(Double.self) { value = d }
        else { value = NSNull() }
    }
}

/// Pulls the secrets dict and config dict (bools unwrapped) out of a raw
/// JSON payload string.
func parseInjected(_ json: String) -> (secrets: [String: String]?, config: [String: Any]?) {
    guard let data = json.data(using: .utf8),
          let p = try? JSONDecoder().decode(InjectedPayload.self, from: data)
    else { return (nil, nil) }
    var cfg: [String: Any] = [:]
    if let raw = p._config { for (k, v) in raw { cfg[k] = v.value } }
    return (p._secrets, cfg.isEmpty ? nil : cfg)
}

// MARK: - Date parsing

/// User's timezone for relative-date resolution. Defaults to the system
/// timezone; the manifest documents this so the LLM can override by
/// passing an explicit ISO 8601 date.
private var userTimeZone: TimeZone {
    TimeZone.current
}

/// Parses a date argument. Accepts:
///   - ISO 8601 (e.g. "2026-08-01T08:00:00-05:00")
///   - "YYYY-MM-DD" (all-day)
///   - "today", "today at 8 AM", "tomorrow", "tomorrow at 8 AM",
///     "in 3 days", "next monday", etc. (resolved in the user's tz)
/// Returns nil when the input is nil/empty (caller decides if that's OK).
func parseFlexibleDate(_ input: String?) throws -> String? {
    guard let input, !input.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    let trimmed = input.trimmingCharacters(in: .whitespaces)

    // ISO 8601 with offset — pass through.
    if trimmed.contains("T") {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: trimmed) { return isoString(d) }
        fmt.formatOptions = [.withInternetDateTime]
        if let d = fmt.date(from: trimmed) { return isoString(d) }
    }

    // YYYY-MM-DD — treat as all-day at local midnight.
    if let d = DateFormatter.dateOnly.date(from: trimmed) {
        return isoString(d)
    }

    // Relative keywords.
    if let d = try? parseRelative(trimmed) {
        return isoString(d)
    }

    throw EnvelopeFailure(
        .invalidArgs,
        "Unrecognized date '\(trimmed)'. Use ISO 8601 (2026-08-01T08:00:00-05:00), YYYY-MM-DD, or 'today' / 'tomorrow at 8 AM'."
    )
}

/// Formats a Date as an ISO 8601 string in the user's timezone, which is
/// what TickTick expects for `startDate`/`dueDate`.
private func isoString(_ d: Date) -> String {
    let fmt = ISO8601DateFormatter()
    fmt.timeZone = userTimeZone
    fmt.formatOptions = [.withInternetDateTime]
    return fmt.string(from: d)
}

private extension DateFormatter {
    static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = userTimeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// Very small relative-date parser: handles "today", "tomorrow",
/// "today/tomorrow at <time>", "in N days", "next <weekday>".
private func parseRelative(_ s: String) throws -> Date {
    let lower = s.lowercased()
    let cal = Calendar(identifier: .gregorian)
    var calTZ = cal
    calTZ.timeZone = userTimeZone
    let now = Date()

    // "in N days" / "in N day"
    if let m = lower.range(of: #"^in (\d+) days?$"#, options: .regularExpression) {
        let numRange = m
        let numString = String(lower[numRange].split(separator: " ")[1])
        let num = Int(numString) ?? 0
        let stripped = lower.replacingCharacters(in: m, with: "")
        let base = calTZ.date(byAdding: .day, value: num, to: now) ?? now
        if stripped.trimmingCharacters(in: .whitespaces).isEmpty {
            return calTZ.startOfDay(for: base)
        }
        return try applyTimePhrase(stripped, to: base, calendar: calTZ)
    }

    // "today" / "tomorrow" optionally followed by "at <time>"
    let baseOffset: Int
    if lower.hasPrefix("today") { baseOffset = 0 }
    else if lower.hasPrefix("tomorrow") { baseOffset = 1 }
    else if lower.hasPrefix("yesterday") { baseOffset = -1 }
    else {
        // "next <weekday>"
        if lower.hasPrefix("next ") {
            let weekdayName = lower.replacingOccurrences(of: "next ", with: "")
            return try nextWeekday(weekdayName, from: now, calendar: calTZ)
        }
        throw EnvelopeFailure(.invalidArgs, "Unrecognized relative date: \(s)")
    }

    let base = calTZ.date(byAdding: .day, value: baseOffset, to: now) ?? now
    let remainder: String
    if baseOffset == 0 {
        remainder = lower.replacingOccurrences(of: "today", with: "")
    } else if baseOffset == 1 {
        remainder = lower.replacingOccurrences(of: "tomorrow", with: "")
    } else {
        remainder = lower.replacingOccurrences(of: "yesterday", with: "")
    }
    if remainder.trimmingCharacters(in: .whitespaces).isEmpty {
        return calTZ.startOfDay(for: base)
    }
    return try applyTimePhrase(remainder, to: base, calendar: calTZ)
}

/// Applies an "at 8 AM" / "at 14:30" / "at 8:00 PM" suffix to a base date.
private func applyTimePhrase(_ s: String, to base: Date, calendar cal: Calendar) throws -> Date {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    guard trimmed.lowercased().hasPrefix("at ") else {
        throw EnvelopeFailure(.invalidArgs, "Expected 'at <time>' after relative date, got: \(trimmed)")
    }
    let timeStr = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
    // Try "8 AM", "8:30 AM", "14:30", "08:00"
    let formats = ["h:mm a", "h a", "H:mm", "HH:mm", "h:mm:ss a", "H:mm:ss"]
    for fmt in formats {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = cal.timeZone
        df.dateFormat = fmt
        if let t = df.date(from: timeStr) {
            // Combine base date with parsed time.
            let comps = cal.dateComponents([.year, .month, .day], from: base)
            let timeComps = cal.dateComponents([.hour, .minute, .second], from: t)
            var merged = DateComponents()
            merged.year = comps.year; merged.month = comps.month; merged.day = comps.day
            merged.hour = timeComps.hour; merged.minute = timeComps.minute; merged.second = timeComps.second
            merged.timeZone = cal.timeZone
            return cal.date(from: merged) ?? base
        }
    }
    throw EnvelopeFailure(.invalidArgs, "Could not parse time: \(timeStr). Try '8 AM' or '14:30'.")
}

private func nextWeekday(_ name: String, from now: Date, calendar cal: Calendar) throws -> Date {
    let names = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7,
    ]
    guard let target = names[name.lowercased()] else {
        throw EnvelopeFailure(.invalidArgs, "Unknown weekday: \(name)")
    }
    let today = cal.component(.weekday, from: now)
    var delta = target - today
    if delta <= 0 { delta += 7 }
    return cal.date(byAdding: .day, value: delta, to: cal.startOfDay(for: now)) ?? now
}

// MARK: - Priority mapping

/// The manifest exposes a friendly 0-4 scale (0=none, 1=low, 2=medium,
/// 3=high, 4=critical). TickTick's API uses 0/1/3/5. Map between them.
func mapPriorityToFriendly(_ api: Int?) -> Int? {
    guard let api else { return nil }
    switch api {
    case 0: return 0
    case 1: return 1
    case 3: return 2
    case 5: return 3
    default: return 4   // any other value → critical
    }
}

func mapPriorityToAPI(_ friendly: Int?) -> Int? {
    guard let friendly else { return nil }
    switch friendly {
    case 0: return 0
    case 1: return 1
    case 2: return 3
    case 3: return 5
    default: return 5   // 4 (critical) → 5 (TickTick's highest)
    }
}

// MARK: - JSON serialization helpers

/// Serializes an encodable value to a JSON string, throwing on failure.
func jsonString<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    return String(data: data, encoding: .utf8) ?? "{}"
}

/// Wraps a raw JSON string in a success envelope under "result".
func successResult(_ raw: String) -> String {
    Envelope.success(raw: raw)
}

// MARK: - Tool: connect_account

/// Runs the TickTick OAuth2 flow: opens the browser for authorization,
/// starts a local HTTP server to catch the callback, exchanges the
/// authorization code for an access token, and stores it via
/// `HostBridge.shared.configSet("access_token", ...)`.
///
/// The user must have `client_id`, `client_secret`, and `redirect_uri`
/// configured as plugin secrets. The redirect_uri must point to a local
/// address (e.g. `http://127.0.0.1:8080/`) — the tool starts a server
/// on that port to catch the callback.
struct ConnectAccountTool {
    let name = "connect_account"

    struct Args: Decodable {
        let _secrets: [String: String]?
        let _config: [String: AnyCodable]?
    }

    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return Envelope.failure(.invalidArgs, "Invalid arguments")
        }

        guard let clientId = input._secrets?["client_id"], !clientId.isEmpty else {
            return Envelope.failure(.invalidArgs, "Client ID is not configured. Set it in Osaurus → Tools → TickTick → Configure.")
        }
        guard let clientSecret = input._secrets?["client_secret"], !clientSecret.isEmpty else {
            return Envelope.failure(.invalidArgs, "Client Secret is not configured. Set it in Osaurus → Tools → TickTick → Configure.")
        }

        let cfgDict: [String: Any]? = input._config?.reduce(into: [:]) { $0[$1.key] = $1.value.value }
        let useDida365 = (cfgDict?["use_dida365"] as? Bool) == true
        let redirectUri = "http://127.0.0.1:8080/"
        guard !redirectUri.isEmpty else {
            return Envelope.failure(.invalidArgs, "Redirect URL is not configured. Set it in Osaurus → Tools → TickTick → Configure.")
        }
        let authHost = useDida365 ? "https://dida365.com" : "https://ticktick.com"
        let apiHost = useDida365 ? "https://api.dida365.com" : "https://api.ticktick.com"

        // Parse the redirect URI to get the port and path
        guard let redirectURL = URL(string: redirectUri),
              let port = redirectURL.port
        else {
            return Envelope.failure(.invalidArgs, "Redirect URL must include a port, e.g. http://127.0.0.1:8080/")
        }
        let path = redirectURL.path.isEmpty ? "/" : redirectURL.path

        // Step 1: Build the authorization URL
        var authComponents = URLComponents(string: "\(authHost)/oauth/authorize")!
        authComponents.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "scope", value: "tasks:read tasks:write"),
            URLQueryItem(name: "state", value: "osaurus-ticktick"),
            URLQueryItem(name: "response_type", value: "code"),
        ]
        guard let authURL = authComponents.url else {
            return Envelope.failure(.executionError, "Could not build authorization URL")
        }

        // Step 2: Start local HTTP server to catch the callback
        let oauthDelegate = OAuthCallbackDelegate()
        let server = LocalHTTPServer(port: port, path: path) { queryParams in
            if let code = queryParams["code"] {
                oauthDelegate.authCode = code
                oauthDelegate.signal()
                return """
                <html><body style="font-family: -apple-system; padding: 40px; text-align: center;">
                <h1>TickTick authorized!</h1>
                <p>You can close this tab and return to Osaurus.</p>
                </body></html>
                """
            }
            if let error = queryParams["error"] {
                oauthDelegate.authError = error
                oauthDelegate.signal()
                return """
                <html><body style="font-family: -apple-system; padding: 40px; text-align: center;">
                <h1>Authorization failed</h1>
                <p>\(error)</p>
                </body></html>
                """
            }
            return "<html><body><h1>Waiting...</h1></body></html>"
        }

        guard server.start() else {
            return Envelope.failure(.executionError, "Could not start local server on port \(port). Make sure the port is not in use and matches your Redirect URL (\(redirectUri)).")
        }

        // Step 3: Open the browser
        #if canImport(AppKit)
        DispatchQueue.main.async {
            NSWorkspace.shared.open(authURL)
        }
        #endif

        // Step 4: Wait for the callback (up to 3 minutes)
        oauthDelegate.waitForCallback(timeout: 180)
        server.stop()

        if let error = oauthDelegate.authError {
            return Envelope.failure(.permissionDenied, "TickTick authorization failed: \(error)")
        }
        guard let code = oauthDelegate.authCode else {
            return Envelope.failure(.timeout, "Timed out waiting for authorization. Please try again and click 'Allow' in the browser.")
        }

        // Step 5: Exchange the code for an access token
        // Token endpoint is on the auth host (ticktick.com), NOT the API host
        // (api.ticktick.com). Using the wrong host gives a 401 "Full
        // authentication is required" from Spring Security.
        var tokenRequest = URLRequest(url: URL(string: "\(authHost)/oauth/token")!)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encodedRedirect = redirectUri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redirectUri
        let body = "code=\(code)&client_id=\(clientId)&client_secret=\(clientSecret)&grant_type=authorization_code&redirect_uri=\(encodedRedirect)"
        tokenRequest.httpBody = body.data(using: .utf8)

        let tokenSemaphore = DispatchSemaphore(value: 0)
        let tokenBox = TokenResponseBox()

        let tokenConfig = URLSessionConfiguration.ephemeral
        let tokenSession = URLSession(configuration: tokenConfig)
        tokenSession.dataTask(with: tokenRequest) { data, response, error in
            tokenBox.data = data
            tokenBox.error = error
            if let http = response as? HTTPURLResponse { tokenBox.status = http.statusCode }
            tokenSemaphore.signal()
        }.resume()

        _ = tokenSemaphore.wait(timeout: .now() + 30)
        tokenSession.invalidateAndCancel()

        if let error = tokenBox.error {
            return Envelope.failure(.executionError, "Token exchange failed: \(error.localizedDescription)")
        }

        guard let respData = tokenBox.data,
              let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any]
        else {
            let body = tokenBox.data.flatMap { String(data: $0, encoding: .utf8) } ?? "(empty)"
            return Envelope.failure(.executionError, "Token exchange returned invalid response (HTTP \(tokenBox.status)): \(body)")
        }

        guard let accessToken = json["access_token"] as? String else {
            let errorDesc = json["error_description"] as? String ?? json["error"] as? String ?? "Unknown error"
            return Envelope.failure(.permissionDenied, "TickTick did not return an access token: \(errorDesc)")
        }

        // Step 6: Store the token persistently
        HostBridge.shared.configSet("access_token", accessToken)
        if let expiresIn = json["expires_in"] as? Int {
            HostBridge.shared.configSet("token_expires_in", String(expiresIn))
        }

        // Step 7: Return success
        var fields: [String: Any] = ["connected": true]
        if let expiresIn = json["expires_in"] as? Int {
            fields["expires_in_seconds"] = expiresIn
        }
        return Envelope.success(fields: fields)
    }
}

/// Holds the OAuth callback result. The HTTP server handler sets
/// `authCode`/`authError`, then calls `signal()` to release the waiter.
final class OAuthCallbackDelegate: @unchecked Sendable {
    var authCode: String?
    var authError: String?
    private let semaphore = DispatchSemaphore(value: 0)

    func waitForCallback(timeout: TimeInterval) {
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    func signal() {
        semaphore.signal()
    }
}

/// Thread-safe box for the token exchange HTTP response.
final class TokenResponseBox: @unchecked Sendable {
    var data: Data?
    var error: Error?
    var status: Int = 0
}

// MARK: - Local HTTP Server (for OAuth callback)

/// Minimal TCP HTTP server for catching the OAuth redirect callback.
/// Listens on a local port, parses the query string, and calls the
/// handler with the query parameters. Sends back a simple HTML page.
final class LocalHTTPServer: @unchecked Sendable {
    private var fd: Int32 = -1
    private var running = false
    private let port: Int
    private let path: String
    private let handler: ([String: String]) -> String

    init(port: Int, path: String, handler: @escaping ([String: String]) -> String) {
        self.port = port
        self.path = path
        self.handler = handler
    }

    func start() -> Bool {
        fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout.size(ofValue: opt)))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult >= 0 else {
            close(fd)
            fd = -1
            return false
        }

        Darwin.listen(fd, 1)
        running = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptConnection()
        }
        return true
    }

    private func acceptConnection() {
        while running {
            var clientAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.accept(fd, sa, &len)
                }
            }
            guard client >= 0 else { continue }

            var buffer = [UInt8](repeating: 0, count: 8192)
            let bytesRead = read(client, &buffer, buffer.count)
            let request = String(bytes: buffer.prefix(bytesRead), encoding: .utf8) ?? ""

            // Parse: GET /path?code=xxx&state=yyy HTTP/1.1
            let requestLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = requestLine.split(separator: " ")
            let urlPath = parts.count > 1 ? String(parts[1]) : "/"

            var queryParams: [String: String] = [:]
            if let qIndex = urlPath.firstIndex(of: "?") {
                let queryString = String(urlPath[urlPath.index(after: qIndex)...])
                for pair in queryString.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    if kv.count == 2 {
                        let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                        let val = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                        queryParams[key] = val
                    }
                }
            }

            let html = handler(queryParams)
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(html.utf8.count)\r
            Connection: close\r
            \r
            \(html)
            """
            let respData = response.data(using: .utf8) ?? Data()
            respData.withUnsafeBytes { ptr in
                _ = write(client, ptr.baseAddress, respData.count)
            }
            close(client)

            // Stop after first request
            running = false
            break
        }
    }

    func stop() {
        running = false
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}

// MARK: - Tool: list_projects

struct ListProjectsTool {
    let name = "list_projects"

    struct Args: Decodable {
        let view: String?       // "all" | "active" | "completed" (TickTick has no "completed projects" — we treat "all" == "active")
        let limit: Int?
        let _secrets: [String: String]?
        let _config: [String: AnyCodable]?
    }

    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return Envelope.failure(.invalidArgs, "Invalid arguments")
        }
        let (secrets, config) = (input._secrets, input._config)
        let cfgDict: [String: Any]? = config?.reduce(into: [:]) { $0[$1.key] = $1.value.value }

        let client: TickTickClient
        do {
            client = try TickTickClient.from(secrets: secrets, config: cfgDict)
        } catch {
            return ticktickFailure("list_projects", error)
        }

        do {
            let projects = try client.listProjects()
            let limit = max(1, min(100, input.limit ?? 50))
            let trimmed = Array(projects.prefix(limit))
            // Project view is informational only — TickTick doesn't expose
            // a "completed projects" filter at the project level.
            let out = try jsonString(trimmed.map(PublicProject.init))
            return successResult(out)
        } catch {
            return ticktickFailure("list_projects", error)
        }
    }
}

// MARK: - Tool: get_project

struct GetProjectTool {
    let name = "get_project"

    struct Args: Decodable {
        let project_id: String
        let _secrets: [String: String]?
        let _config: [String: AnyCodable]?
    }

    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return Envelope.failure(.invalidArgs, "Invalid arguments. Required: project_id")
        }
        guard !input.project_id.isEmpty else {
            return Envelope.failure(.invalidArgs, "project_id must not be empty")
        }
        let cfgDict: [String: Any]? = input._config?.reduce(into: [:]) { $0[$1.key] = $1.value.value }

        let client: TickTickClient
        do {
            client = try TickTickClient.from(secrets: input._secrets, config: cfgDict)
        } catch {
            return ticktickFailure("get_project", error)
        }

        do {
            let p = try client.getProject(input.project_id)
            let out = try jsonString(PublicProject(p))
            return successResult(out)
        } catch {
            return ticktickFailure("get_project", error)
        }
    }
}

// MARK: - Tool: create_project

struct CreateProjectTool {
    let name = "create_project"

    struct Args: Decodable {
        let name: String
        let color: String?
        let view_mode: String?
        let kind: String?
        let sort_order: Int?
        let tag: String?      // accepted for compat; TickTick v1 has no project tag — ignored
        let _secrets: [String: String]?
        let _config: [String: AnyCodable]?
    }

    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return Envelope.failure(.invalidArgs, "Invalid arguments. Required: name")
        }
        guard !input.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Envelope.failure(.invalidArgs, "project name must not be empty")
        }
        if let vm = input.view_mode, !["list", "kanban", "timeline"].contains(vm) {
            return Envelope.failure(.invalidArgs, "view_mode must be one of: list, kanban, timeline")
        }
        if let k = input.kind, !["TASK", "NOTE"].contains(k) {
            return Envelope.failure(.invalidArgs, "kind must be one of: TASK, NOTE")
        }
        let cfgDict: [String: Any]? = input._config?.reduce(into: [:]) { $0[$1.key] = $1.value.value }

        let client: TickTickClient
        do {
            client = try TickTickClient.from(secrets: input._secrets, config: cfgDict)
        } catch {
            return ticktickFailure("create_project", error)
        }

        do {
            // Normalize color: accept both "#RRGGBB" and "a02"-style codes.
            let color = input.color?.trimmingCharacters(in: .whitespaces)
            let normalized = color.flatMap { $0.hasPrefix("#") ? $0 : nil }
            let p = try client.createProject(
                name: input.name,
                color: normalized,
                kind: input.kind ?? "TASK",
                viewMode: input.view_mode ?? "list",
                sortOrder: input.sort_order
            )
            let out = try jsonString(PublicProject(p))
            return successResult(out)
        } catch {
            return ticktickFailure("create_project", error)
        }
    }
}

// MARK: - Tool: delete_project

struct DeleteProjectTool {
    let name = "delete_project"

    struct Args: Decodable {
        let project_id: String
        let _secrets: [String: String]?
        let _config: [String: AnyCodable]?
    }

    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return Envelope.failure(.invalidArgs, "Invalid arguments. Required: project_id")
        }
        guard !input.project_id.isEmpty else {
            return Envelope.failure(.invalidArgs, "project_id must not be empty")
        }
        let cfgDict: [String: Any]? = input._config?.reduce(into: [:]) { $0[$1.key] = $1.value.value }

        let client: TickTickClient
        do {
            client = try TickTickClient.from(secrets: input._secrets, config: cfgDict)
        } catch {
            return ticktickFailure("delete_project", error)
        }

        do {
            try client.deleteProject(input.project_id)
            return Envelope.success(fields: ["deleted": true, "project_id": input.project_id])
        } catch {
            return ticktickFailure("delete_project", error)
        }
    }
}

// MARK: - Tool: update_project

struct UpdateProjectTool {
    let name = "update_project"

    struct Args: Decodable {
        let project_id: String
        let name: String?
        let color: String?
        let view_mode: String?
        let kind: String?
        let sort_order: Int?
        let _secrets: [String: String]?
        let _config: [String: AnyCodable]?
    }

    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return Envelope.failure(.invalidArgs, "Invalid arguments. Required: project_id")
        }
        guard !input.project_id.isEmpty else {
            return Envelope.failure(.invalidArgs, "project_id must not be empty")
        }
        if let vm = input.view_mode, !["list", "kanban", "timeline"].contains(vm) {
            return Envelope.failure(.invalidArgs, "view_mode must be one of: list, kanban, timeline")
        }
        if let k = input.kind, !["TASK", "NOTE"].contains(k) {
            return Envelope.failure(.invalidArgs, "kind must be one of: TASK, NOTE")
        }
        let cfgDict: [String: Any]? = input._config?.reduce(into: [:]) { $0[$1.key] = $1.value.value }

        let client: TickTickClient
        do {
            client = try TickTickClient.from(secrets: input._secrets, config: cfgDict)
        } catch {
            return ticktickFailure("update_project", error)
        }

        do {
            let color = input.color?.trimmingCharacters(in: .whitespaces)
            let normalized = color.flatMap { $0.hasPrefix("#") ? $0 : nil }
            let p = try client.updateProject(
                id: input.project_id,
                name: input.name,
                color: normalized,
                kind: input.kind,
                viewMode: input.view_mode,
                sortOrder: input.sort_order
            )
            let out = try jsonString(PublicProject(p))
            return successResult(out)
        } catch {
            return ticktickFailure("update_project", error)
        }
    }
}

// MARK: - Tool: list_tasks

struct ListTasksTool {
    let name = "list_tasks"

    struct Args: Decodable {
        let project_id: String
        let filter: String?       // all | active | completed | overdue
        let priority: Int?        // friendly 0-4
        let limit: Int?
        let _secrets: [String: String]?
        let _config: [String: AnyCodable]?
    }

    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return Envelope.failure(.invalidArgs, "Invalid arguments. Required: project_id")
        }
        guard !input.project_id.isEmpty else {
            return Envelope.failure(.invalidArgs, "project_id must not be empty")
        }
        let cfgDict: [String: Any]? = input._config?.reduce(into: [:]) { $0[$1.key] = $1.value.value }

        let client: TickTickClient
        do {
            client = try TickTickClient.from(secrets: input._secrets, config: cfgDict)
        } catch {
            return ticktickFailure("list_tasks", error)
        }

        do {
            let pd = try client.getProjectData(input.project_id)
            var tasks = pd.tasks ?? []
            // Filter
            let filter = input.filter ?? "active"
            switch filter {
            case "active":
                tasks = tasks.filter { ($0.status ?? 0) == 0 }
            case "completed":
                tasks = tasks.filter { ($0.status ?? 0) == 2 }
            case "overdue":
                let now = Date()
                tasks = tasks.filter { t in
                    guard (t.status ?? 0) == 0, let due = t.dueDate else { return false }
                    return parseISO(due).map { $0 < now } ?? false
                }
            case "all":
                break
            default:
                return Envelope.failure(.invalidArgs, "filter must be one of: all, active, completed, overdue")
            }
            // Priority filter (friendly scale)
            if let want = input.priority {
                let wantAPI = mapPriorityToAPI(want)
                tasks = tasks.filter { $0.priority == wantAPI }
            }
            let limit = max(1, min(100, input.limit ?? 50))
            let trimmed = Array(tasks.prefix(limit))
            let out = try jsonString(trimmed.map(PublicTask.init))
            return successResult(out)
        } catch {
            return ticktickFailure("list_tasks", error)
        }
    }
}

// MARK: - Tool: search_tasks

struct SearchTasksTool {
    let name = "search_tasks"

    struct Args: Decodable {
        let query: String
        let project_id: String?
        let limit: Int?
        let _secrets: [String: String]?
        let _config: [String: AnyCodable]?
    }

    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return Envelope.failure(.invalidArgs, "Invalid arguments. Required: query")
        }
        let query = input.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            return Envelope.failure(.invalidArgs, "query must not be empty")
        }
        let cfgDict: [String: Any]? = input._config?.reduce(into: [:]) { $0[$1.key] = $1.value.value }

        let client: TickTickClient
        do {
            client = try TickTickClient.from(secrets: input._secrets, config: cfgDict)
        } catch {
            return ticktickFailure("search_tasks", error)
        }

        do {
            // TickTick v1 has no search endpoint; we fetch all tasks
            // (including Inbox) and match client-side.
            let q = query.lowercased()

            let allTasks: [TickTickClient.Task]
            if let pid = input.project_id, !pid.isEmpty {
                let pd = try client.getProjectData(pid)
                allTasks = pd.tasks ?? []
            } else {
                allTasks = try client.getAllTasks()
            }

            let matches = allTasks.filter { t in
                t.title.lowercased().contains(q) ||
                (t.content ?? "").lowercased().contains(q) ||
                (t.tags ?? []).contains { $0.lowercased().contains(q) }
            }

            let limit = max(1, min(50, input.limit ?? 20))
            let trimmed = Array(matches.prefix(limit))
            let out = try jsonString(trimmed.map(PublicTask.init))
            return successResult(out)
        } catch {
            return ticktickFailure("search_tasks", error)
        }
    }
}

// MARK: - Tool: create_task

struct CreateTaskTool {
    let name = "create_task"

    struct ChecklistItemInput: Decodable {
        let title: String
        let start_date: String?
        let is_all_day: Bool?
        let sort_order: Int?
    }

    struct Args: Decodable {
        let project_id: String?
        let title: String
        let content: String?
        let desc: String?
        let start_date: String?
        let due_date: String?
        let priority: Int?        // friendly 0-4
        let is_all_day: Bool?
        let tags: [String]?
        let time_zone: String?
        let parent_id: String?
        let reminders: [String]?
        let repeat_flag: String?
        let sort_order: Int?
        let items: [ChecklistItemInput]?
        let _secrets: [String: String]?
        let _config: [String: AnyCodable]?
    }

    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return Envelope.failure(.invalidArgs, "Invalid arguments. Required: title")
        }
        guard !input.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Envelope.failure(.invalidArgs, "title must not be empty")
        }
        if let p = input.priority, !(0...4).contains(p) {
            return Envelope.failure(.invalidArgs, "priority must be 0-4 (0=none, 1=low, 2=medium, 3=high, 4=critical)")
        }
        let cfgDict: [String: Any]? = input._config?.reduce(into: [:]) { $0[$1.key] = $1.value.value }

        let startDate: String?
        let dueDate: String?
        do {
            startDate = try parseFlexibleDate(input.start_date)
            dueDate = try parseFlexibleDate(input.due_date)
        } catch {
            return ticktickFailure("create_task", error)
        }

        // Parse checklist item dates
        let items: [TickTickClient.CreateChecklistItem]?
        if let inputItems = input.items {
            var parsed: [TickTickClient.CreateChecklistItem] = []
            for item in inputItems {
                let itemStart = (try? parseFlexibleDate(item.start_date)) ?? nil
                parsed.append(TickTickClient.CreateChecklistItem(
                    title: item.title,
                    startDate: itemStart,
                    isAllDay: item.is_all_day,
                    sortOrder: item.sort_order,
                    timeZone: nil
                ))
            }
            items = parsed
        } else {
            items = nil
        }

        let client: TickTickClient
        do {
            client = try TickTickClient.from(secrets: input._secrets, config: cfgDict)
        } catch {
            return ticktickFailure("create_task", error)
        }

        do {
            let t = try client.createTask(
                title: input.title,
                projectId: input.project_id,
                content: input.content,
                desc: input.desc,
                priority: mapPriorityToAPI(input.priority),
                startDate: startDate,
                dueDate: dueDate,
                isAllDay: input.is_all_day,
                tags: input.tags,
                timeZone: input.time_zone,
                parentId: input.parent_id,
                reminders: input.reminders,
                repeatFlag: input.repeat_flag,
                sortOrder: input.sort_order,
                items: items
            )
            let out = try jsonString(PublicTask(t))
            return successResult(out)
        } catch {
            return ticktickFailure("create_task", error)
        }
    }
}

// MARK: - Tool: get_task

struct GetTaskTool {
    let name = "get_task"

    struct Args: Decodable {
        let project_id: String
        let task_id: String
        let _secrets: [String: String]?
        let _config: [String: AnyCodable]?
    }

    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return Envelope.failure(.invalidArgs, "Invalid arguments. Required: project_id, task_id")
        }
        guard !input.project_id.isEmpty, !input.task_id.isEmpty else {
            return Envelope.failure(.invalidArgs, "project_id and task_id must not be empty")
        }
        let cfgDict: [String: Any]? = input._config?.reduce(into: [:]) { $0[$1.key] = $1.value.value }

        let client: TickTickClient
        do {
            client = try TickTickClient.from(secrets: input._secrets, config: cfgDict)
        } catch {
            return ticktickFailure("get_task", error)
        }

        do {
            let t = try client.getTask(projectId: input.project_id, taskId: input.task_id)
            let out = try jsonString(PublicTask(t))
            return successResult(out)
        } catch {
            return ticktickFailure("get_task", error)
        }
    }
}

// MARK: - Tool: update_task

struct UpdateTaskTool {
    let name = "update_task"

    struct ChecklistItemInput: Decodable {
        let id: String?
        let title: String?
        let start_date: String?
        let is_all_day: Bool?
        let sort_order: Int?
        let status: Int?
        let completed_time: String?
    }

    struct Args: Decodable {
        let project_id: String
        let task_id: String
        let title: String?
        let content: String?
        let desc: String?
        let start_date: String?
        let due_date: String?
        let priority: Int?
        let is_all_day: Bool?
        let tags: [String]?
        let time_zone: String?
        let parent_id: String?
        let reminders: [String]?
        let repeat_flag: String?
        let sort_order: Int?
        let items: [ChecklistItemInput]?
        let _secrets: [String: String]?
        let _config: [String: AnyCodable]?
    }

    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return Envelope.failure(.invalidArgs, "Invalid arguments. Required: project_id, task_id")
        }
        guard !input.project_id.isEmpty, !input.task_id.isEmpty else {
            return Envelope.failure(.invalidArgs, "project_id and task_id must not be empty")
        }
        if let p = input.priority, !(0...4).contains(p) {
            return Envelope.failure(.invalidArgs, "priority must be 0-4")
        }
        let cfgDict: [String: Any]? = input._config?.reduce(into: [:]) { $0[$1.key] = $1.value.value }

        let startDate: String?
        let dueDate: String?
        do {
            startDate = try parseFlexibleDate(input.start_date)
            dueDate = try parseFlexibleDate(input.due_date)
        } catch {
            return ticktickFailure("update_task", error)
        }

        // Parse checklist item dates
        let items: [TickTickClient.UpdateChecklistItem]?
        if let inputItems = input.items {
            var parsed: [TickTickClient.UpdateChecklistItem] = []
            for item in inputItems {
                let itemStart = (try? parseFlexibleDate(item.start_date)) ?? nil
                let itemCompleted = (try? parseFlexibleDate(item.completed_time)) ?? nil
                parsed.append(TickTickClient.UpdateChecklistItem(
                    id: item.id,
                    title: item.title,
                    startDate: itemStart,
                    isAllDay: item.is_all_day,
                    sortOrder: item.sort_order,
                    status: item.status,
                    timeZone: nil,
                    completedTime: itemCompleted
                ))
            }
            items = parsed
        } else {
            items = nil
        }

        let client: TickTickClient
        do {
            client = try TickTickClient.from(secrets: input._secrets, config: cfgDict)
        } catch {
            return ticktickFailure("update_task", error)
        }

        do {
            let t = try client.updateTask(
                projectId: input.project_id,
                taskId: input.task_id,
                title: input.title,
                content: input.content,
                desc: input.desc,
                priority: mapPriorityToAPI(input.priority),
                startDate: startDate,
                dueDate: dueDate,
                isAllDay: input.is_all_day,
                tags: input.tags,
                timeZone: input.time_zone,
                parentId: input.parent_id,
                reminders: input.reminders,
                repeatFlag: input.repeat_flag,
                sortOrder: input.sort_order,
                items: items
            )
            let out = try jsonString(PublicTask(t))
            return successResult(out)
        } catch {
            return ticktickFailure("update_task", error)
        }
    }
}

// MARK: - Tool: complete_task

struct CompleteTaskTool {
    let name = "complete_task"

    struct Args: Decodable {
        let project_id: String
        let task_id: String
        let _secrets: [String: String]?
        let _config: [String: AnyCodable]?
    }

    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return Envelope.failure(.invalidArgs, "Invalid arguments. Required: project_id, task_id")
        }
        guard !input.project_id.isEmpty, !input.task_id.isEmpty else {
            return Envelope.failure(.invalidArgs, "project_id and task_id must not be empty")
        }
        let cfgDict: [String: Any]? = input._config?.reduce(into: [:]) { $0[$1.key] = $1.value.value }

        let client: TickTickClient
        do {
            client = try TickTickClient.from(secrets: input._secrets, config: cfgDict)
        } catch {
            return ticktickFailure("complete_task", error)
        }

        do {
            try client.completeTask(projectId: input.project_id, taskId: input.task_id)
            return Envelope.success(fields: [
                "completed": true,
                "project_id": input.project_id,
                "task_id": input.task_id,
            ])
        } catch {
            return ticktickFailure("complete_task", error)
        }
    }
}

// MARK: - Tool: delete_task

struct DeleteTaskTool {
    let name = "delete_task"

    struct Args: Decodable {
        let project_id: String
        let task_id: String
        let _secrets: [String: String]?
        let _config: [String: AnyCodable]?
    }

    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return Envelope.failure(.invalidArgs, "Invalid arguments. Required: project_id, task_id")
        }
        guard !input.project_id.isEmpty, !input.task_id.isEmpty else {
            return Envelope.failure(.invalidArgs, "project_id and task_id must not be empty")
        }
        let cfgDict: [String: Any]? = input._config?.reduce(into: [:]) { $0[$1.key] = $1.value.value }

        let client: TickTickClient
        do {
            client = try TickTickClient.from(secrets: input._secrets, config: cfgDict)
        } catch {
            return ticktickFailure("delete_task", error)
        }

        do {
            try client.deleteTask(projectId: input.project_id, taskId: input.task_id)
            return Envelope.success(fields: [
                "deleted": true,
                "project_id": input.project_id,
                "task_id": input.task_id,
            ])
        } catch {
            return ticktickFailure("delete_task", error)
        }
    }
}

// MARK: - Tool: move_task

struct MoveTaskTool {
    let name = "move_task"

    struct Args: Decodable {
        let task_id: String
        let from_project_id: String
        let to_project_id: String
        let _secrets: [String: String]?
        let _config: [String: AnyCodable]?
    }

    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return Envelope.failure(.invalidArgs, "Invalid arguments. Required: task_id, from_project_id, to_project_id")
        }
        guard !input.task_id.isEmpty, !input.from_project_id.isEmpty, !input.to_project_id.isEmpty else {
            return Envelope.failure(.invalidArgs, "task_id, from_project_id, and to_project_id must not be empty")
        }
        let cfgDict: [String: Any]? = input._config?.reduce(into: [:]) { $0[$1.key] = $1.value.value }

        let client: TickTickClient
        do {
            client = try TickTickClient.from(secrets: input._secrets, config: cfgDict)
        } catch {
            return ticktickFailure("move_task", error)
        }

        do {
            try client.moveTask(
                fromProjectId: input.from_project_id,
                toProjectId: input.to_project_id,
                taskId: input.task_id
            )
            return Envelope.success(fields: [
                "moved": true,
                "task_id": input.task_id,
                "from_project_id": input.from_project_id,
                "to_project_id": input.to_project_id,
            ])
        } catch {
            return ticktickFailure("move_task", error)
        }
    }
}

// MARK: - Tool: get_completed_tasks

struct GetCompletedTasksTool {
    let name = "get_completed_tasks"

    struct Args: Decodable {
        let project_ids: [String]?
        let start_date: String?
        let end_date: String?
        let _secrets: [String: String]?
        let _config: [String: AnyCodable]?
    }

    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return Envelope.failure(.invalidArgs, "Invalid arguments. Optional: project_ids, start_date, end_date")
        }
        let cfgDict: [String: Any]? = input._config?.reduce(into: [:]) { $0[$1.key] = $1.value.value }

        let startDate: String?
        let endDate: String?
        do {
            startDate = try parseFlexibleDate(input.start_date)
            endDate = try parseFlexibleDate(input.end_date)
        } catch {
            return ticktickFailure("get_completed_tasks", error)
        }

        let client: TickTickClient
        do {
            client = try TickTickClient.from(secrets: input._secrets, config: cfgDict)
        } catch {
            return ticktickFailure("get_completed_tasks", error)
        }

        do {
            let tasks = try client.getCompletedTasks(
                projectIds: input.project_ids,
                startDate: startDate,
                endDate: endDate
            )
            let out = try jsonString(tasks.map(PublicTask.init))
            return successResult(out)
        } catch {
            return ticktickFailure("get_completed_tasks", error)
        }
    }
}

// MARK: - Tool: filter_tasks

struct FilterTasksTool {
    let name = "filter_tasks"

    struct Args: Decodable {
        let project_ids: [String]?
        let start_date: String?
        let end_date: String?
        let priority: [Int]?       // API scale: 0, 1, 3, 5
        let tags: [String]?
        let status: [Int]?         // 0=active, 2=completed
        let _secrets: [String: String]?
        let _config: [String: AnyCodable]?
    }

    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return Envelope.failure(.invalidArgs, "Invalid arguments. Optional: project_ids, start_date, end_date, priority, tags, status")
        }
        // Validate priority values (API scale: 0, 1, 3, 5)
        if let prios = input.priority {
            for p in prios where ![0, 1, 3, 5].contains(p) {
                return Envelope.failure(.invalidArgs, "priority values must be on the API scale: 0 (none), 1 (low), 3 (medium), 5 (high)")
            }
        }
        if let statuses = input.status {
            for s in statuses where ![0, 2].contains(s) {
                return Envelope.failure(.invalidArgs, "status values must be 0 (active) or 2 (completed)")
            }
        }
        let cfgDict: [String: Any]? = input._config?.reduce(into: [:]) { $0[$1.key] = $1.value.value }

        let startDate: String?
        let endDate: String?
        do {
            startDate = try parseFlexibleDate(input.start_date)
            endDate = try parseFlexibleDate(input.end_date)
        } catch {
            return ticktickFailure("filter_tasks", error)
        }

        let client: TickTickClient
        do {
            client = try TickTickClient.from(secrets: input._secrets, config: cfgDict)
        } catch {
            return ticktickFailure("filter_tasks", error)
        }

        do {
            let tasks = try client.filterTasks(
                projectIds: input.project_ids,
                startDate: startDate,
                endDate: endDate,
                priority: input.priority,
                tags: input.tags,
                status: input.status
            )
            let out = try jsonString(tasks.map(PublicTask.init))
            return successResult(out)
        } catch {
            return ticktickFailure("filter_tasks", error)
        }
    }
}

// MARK: - Tool: get_tasks_due_today

struct GetTasksDueTodayTool {
    let name = "get_tasks_due_today"

    struct Args: Decodable {
        let project_id: String?
        let _secrets: [String: String]?
        let _config: [String: AnyCodable]?
    }

    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return Envelope.failure(.invalidArgs, "Invalid arguments")
        }
        let cfgDict: [String: Any]? = input._config?.reduce(into: [:]) { $0[$1.key] = $1.value.value }

        let client: TickTickClient
        do {
            client = try TickTickClient.from(secrets: input._secrets, config: cfgDict)
        } catch {
            return ticktickFailure("get_tasks_due_today", error)
        }

        do {
            let cal = Calendar(identifier: .gregorian)
            var calTZ = cal
            calTZ.timeZone = userTimeZone
            let todayStart = calTZ.startOfDay(for: Date())
            let todayEnd = calTZ.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart

            let allTasks: [TickTickClient.Task]
            if let pid = input.project_id, !pid.isEmpty {
                let pd = try client.getProjectData(pid)
                allTasks = pd.tasks ?? []
            } else {
                allTasks = try client.getAllTasks()
            }

            let due = allTasks.filter { t in
                guard (t.status ?? 0) == 0, let due = t.dueDate else { return false }
                guard let d = parseISO(due) else { return false }
                return d >= todayStart && d < todayEnd
            }
            let out = try jsonString(due.map(PublicTask.init))
            return successResult(out)
        } catch {
            return ticktickFailure("get_tasks_due_today", error)
        }
    }
}

// MARK: - Tool: get_overdue_tasks

struct GetOverdueTasksTool {
    let name = "get_overdue_tasks"

    struct Args: Decodable {
        let project_id: String?
        let max_days_overdue: Int?
        let _secrets: [String: String]?
        let _config: [String: AnyCodable]?
    }

    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return Envelope.failure(.invalidArgs, "Invalid arguments")
        }
        let cfgDict: [String: Any]? = input._config?.reduce(into: [:]) { $0[$1.key] = $1.value.value }

        let client: TickTickClient
        do {
            client = try TickTickClient.from(secrets: input._secrets, config: cfgDict)
        } catch {
            return ticktickFailure("get_overdue_tasks", error)
        }

        do {
            let now = Date()
            let maxDays = input.max_days_overdue

            let allTasks: [TickTickClient.Task]
            if let pid = input.project_id, !pid.isEmpty {
                let pd = try client.getProjectData(pid)
                allTasks = pd.tasks ?? []
            } else {
                allTasks = try client.getAllTasks()
            }

            let overdue = allTasks.filter { t in
                guard (t.status ?? 0) == 0, let due = t.dueDate else { return false }
                guard let d = parseISO(due) else { return false }
                if d >= now { return false }
                if let maxDays {
                    let cutoff = now.addingTimeInterval(-Double(maxDays) * 86_400)
                    if d < cutoff { return false }
                }
                return true
            }
            let out = try jsonString(overdue.map(PublicTask.init))
            return successResult(out)
        } catch {
            return ticktickFailure("get_overdue_tasks", error)
        }
    }
}

// MARK: - ISO parse helper

func parseISO(_ s: String) -> Date? {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = fmt.date(from: s) { return d }
    fmt.formatOptions = [.withInternetDateTime]
    return fmt.date(from: s)
}

// MARK: - Public (output) models

/// Stable, documented JSON shape returned to the LLM. Field names match
/// the manifest's documented parameter names so round-tripping is obvious.
struct PublicProject: Encodable {
    let id: String
    let name: String
    let color: String?
    let view_mode: String?
    let kind: String?
    let sort_order: Int?
    let closed: Bool?
    let group_id: String?
    let permission: String?

    init(_ p: TickTickClient.Project) {
        id = p.id
        name = p.name
        color = p.color
        view_mode = p.viewMode
        kind = p.kind
        sort_order = p.sortOrder
        closed = p.closed
        group_id = p.groupId
        permission = p.permission
    }
}

struct PublicTask: Encodable {
    let id: String
    let title: String
    let project_id: String?
    let content: String?
    let desc: String?
    let priority: Int?          // friendly 0-4
    let start_date: String?
    let due_date: String?
    let is_all_day: Bool?
    let tags: [String]?
    let time_zone: String?
    let parent_id: String?
    let status: String?         // "active" | "completed"
    let kind: String?
    let reminders: [String]?
    let repeat_flag: String?
    let sort_order: Int?
    let items: [PublicChecklistItem]?
    let completed_time: String?

    init(_ t: TickTickClient.Task) {
        id = t.id
        title = t.title
        project_id = t.projectId
        content = t.content
        desc = t.desc
        priority = mapPriorityToFriendly(t.priority)
        start_date = t.startDate
        due_date = t.dueDate
        is_all_day = t.isAllDay
        tags = t.tags
        time_zone = t.timeZone
        parent_id = t.parentId
        status = (t.status == 2) ? "completed" : "active"
        kind = t.kind
        reminders = t.reminders
        repeat_flag = t.repeatFlag
        sort_order = t.sortOrder
        items = t.items?.map(PublicChecklistItem.init)
        completed_time = t.completedTime
    }
}

struct PublicChecklistItem: Encodable {
    let id: String?
    let title: String?
    let start_date: String?
    let is_all_day: Bool?
    let sort_order: Int?
    let status: String?
    let time_zone: String?
    let completed_time: String?

    init(_ i: TickTickClient.ChecklistItem) {
        id = i.id
        title = i.title
        start_date = i.startDate
        is_all_day = i.isAllDay
        sort_order = i.sortOrder
        status = (i.status == 2) ? "completed" : "active"
        time_zone = i.timeZone
        completed_time = i.completedTime
    }
}

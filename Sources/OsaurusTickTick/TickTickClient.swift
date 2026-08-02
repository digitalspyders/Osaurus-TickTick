//
//  TickTickClient.swift
//  osaurus-ticktick
//
//  Synchronous HTTP client for the TickTick Open API v1.
//
//  Base URL:  https://api.ticktick.com/open/v1
//             (https://api.dida365.com/open/v1 for the China variant)
//  Auth:      Authorization: Bearer <access_token>
//

import Foundation
import OsaurusPluginABI
import OsaurusPluginKit

/// Errors surfaced by the client. Mapped to canonical envelopes at the
/// tool boundary.
enum TickTickClientError: Error {
    case notConfigured      // access token missing
    case httpError(Int, String)
    case transport(String)
    case decoding(String)
    case timeout(String)
}

/// URLSession delegate that collects the response synchronously via a
/// semaphore. Modeled on the official `osaurus-fetch` plugin's pattern:
/// ephemeral session, delegate-based callbacks, bounded semaphore wait,
/// `invalidateAndCancel` after the wait returns.
private final class TickTickHTTPDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var status: Int = 0
    var collected = Data()
    var taskError: Error?
    var timedOut = false
    private let semaphore = DispatchSemaphore(value: 0)

    func wait(timeout: TimeInterval) {
        let result = semaphore.wait(timeout: .now() + timeout)
        if case .timedOut = result {
            timedOut = true
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            status = http.statusCode
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        collected.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            taskError = error
        }
        semaphore.signal()
    }
}

/// Thread-safe box for capturing URLSession completion results across
/// the semaphore boundary without tripping Swift 6 sendable diagnostics.
private final class ResponseBox: @unchecked Sendable {
    var status: Int = 0
    var data: Data = Data()
    var error: Error?
}

/// One-shot client. A new instance is built per tool invocation from the
/// secrets + config in the payload, so there is no shared mutable state.
struct TickTickClient {

    let accessToken: String
    let baseURL: String

    /// Build a client from the `_secrets` and `_config` blocks Osaurus
    /// injects into every tool payload. Checks the host's persistent
    /// config storage first (where `connect_account` stores the OAuth
    /// token), then falls back to an `access_token` secret if someone
    /// set one directly.
    ///
    /// If no token exists but client_id and client_secret are present,
    /// auto-runs the OAuth flow so the user doesn't have to manually
    /// call connect_account.
    static func from(secrets: [String: String]?, config: [String: Any]?) throws -> TickTickClient {
        // 1. Check host config storage (set by connect_account tool)
        let token = HostBridge.shared.configGet("access_token")
            ?? secrets?["access_token"]

        if let token, !token.isEmpty {
            let useDida365 = (config?["use_dida365"] as? Bool) == true
            let host = useDida365 ? "https://api.dida365.com" : "https://api.ticktick.com"
            return TickTickClient(accessToken: token, baseURL: "\(host)/open/v1")
        }

        // 2. No token — but if credentials are present, auto-run OAuth
        if let clientId = secrets?["client_id"], !clientId.isEmpty,
           let clientSecret = secrets?["client_secret"], !clientSecret.isEmpty {
            HostBridge.shared.log(1, "ticktick: no token found, auto-running OAuth")
            OAuthFlow.run(
                clientId: clientId,
                clientSecret: clientSecret,
                redirectUri: "http://127.0.0.1:8080/"
            )
            // After OAuth, try reading the token again
            if let newToken = HostBridge.shared.configGet("access_token"), !newToken.isEmpty {
                let useDida365 = (config?["use_dida365"] as? Bool) == true
                let host = useDida365 ? "https://api.dida365.com" : "https://api.ticktick.com"
                return TickTickClient(accessToken: newToken, baseURL: "\(host)/open/v1")
            }
        }

        throw TickTickClientError.notConfigured
    }

    // MARK: - Request helpers

    /// Synchronous HTTP request using a dedicated ephemeral URLSession
    /// with a delegate (never `URLSession.shared`). The semaphore wait
    /// has a hard timeout so a stalled network call can never deadlock
    /// the host's main thread — the #1 plugin crash/hang source audited
    /// across the Osaurus plugin ecosystem.
    private func request(
        method: String,
        path: String,
        query: [(String, String)] = [],
        body: Data? = nil
    ) throws -> (Int, Data) {
        var components = URLComponents(string: baseURL + path)
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components?.url else {
            throw TickTickClientError.transport("malformed URL: \(path)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }

        let delegate = TickTickHTTPDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 4
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: req)
        task.resume()
        delegate.wait(timeout: 35)   // URLRequest timeout (30) + 5s grace
        session.invalidateAndCancel()

        if delegate.timedOut {
            throw TickTickClientError.timeout("request timed out after 35s")
        }
        if let error = delegate.taskError {
            throw TickTickClientError.transport(error.localizedDescription)
        }
        return (delegate.status, delegate.collected)
    }

    /// Decodes a JSON body into `T`; an empty body returns `nil`.
    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T? {
        if data.isEmpty { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TickTickClientError.decoding(error.localizedDescription)
        }
    }

    /// Maps an HTTP status + body into either decoded JSON or a
    /// `TickTickClientError`. 204 is treated as success-with-no-body.
    private func handle<T: Decodable>(
        status: Int,
        data: Data,
        as type: T.Type
    ) throws -> T? {
        switch status {
        case 200...299:
            return try decode(T.self, from: data)
        case 401:
            throw TickTickClientError.httpError(401, "Access token is missing or expired")
        case 404:
            throw TickTickClientError.httpError(404, "Resource not found")
        default:
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            throw TickTickClientError.httpError(status, msg)
        }
    }

    // MARK: - Projects

    struct Project: Decodable {
        let id: String
        let name: String
        let color: String?
        let viewMode: String?
        let kind: String?
        let sortOrder: Int?
        let closed: Bool?
        let groupId: String?
        let permission: String?
    }

    func listProjects() throws -> [Project] {
        let (status, data) = try request(method: "GET", path: "/project")
        return try handle(status: status, data: data, as: [Project].self) ?? []
    }

    func getProject(_ id: String) throws -> Project {
        let (status, data) = try request(method: "GET", path: "/project/\(encode(id))")
        guard let p: Project = try handle(status: status, data: data, as: Project.self) else {
            throw TickTickClientError.decoding("project body was empty")
        }
        return p
    }

    struct Column: Decodable {
        let id: String
        let projectId: String?
        let name: String?
        let sortOrder: Int?
    }

    struct ProjectData: Decodable {
        let project: Project?
        let tasks: [Task]?
        let columns: [Column]?
    }

    /// `GET /project/{id}/data` — project + all its tasks.
    func getProjectData(_ id: String) throws -> ProjectData {
        let (status, data) = try request(method: "GET", path: "/project/\(encode(id))/data")
        return try handle(status: status, data: data, as: ProjectData.self)
            ?? ProjectData(project: nil, tasks: nil, columns: nil)
    }

    /// `GET /project/inbox/data` — the Inbox is a special project that
    /// does NOT appear in `GET /project`. This endpoint returns its tasks.
    /// The response shape is `{columns, tasks}` (no `project` field).
    func getInboxData() throws -> [Task] {
        let (status, data) = try request(method: "GET", path: "/project/inbox/data")
        // The inbox response may not include a `project` field, so we
        // decode just the tasks array directly.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tasksArray = json["tasks"] as? [[String: Any]] {
            let tasksData = try JSONSerialization.data(withJSONObject: tasksArray)
            return (try? JSONDecoder().decode([Task].self, from: tasksData)) ?? []
        }
        // Fallback: try full ProjectData decode
        let pd = try handle(status: status, data: data, as: ProjectData.self)
        return pd?.tasks ?? []
    }

    /// Fetches all tasks across all projects AND the Inbox. Useful for
    /// search and aggregation tools where missing the Inbox would give
    /// incomplete results.
    func getAllTasks() throws -> [Task] {
        var all: [Task] = []
        // Inbox first (it's where newly created tasks land by default)
        if let inbox = try? getInboxData() {
            all.append(contentsOf: inbox)
        }
        // Then all projects
        let projects = try listProjects()
        for p in projects {
            if let pd = try? getProjectData(p.id), let tasks = pd.tasks {
                all.append(contentsOf: tasks)
            }
        }
        return all
    }

    struct CreateProjectBody: Encodable {
        let name: String
        let color: String?
        let kind: String?
        let viewMode: String?
        let sortOrder: Int?
    }

    func createProject(name: String, color: String?, kind: String?, viewMode: String?, sortOrder: Int?) throws -> Project {
        let body = CreateProjectBody(name: name, color: color, kind: kind, viewMode: viewMode, sortOrder: sortOrder)
        let data = try JSONEncoder().encode(body)
        let (status, resp) = try request(method: "POST", path: "/project", body: data)
        guard let p: Project = try handle(status: status, data: resp, as: Project.self) else {
            throw TickTickClientError.decoding("created project body was empty")
        }
        return p
    }

    struct UpdateProjectBody: Encodable {
        let name: String?
        let color: String?
        let kind: String?
        let viewMode: String?
        let sortOrder: Int?
    }

    func updateProject(id: String, name: String?, color: String?, kind: String?, viewMode: String?, sortOrder: Int?) throws -> Project {
        let body = UpdateProjectBody(name: name, color: color, kind: kind, viewMode: viewMode, sortOrder: sortOrder)
        let data = try JSONEncoder().encode(body)
        let (status, resp) = try request(method: "POST", path: "/project/\(encode(id))", body: data)
        guard let p: Project = try handle(status: status, data: resp, as: Project.self) else {
            throw TickTickClientError.decoding("updated project body was empty")
        }
        return p
    }

    func deleteProject(_ id: String) throws {
        let (status, _) = try request(method: "DELETE", path: "/project/\(encode(id))")
        if !(200...299).contains(status) {
            throw TickTickClientError.httpError(status, "delete project failed")
        }
    }

    // MARK: - Tasks

    struct Task: Decodable {
        let id: String
        let title: String
        let projectId: String?
        let content: String?
        let desc: String?
        let priority: Int?
        let startDate: String?
        let dueDate: String?
        let isAllDay: Bool?
        let tags: [String]?
        let timeZone: String?
        let parentId: String?
        let status: Int?
        let kind: String?
        let reminders: [String]?
        let repeatFlag: String?
        let sortOrder: Int?
        let items: [ChecklistItem]?
        let completedTime: String?
    }

    struct ChecklistItem: Decodable {
        let id: String?
        let title: String?
        let startDate: String?
        let isAllDay: Bool?
        let sortOrder: Int?
        let status: Int?
        let timeZone: String?
        let completedTime: String?
    }

    func getTask(projectId: String, taskId: String) throws -> Task {
        let (status, data) = try request(
            method: "GET",
            path: "/project/\(encode(projectId))/task/\(encode(taskId))"
        )
        guard let t: Task = try handle(status: status, data: data, as: Task.self) else {
            throw TickTickClientError.decoding("task body was empty")
        }
        return t
    }

    struct CreateTaskBody: Encodable {
        let title: String
        let projectId: String?
        let content: String?
        let desc: String?
        let priority: Int?
        let startDate: String?
        let dueDate: String?
        let isAllDay: Bool?
        let tags: [String]?
        let timeZone: String?
        let parentId: String?
        let reminders: [String]?
        let repeatFlag: String?
        let sortOrder: Int?
        let items: [CreateChecklistItem]?
    }

    struct CreateChecklistItem: Encodable {
        let title: String
        let startDate: String?
        let isAllDay: Bool?
        let sortOrder: Int?
        let timeZone: String?
    }

    func createTask(
        title: String,
        projectId: String?,
        content: String?,
        desc: String?,
        priority: Int?,
        startDate: String?,
        dueDate: String?,
        isAllDay: Bool?,
        tags: [String]?,
        timeZone: String?,
        parentId: String?,
        reminders: [String]?,
        repeatFlag: String?,
        sortOrder: Int?,
        items: [CreateChecklistItem]?
    ) throws -> Task {
        let body = CreateTaskBody(
            title: title, projectId: projectId, content: content, desc: desc,
            priority: priority, startDate: startDate, dueDate: dueDate,
            isAllDay: isAllDay, tags: tags, timeZone: timeZone, parentId: parentId,
            reminders: reminders, repeatFlag: repeatFlag, sortOrder: sortOrder, items: items
        )
        let data = try JSONEncoder().encode(body)
        let (status, resp) = try request(method: "POST", path: "/task", body: data)
        guard let t: Task = try handle(status: status, data: resp, as: Task.self) else {
            throw TickTickClientError.decoding("created task body was empty")
        }
        return t
    }

    struct UpdateTaskBody: Encodable {
        let id: String
        let projectId: String
        let title: String?
        let content: String?
        let desc: String?
        let priority: Int?
        let startDate: String?
        let dueDate: String?
        let isAllDay: Bool?
        let tags: [String]?
        let timeZone: String?
        let parentId: String?
        let reminders: [String]?
        let repeatFlag: String?
        let sortOrder: Int?
        let items: [UpdateChecklistItem]?
    }

    struct UpdateChecklistItem: Encodable {
        let id: String?
        let title: String?
        let startDate: String?
        let isAllDay: Bool?
        let sortOrder: Int?
        let status: Int?
        let timeZone: String?
        let completedTime: String?
    }

    func updateTask(
        projectId: String,
        taskId: String,
        title: String?,
        content: String?,
        desc: String?,
        priority: Int?,
        startDate: String?,
        dueDate: String?,
        isAllDay: Bool?,
        tags: [String]?,
        timeZone: String?,
        parentId: String?,
        reminders: [String]?,
        repeatFlag: String?,
        sortOrder: Int?,
        items: [UpdateChecklistItem]?
    ) throws -> Task {
        let body = UpdateTaskBody(
            id: taskId, projectId: projectId, title: title, content: content, desc: desc,
            priority: priority, startDate: startDate, dueDate: dueDate,
            isAllDay: isAllDay, tags: tags, timeZone: timeZone, parentId: parentId,
            reminders: reminders, repeatFlag: repeatFlag, sortOrder: sortOrder, items: items
        )
        let data = try JSONEncoder().encode(body)
        let (status, resp) = try request(method: "POST", path: "/task/\(encode(taskId))", body: data)
        guard let t: Task = try handle(status: status, data: resp, as: Task.self) else {
            throw TickTickClientError.decoding("updated task body was empty")
        }
        return t
    }

    func completeTask(projectId: String, taskId: String) throws {
        let (status, _) = try request(
            method: "POST",
            path: "/project/\(encode(projectId))/task/\(encode(taskId))/complete"
        )
        if !(200...299).contains(status) {
            throw TickTickClientError.httpError(status, "complete task failed")
        }
    }

    func deleteTask(projectId: String, taskId: String) throws {
        let (status, _) = try request(
            method: "DELETE",
            path: "/project/\(encode(projectId))/task/\(encode(taskId))"
        )
        if !(200...299).contains(status) {
            throw TickTickClientError.httpError(status, "delete task failed")
        }
    }

    // MARK: - Task: Move

    struct MoveTaskBody: Encodable {
        let fromProjectId: String
        let toProjectId: String
        let taskId: String
    }

    struct MoveResult: Decodable {
        let taskId: String?
        let etag: String?
    }

    /// `POST /task/move` — moves a task from one project to another.
    func moveTask(fromProjectId: String, toProjectId: String, taskId: String) throws {
        let body = MoveTaskBody(fromProjectId: fromProjectId, toProjectId: toProjectId, taskId: taskId)
        let data = try JSONEncoder().encode([body])
        let (status, _) = try request(method: "POST", path: "/task/move", body: data)
        if !(200...299).contains(status) {
            throw TickTickClientError.httpError(status, "move task failed")
        }
    }

    // MARK: - Task: Completed

    struct CompletedTasksBody: Encodable {
        let projectIds: [String]?
        let startDate: String?
        let endDate: String?
    }

    /// `POST /task/completed` — retrieves tasks completed within a time range.
    func getCompletedTasks(projectIds: [String]?, startDate: String?, endDate: String?) throws -> [Task] {
        let body = CompletedTasksBody(projectIds: projectIds, startDate: startDate, endDate: endDate)
        let data = try JSONEncoder().encode(body)
        let (status, resp) = try request(method: "POST", path: "/task/completed", body: data)
        return try handle(status: status, data: resp, as: [Task].self) ?? []
    }

    // MARK: - Task: Filter

    struct FilterTasksBody: Encodable {
        let projectIds: [String]?
        let startDate: String?
        let endDate: String?
        let priority: [Int]?
        let tag: [String]?
        let status: [Int]?
    }

    /// `POST /task/filter` — retrieves tasks matching advanced filter criteria.
    func filterTasks(
        projectIds: [String]?,
        startDate: String?,
        endDate: String?,
        priority: [Int]?,
        tags: [String]?,
        status: [Int]?
    ) throws -> [Task] {
        let body = FilterTasksBody(
            projectIds: projectIds, startDate: startDate, endDate: endDate,
            priority: priority, tag: tags, status: status
        )
        let data = try JSONEncoder().encode(body)
        let (status, resp) = try request(method: "POST", path: "/task/filter", body: data)
        return try handle(status: status, data: resp, as: [Task].self) ?? []
    }

    // MARK: - URL path encoding

    /// Percent-encodes a path segment (TickTick ids are alphanumeric but
    /// this guards against any odd characters).
    private func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}

// MARK: - Error → Envelope mapping

/// Maps a `TickTickClientError` to a canonical failure envelope string.
func ticktickFailure(_ context: String, _ error: Error) -> String {
    switch error {
    case TickTickClientError.notConfigured:
        return Envelope.failure(
            .permissionDenied,
            "TickTick is not connected. Make sure your Client ID, Client Secret, and Redirect URL are configured in Osaurus → Tools → TickTick, then call the connect_account tool to authorize.",
            retryable: false
        )
    case let TickTickClientError.httpError(code, msg):
        let kind: Envelope.Kind = (code == 404) ? .notFound : .executionError
        return Envelope.failure(kind, "\(context): HTTP \(code) — \(msg)")
    case let TickTickClientError.transport(msg):
        return Envelope.failure(.executionError, "\(context): \(msg)")
    case let TickTickClientError.timeout(msg):
        return Envelope.failure(.timeout, "\(context): \(msg)")
    case let TickTickClientError.decoding(msg):
        return Envelope.failure(.executionError, "\(context): bad response — \(msg)")
    case let e as EnvelopeFailure:
        return e.render()
    default:
        return Envelope.failure(.executionError, "\(context): \(error.localizedDescription)")
    }
}

import Foundation

/// Model state as reported by the control service (`GET /status`).
enum ModelStatus: String {
    case running, loading, stopped
    case unreachable, unauthorized, unknown
}

struct ModelInfo {
    var name: String = ""
    var quant: String = ""
    var params: Int64 = 0
    var sizeBytes: Int64 = 0
    var ctx: Int = 0
    var ctxTrain: Int = 0
    var vocab: Int = 0
    var vision = false
    var audio = false
    var webUI = false
}

struct SlotsInfo {
    var total = 0
    var busy = 0
}

/// Model launch settings from the control service (`GET /config`); the token is never returned.
struct ServiceConfig {
    var ctx: Int
    var ngl: Int?
}

struct SpeedResult {
    var promptTPS: Double
    var genTPS: Double
    var tokens: Int
}

enum APIError: LocalizedError {
    case http(Int, String)
    case badResponse
    case noConfigEndpoint
    var errorDescription: String? {
        switch self {
        case .http(let code, let msg): return "HTTP \(code)\(msg.isEmpty ? "" : ": \(msg)")"
        case .badResponse: return "Непонятный ответ сервера"
        case .noConfigEndpoint:
            return "Сервис управления на ПК старой версии и не умеет менять контекст. Обновите control-server.ps1 на ПК."
        }
    }
}

/// Talks to the control service (start/stop/status) and to llama-server (info, slots, speed test).
struct AIClient {
    var host: String
    var controlPort: Int
    var llamaPort: Int
    var token: String

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.timeoutIntervalForResource = 120
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    var controlBase: String { "http://\(host):\(controlPort)" }
    var llamaBase: String { "http://\(host):\(llamaPort)" }

    private func request(_ url: String, method: String = "GET", body: [String: Any]? = nil,
                         auth: Bool = true, timeout: TimeInterval = 4) async throws -> (Int, Data) {
        guard let u = URL(string: url) else { throw APIError.badResponse }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = method
        if auth && !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await Self.session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        return (http.statusCode, data)
    }

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: control service

    func status() async -> (ModelStatus, TimeInterval) {
        let t0 = Date()
        do {
            let (code, data) = try await request(controlBase + "/status")
            let ms = Date().timeIntervalSince(t0)
            if code == 401 || code == 403 { return (.unauthorized, ms) }
            guard code == 200 else { return (.unknown, ms) }
            let s = json(data)["status"] as? String ?? ""
            return (ModelStatus(rawValue: s) ?? .unknown, ms)
        } catch {
            return (.unreachable, 0)
        }
    }

    func start() async throws -> ModelStatus { try await control("/start") }
    func stop() async throws -> ModelStatus { try await control("/stop") }

    private func control(_ path: String) async throws -> ModelStatus {
        let (code, data) = try await request(controlBase + path, method: "POST", timeout: 30)
        guard code == 200 else { throw APIError.http(code, json(data)["error"] as? String ?? "") }
        return ModelStatus(rawValue: json(data)["status"] as? String ?? "") ?? .unknown
    }

    /// Current launch settings. Throws `.noConfigEndpoint` when the service predates `/config`.
    func config() async throws -> ServiceConfig {
        let (code, data) = try await request(controlBase + "/config")
        if code == 404 { throw APIError.noConfigEndpoint }
        guard code == 200 else { throw APIError.http(code, json(data)["error"] as? String ?? "") }
        let j = json(data)
        guard let ctx = (j["ctx"] as? NSNumber)?.intValue else { throw APIError.badResponse }
        return ServiceConfig(ctx: ctx, ngl: (j["ngl"] as? NSNumber)?.intValue)
    }

    /// Saves a new context size; the service writes config.json and restarts llama-server.
    func setConfig(ctx: Int) async throws -> ModelStatus {
        let (code, data) = try await request(controlBase + "/config", method: "POST", body: ["ctx": ctx], timeout: 60)
        if code == 404 { throw APIError.noConfigEndpoint }
        guard code == 200 else { throw APIError.http(code, json(data)["error"] as? String ?? "") }
        return ModelStatus(rawValue: json(data)["status"] as? String ?? "") ?? .unknown
    }

    // MARK: llama-server

    func health() async -> Bool {
        guard let (code, _) = try? await request(llamaBase + "/health", auth: false, timeout: 2) else { return false }
        return code == 200
    }

    func modelInfo() async -> ModelInfo? {
        guard let (code, data) = try? await request(llamaBase + "/v1/models"), code == 200 else { return nil }
        var info = ModelInfo()
        let first = (json(data)["data"] as? [[String: Any]])?.first ?? [:]
        let id = first["id"] as? String ?? ""
        info.name = id.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? id
        if let meta = first["meta"] as? [String: Any] {
            info.quant = meta["ftype"] as? String ?? ""
            info.params = (meta["n_params"] as? NSNumber)?.int64Value ?? 0
            info.sizeBytes = (meta["size"] as? NSNumber)?.int64Value ?? 0
            info.ctx = meta["n_ctx"] as? Int ?? 0
            info.ctxTrain = meta["n_ctx_train"] as? Int ?? 0
            info.vocab = meta["n_vocab"] as? Int ?? 0
        }
        if let (pc, pdata) = try? await request(llamaBase + "/props"), pc == 200 {
            let p = json(pdata)
            if let m = p["modalities"] as? [String: Any] {
                info.vision = m["vision"] as? Bool ?? false
                info.audio = m["audio"] as? Bool ?? false
            }
            info.webUI = p["ui"] as? Bool ?? false
            if info.quant.isEmpty { info.quant = p["model_ftype"] as? String ?? "" }
        }
        return info
    }

    func slots() async -> SlotsInfo? {
        guard let (code, data) = try? await request(llamaBase + "/slots"), code == 200,
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return SlotsInfo(total: arr.count, busy: arr.filter { $0["is_processing"] as? Bool == true }.count)
    }

    /// Short generation to measure prompt and generation speed (tokens per second).
    func speedTest() async throws -> SpeedResult {
        let body: [String: Any] = [
            "prompt": "Write a short paragraph about the ocean.",
            "n_predict": 128, "cache_prompt": false, "temperature": 0.7,
        ]
        let (code, data) = try await request(llamaBase + "/completion", method: "POST", body: body, timeout: 120)
        guard code == 200, let t = json(data)["timings"] as? [String: Any] else {
            throw APIError.http(code, "")
        }
        return SpeedResult(promptTPS: t["prompt_per_second"] as? Double ?? 0,
                           genTPS: t["predicted_per_second"] as? Double ?? 0,
                           tokens: t["predicted_n"] as? Int ?? 0)
    }
}

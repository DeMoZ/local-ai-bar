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
    /// Tokens generated so far by the requests in progress (for the live tokens-per-second rate).
    var decoded = 0
}

/// Model launch settings from the control service (`GET /config`); the token is never returned.
struct ServiceConfig {
    var ctx: Int
    var ngl: Int?
    var modelId: String?
    var autoRestart: Bool?
}

/// An unexpected llama-server exit seen by the control service.
struct CrashInfo: Equatable {
    var at: String
    var exitCode: Int?
    var restarted: Bool
}

/// `GET /status`. `crash` / `autoRestart` are nil with a control service older than v0.4.
struct StatusReply {
    var status: ModelStatus
    var latency: TimeInterval
    var crash: CrashInfo?
    var autoRestart: Bool?
}

/// A model file on the PC (`GET /models`); `id` is its path inside the models folder.
struct ModelEntry: Identifiable, Hashable {
    var id: String
    var name: String
    var sizeBytes: Int64
    var vision: Bool
    var current: Bool
}

/// PC load (`GET /metrics`); nil fields are not reported by the PC.
struct PcMetrics {
    var cpu: Double?
    var gpu: Double?
    var ramTotal: Int64?
    var ramUsed: Int64?
    var gpuDedicated: Int64?
    var gpuShared: Int64?
    var llamaRam: Int64?
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
    case oldService
    var errorDescription: String? {
        switch self {
        case .http(let code, let msg): return "HTTP \(code)\(msg.isEmpty ? "" : ": \(msg)")"
        case .badResponse: return "Непонятный ответ сервера"
        case .noConfigEndpoint:
            return "Сервис управления на ПК старой версии и не умеет менять контекст. Обновите его: server/update-windows.ps1 в репозитории."
        case .oldService:
            return "Сервис управления на ПК старой версии. Обновите его: server/update-windows.ps1 в репозитории."
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

    func status() async -> StatusReply {
        let t0 = Date()
        do {
            let (code, data) = try await request(controlBase + "/status")
            let ms = Date().timeIntervalSince(t0)
            if code == 401 || code == 403 { return StatusReply(status: .unauthorized, latency: ms) }
            guard code == 200 else { return StatusReply(status: .unknown, latency: ms) }
            let j = json(data)
            var crash: CrashInfo?
            if let c = j["crash"] as? [String: Any], let at = c["at"] as? String {
                crash = CrashInfo(at: at, exitCode: (c["exitCode"] as? NSNumber)?.intValue,
                                  restarted: c["restarted"] as? Bool ?? false)
            }
            return StatusReply(status: ModelStatus(rawValue: j["status"] as? String ?? "") ?? .unknown,
                               latency: ms, crash: crash, autoRestart: j["autoRestart"] as? Bool)
        } catch {
            return StatusReply(status: .unreachable, latency: 0)
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
        return ServiceConfig(ctx: ctx, ngl: (j["ngl"] as? NSNumber)?.intValue,
                             modelId: j["modelId"] as? String, autoRestart: j["autoRestart"] as? Bool)
    }

    /// Saves launch settings (`ctx`, `model`, `autoRestart`, any subset); the service writes config.json and
    /// restarts llama-server if the model or context changed while it was on.
    func setConfig(_ body: [String: Any]) async throws -> ModelStatus {
        let (code, data) = try await request(controlBase + "/config", method: "POST", body: body, timeout: 90)
        if code == 404 { throw APIError.noConfigEndpoint }
        guard code == 200 else { throw APIError.http(code, json(data)["error"] as? String ?? "") }
        return ModelStatus(rawValue: json(data)["status"] as? String ?? "") ?? .unknown
    }

    /// Models in the PC's models folder. Throws `.oldService` when the service predates `/models`.
    func models() async throws -> [ModelEntry] {
        let (code, data) = try await request(controlBase + "/models", timeout: 10)
        if code == 404 { throw APIError.oldService }
        guard code == 200 else { throw APIError.http(code, json(data)["error"] as? String ?? "") }
        return (json(data)["models"] as? [[String: Any]] ?? []).compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            return ModelEntry(id: id, name: m["name"] as? String ?? id,
                              sizeBytes: (m["sizeBytes"] as? NSNumber)?.int64Value ?? 0,
                              vision: m["vision"] as? Bool ?? false, current: m["current"] as? Bool ?? false)
        }
    }

    /// PC load, or nil when the service predates `/metrics` or does not answer.
    func metrics() async -> PcMetrics? {
        guard let (code, data) = try? await request(controlBase + "/metrics", timeout: 8), code == 200 else { return nil }
        let j = json(data)
        let d = { (k: String) in (j[k] as? NSNumber)?.doubleValue }
        let i = { (k: String) in (j[k] as? NSNumber)?.int64Value }
        return PcMetrics(cpu: d("cpu"), gpu: d("gpu"), ramTotal: i("ramTotal"), ramUsed: i("ramUsed"),
                         gpuDedicated: i("gpuDedicated"), gpuShared: i("gpuShared"), llamaRam: i("llamaRam"))
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
        let busy = arr.filter { $0["is_processing"] as? Bool == true }
        // next_token is an object in older llama.cpp builds and an array (one per sequence) in newer ones.
        let decoded = busy.reduce(0) { sum, slot in
            let next = slot["next_token"]
            let items = (next as? [[String: Any]]) ?? ((next as? [String: Any]).map { [$0] } ?? [])
            return sum + items.reduce(0) { $0 + ((($1["n_decoded"]) as? NSNumber)?.intValue ?? 0) }
        }
        return SlotsInfo(total: arr.count, busy: busy.count, decoded: decoded)
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

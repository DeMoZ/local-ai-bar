import Foundation

/// A text in several languages: language tag ("en", "ru", "pt-BR") → string. A plain string counts as English.
struct LocalizedText: Decodable, Equatable {
    let values: [String: String]

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            values = s.isEmpty ? [:] : ["en": s]
        } else {
            values = (try? c.decode([String: String].self))?.filter { !$0.value.isEmpty } ?? [:]
        }
    }

    /// The first of `languages` that has a text (exact tag, then its base language), else English.
    func resolved(for languages: [String]) -> String? {
        let norm = { (t: String) in t.replacingOccurrences(of: "_", with: "-").lowercased() }
        let byTag = Dictionary(values.map { (norm($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        for l in languages.map(norm) {
            if let t = byTag[l] { return t }
            if let base = l.split(separator: "-").first, let t = byTag[String(base)] { return t }
        }
        return byTag["en"]
    }
}

/// One way to donate: a payment page opened in the browser (https only — the file comes from the network).
struct DonationMethod: Decodable, Identifiable, Equatable {
    let id: String
    let title: LocalizedText
    let description: LocalizedText?
    let url: URL

    private enum K: String, CodingKey { case id, title, description, url }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let link = try c.decode(String.self, forKey: .url)
        guard let url = URL(string: link), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "Not an https url")
        }
        self.url = url
        title = try c.decode(LocalizedText.self, forKey: .title)
        description = try? c.decodeIfPresent(LocalizedText.self, forKey: .description)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? link
    }
}

/// The donate panel's content, from the public `DeMoZ/donations` repository (format: its README).
/// Links are never hardcoded in the app, so they change there without a new release.
struct DonationInfo: Decodable, Equatable {
    let message: LocalizedText?
    let methods: [DonationMethod]

    private enum K: String, CodingKey { case message, methods }
    private struct Lenient: Decodable { let value: DonationMethod?
        init(from d: Decoder) throws { value = try? DonationMethod(from: d) } }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        message = try? c.decodeIfPresent(LocalizedText.self, forKey: .message)
        methods = ((try? c.decode([Lenient].self, forKey: .methods)) ?? []).compactMap(\.value)  // drop malformed
    }

    static func parse(_ data: Data) -> DonationInfo? {
        guard let info = try? JSONDecoder().decode(DonationInfo.self, from: data), !info.methods.isEmpty else { return nil }
        return info
    }
}

enum Donations {
    static let fileName = "localaibar.json"

    /// GitHub first, then the jsDelivr mirror of the same repository.
    static let sources = [
        URL(string: "https://raw.githubusercontent.com/DeMoZ/donations/main/\(fileName)")!,
        URL(string: "https://cdn.jsdelivr.net/gh/DeMoZ/donations@main/\(fileName)")!,
    ]

    /// `~/Library/Caches/LocalAIBar/donations.json` — the last good copy, for when the network fails.
    static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalAIBar", isDirectory: true).appendingPathComponent("donations.json")
    }

    static func cached() -> DonationInfo? { (try? Data(contentsOf: cacheURL)).flatMap(DonationInfo.parse) }

    static func download() async -> DonationInfo? {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        for source in sources {
            var r = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            r.setValue("LocalAIBar", forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await session.data(for: r),
                  (resp as? HTTPURLResponse)?.statusCode == 200, let info = DonationInfo.parse(data) else { continue }
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
            return info
        }
        return nil
    }

    /// The app's interface is Russian, so texts prefer Russian, then the system languages, then English.
    static var languages: [String] { ["ru"] + Locale.preferredLanguages }
}

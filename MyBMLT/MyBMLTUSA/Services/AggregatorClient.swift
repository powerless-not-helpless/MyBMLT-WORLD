import Foundation

/// The only type in the app that knows a URL exists.
///
/// All requests go to the BMLT **aggregator**, which merges ~200 root servers
/// into one endpoint. Verified live: 1,571 service bodies, US-wide coverage
/// (419 meetings within 10 mi of NYC, 246 within 10 mi of San Diego).
///
/// URLs are built with `URLComponents`, never string concatenation — a search
/// term containing a space must not produce an invalid URL.
actor AggregatorClient {

    static let baseURL = URL(string: "https://aggregator.bmltenabled.org/main_server")!

    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Query description

    /// Verified parameter names and behaviours are noted per case.
    enum Query {
        /// Meetings for one or more service bodies, recursively down the tree.
        /// Verified: `services=2313&recursive=1` → 377 SDICR meetings.
        case serviceBodies(ids: [Int], recursive: Bool)

        /// Radius search. Verified to **cross service body boundaries** and to
        /// return server-computed `distance_in_miles`. Works with no `services`
        /// filter at all.
        case geo(latitude: Double, longitude: Double, radiusMiles: Double)

        /// Fetch specific meetings by local ID.
        ///
        /// **A bare `id_bigint` is ambiguous and resolving it unscoped is a
        /// correctness bug.** Verified live against the aggregator:
        ///
        /// - `meeting_ids=1,2,3,...,60` returns 13 rows, **all on root server
        ///   1**. The aggregator resolves an unscoped id against the first root
        ///   server that owns it and silently omits the rest.
        /// - `root_server_ids[]=1` alongside `meeting_ids=148884` returns 0,
        ///   proving that parameter genuinely filters. The plural forms
        ///   (`root_servers[]`, `server_ids[]`) and the *singular*
        ///   `root_server_id` are all silently ignored.
        ///
        /// So `rootServerIDs` is mandatory, not an optimisation. Fetching an
        /// out-of-Area favourite without it would diff the saved record against
        /// an unrelated meeting on another server — the same `uid` aliasing
        /// hazard documented on `Meeting`, but on the request path.
        ///
        /// `meeting_ids` is global: one call **can** span root servers (verified
        /// returning roots 1 and 38 together), so `rootServerIDs` is a filter,
        /// not a per-server batch loop. An id that exists on none of the listed
        /// servers is simply absent from the response; a nonexistent id returns
        /// an empty array, not an error.
        ///
        /// Bracket form is required for both parameters. `meeting_ids=148884`
        /// (comma) works, but `root_server_ids=38,1` silently returns only the
        /// first server's rows — a quiet wrong answer, so we always emit paired
        /// `root_server_ids[]` entries.
        case meetingIDs(ids: [Int], rootServerIDs: [Int])
    }

    // MARK: - Errors

    enum ClientError: LocalizedError {
        case badStatus(Int)
        case malformedURL
        case emptyResponse
        case serverMessage(String)

        var errorDescription: String? {
            switch self {
            case .badStatus(let code):
                return "The meeting server returned an error (\(code))."
            case .malformedURL:
                return "Could not build a valid request."
            case .emptyResponse:
                return "The meeting server returned no data."
            case .serverMessage(let msg):
                return msg
            }
        }
    }

    // MARK: - Meetings

    func meetings(_ query: Query) async throws -> [Meeting] {
        let url = try buildURL(for: query)
        let payload = try await fetchSearchPayload(url)
        return payload.meetings.compactMap { $0.toMeeting() }
    }

    /// Meetings plus the format labels the server knows about, for the same
    /// query. Used by the Meetings tab so format chips show names, not codes.
    func meetingsAndFormats(_ query: Query) async throws -> (meetings: [Meeting], formats: [String: String]) {
        let url = try buildURL(for: query, includeFormats: true)
        let payload = try await fetchSearchPayload(url)

        // Formats are per-root-server, so later rows must not clobber earlier
        // ones for the same key from a different server. First wins.
        var labels: [String: String] = [:]
        for format in payload.formats {
            guard let key = format.key, let name = format.name_string, !name.isEmpty else { continue }
            if labels[key] == nil { labels[key] = name }
        }
        return (payload.meetings.compactMap { $0.toMeeting() }, labels)
    }

    // MARK: - Service bodies

    /// The full service body graph (~1,571 rows). Cache this for days.
    func serviceBodies() async throws -> ServiceBodyTree {
        let url = try buildURL(switcher: "GetServiceBodies")
        let data = try await fetch(url)

        struct RawBody: Codable {
            let id: String?
            let parent_id: String?
            let name: String?
            let description: String?
            let type: String?
            let url: String?
            let helpline: String?
            let world_id: String?
            let root_server_id: Int?
        }

        let raw = try decode([RawBody].self, from: data, url: url)
        let bodies = raw.compactMap { r -> ServiceBody? in
            guard let idStr = r.id, let id = Int(idStr) else { return nil }
            return ServiceBody(
                id: id,
                parentID: Int(r.parent_id ?? ""),
                name: r.name ?? "",
                description: r.description,
                type: r.type ?? "",
                url: r.url,
                helpline: r.helpline,
                worldID: r.world_id,
                rootServerID: r.root_server_id ?? 0
            )
        }
        return ServiceBodyTree(bodies)
    }

    // MARK: - URL building

    /// The query items for a `Query`, exposed for testing.
    ///
    /// `nonisolated` because it is pure: it maps a value to query items and
    /// touches no session state. Marking it so also keeps it callable from
    /// tests without hopping actors, which is the point of exposing it.
    ///
    /// `internal` rather than `private` deliberately. The parameter *names and
    /// shapes* are the load-bearing part of this API — the aggregator silently
    /// ignores `root_server_id` (singular), `root_servers[]` and
    /// `server_ids[]`, and silently drops all but the first server for the
    /// comma form `root_server_ids=38,1`. Every one of those failures returns a
    /// plausible-looking JSON payload, so a regression here cannot be caught by
    /// a status code. See `AggregatorClientTests`.
    nonisolated func queryItems(for query: Query) -> [URLQueryItem] {
        switch query {
        case .serviceBodies(let ids, let recursive):
            var items = [URLQueryItem(name: "services[]",
                                      value: ids.map(String.init).joined(separator: ","))]
            if recursive { items.append(URLQueryItem(name: "recursive", value: "1")) }
            return items

        case .geo(let lat, let lon, let radius):
            return [
                URLQueryItem(name: "lat_val", value: String(lat)),
                URLQueryItem(name: "long_val", value: String(lon)),
                URLQueryItem(name: "geo_width", value: String(radius)),
            ]

        case .meetingIDs(let ids, let rootServerIDs):
            // Paired bracket form. Omitting the root filter lets a bare id
            // resolve against the wrong server; the comma form drops servers.
            return ids.map { URLQueryItem(name: "meeting_ids[]", value: String($0)) }
                + rootServerIDs.map {
                    URLQueryItem(name: "root_server_ids[]", value: String($0))
                }
        }
    }

    private func buildURL(for query: Query, includeFormats: Bool = false) throws -> URL {
        try buildURL(switcher: "GetSearchResults",
                     extra: queryItems(for: query),
                     includeFormats: includeFormats)
    }

    private func buildURL(switcher: String,
                          extra: [URLQueryItem] = [],
                          includeFormats: Bool = false) throws -> URL {
        guard var comps = URLComponents(url: Self.baseURL
            .appendingPathComponent("client_interface")
            .appendingPathComponent("json"), resolvingAgainstBaseURL: false)
        else { throw ClientError.malformedURL }

        var items = [URLQueryItem(name: "switcher", value: switcher)]
        items.append(contentsOf: extra)
        // lang_enum filters to one language; meetings exist in several.
        items.append(URLQueryItem(name: "lang_enum", value: "en"))
        if includeFormats {
            items.append(URLQueryItem(name: "get_used_formats", value: "1"))
        }
        comps.queryItems = items

        guard let url = comps.url else { throw ClientError.malformedURL }
        return url
    }

    // MARK: - Transport

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.badStatus(http.statusCode)
        }
        guard !data.isEmpty else { throw ClientError.emptyResponse }

        // The server reports bad switcher names as a JSON object with
        // "message", not an HTTP error. Surface that instead of a decode
        // failure.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = obj["message"] as? String {
            throw ClientError.serverMessage(message)
        }
        return data
    }

    private func fetchSearchPayload(_ url: URL) async throws -> BMLTSearchPayload {
        let data = try await fetch(url)
        return try decode(BMLTSearchPayload.self, from: data, url: url)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, url: URL) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            #if DEBUG
            let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
            print("""
            [AggregatorClient] Decode failed for \(T.self)
              URL: \(url.absoluteString)
              Error: \(error)
              Body: \(preview)
            """)
            #endif
            throw error
        }
    }
}

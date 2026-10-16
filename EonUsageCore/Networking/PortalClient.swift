import Foundation

/// Talks to the two SAP Gateway OData services behind https://e-portal.eon-hungaria.com.
///
/// * `ZWB5_ONLINE_SRV` — the customer-account service. It authenticates an e-mail +
///   password pair and hands back a session GUID plus the business partners the account
///   may act for.
/// * `ZWB5_W1000` — the remote-reading ("távleolvasás") service. It lists the delivery
///   points (PODs), the available resolutions and measured variables, and returns the
///   interval readings themselves. Every call is authorised with the GUID sent as a
///   bearer token in *both* `Authorization` and `AuthorizationERP`.
actor PortalClient {
    struct Configuration: Sendable {
        var host = URL(string: "https://e-portal.eon-hungaria.com")!
        /// The account service insists on the two-letter language code…
        var accountLanguage = "HU"
        /// …while the metering service expects the one-letter SAP code.
        var meteringLanguage = "H"

        var accountService: URL { host.appending(path: "sap/opu/odata/sap/ZWB5_ONLINE_SRV") }
        var meteringService: URL { host.appending(path: "sap/opu/odata/sap/ZWB5_W1000") }
    }

    private let configuration: Configuration
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 120
        sessionConfiguration.httpCookieAcceptPolicy = .always
        sessionConfiguration.waitsForConnectivity = true
        self.session = URLSession(configuration: sessionConfiguration)
    }

    // MARK: - Account service

    /// Signs in and returns the session GUID together with the partners on the account.
    func logIn(email: String, password: String) async throws -> (guid: String, partners: [PartnerDTO]) {
        let body = LoginRequestBody(
            username: email.trimmingCharacters(in: .whitespacesAndNewlines),
            password: Data(password.utf8).base64EncodedString()
        )

        var request = URLRequest(url: accountURL(entity: "Login"))
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        applyCommonHeaders(to: &request)

        let payload: LoginPayload = try await send(request, unwrapping: LoginPayload.self)

        guard payload.ok, !payload.guid.isEmpty else {
            throw PortalError.invalidCredentials(
                payload.failureText ?? "The portal rejected that e-mail address and password."
            )
        }
        guard !payload.partners.results.isEmpty else {
            throw PortalError.notConfigured("This account has no business partner attached to it.")
        }
        return (payload.guid, payload.partners.results)
    }

    /// Tells the backend which partner subsequent metering calls belong to.
    @discardableResult
    func selectPartner(guid: String, partner: PartnerDTO) async throws -> SessionPayload {
        let body = SessionRequestBody(authid: partner.authid, guid: guid, partner: partner.partner)

        var request = URLRequest(url: accountURL(entity: "Session"))
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        applyCommonHeaders(to: &request)

        return try await send(request, unwrapping: SessionPayload.self)
    }

    // MARK: - Metering service

    /// The delivery points (PODs) the selected partner may read.
    func pods(guid: String, partner: String) async throws -> [PodDTO] {
        let request = meteringRequest(guid: guid, path: "Pod(Partner='\(escape(partner))')", expand: "Pods")
        let payload: PodsPayload = try await send(request, unwrapping: PodsPayload.self)
        return payload.pods.results.filter { !$0.pod.isEmpty }
    }

    /// The resolutions the service offers, already narrowed to one division (`sparte`).
    func intervals(guid: String, sparte: String) async throws -> [IntervalDTO] {
        let request = meteringRequest(guid: guid, path: "Intervals")
        let payload: SAPResults<IntervalDTO> = try await send(request, unwrapping: SAPResults<IntervalDTO>.self)
        return payload.results.filter { $0.sparte == sparte }
    }

    /// The measured variables (channels) available for a division.
    func variables(guid: String, sparte: String) async throws -> [VariableDTO] {
        let request = meteringRequest(guid: guid, path: "Variables")
        let payload: SAPResults<VariableDTO> = try await send(request, unwrapping: SAPResults<VariableDTO>.self)
        return payload.results.filter { $0.sparte == sparte }
    }

    /// Readings for one POD, one resolution and a list of variables, over an inclusive
    /// day range. The caller is responsible for staying inside the interval's horizon.
    func readings(
        guid: String,
        pod: String,
        variableIds: [String],
        intervalId: String,
        from: Date,
        to: Date
    ) async throws -> [MeasRowDTO] {
        guard !variableIds.isEmpty else { return [] }

        let key = [
            "Pod='\(escape(pod))'",
            "MeasVarList='\(escape(variableIds.joined(separator: ",")))'",
            "Interval='\(escape(intervalId))'",
            "StartDate=datetime'\(SAPDate.literal(from, endOfDay: false))'",
            "EndDate=datetime'\(SAPDate.literal(to, endOfDay: true))'",
        ].joined(separator: ",")

        let request = meteringRequest(guid: guid, path: "MeasData(\(key))", expand: "MeasDatas")
        let payload: MeasDataPayload = try await send(request, unwrapping: MeasDataPayload.self)
        return payload.measDatas.results
    }

    // MARK: - Request plumbing

    private func accountURL(entity: String) -> URL {
        var components = URLComponents(
            url: configuration.accountService.appending(path: entity),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "sap-language", value: configuration.accountLanguage)]
        return components.url!
    }

    private func meteringRequest(guid: String, path: String, expand: String? = nil) -> URLRequest {
        // The key predicates contain characters (`'`, `(`, `,`, `:`) that are legal in a
        // path but that URLComponents would re-encode, so the URL is assembled by hand.
        var url = configuration.meteringService.absoluteString + "/" + path + "?"
        if let expand { url += "$expand=\(expand)&" }
        url += "sap-language=\(configuration.meteringLanguage)"

        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "GET"
        applyCommonHeaders(to: &request)
        request.setValue("Bearer \(guid)", forHTTPHeaderField: "Authorization")
        request.setValue("Bearer \(guid)", forHTTPHeaderField: "AuthorizationERP")
        return request
    }

    private func applyCommonHeaders(to request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("X", forHTTPHeaderField: "X-Requested-With")
    }

    private func send<Payload: Decodable & Sendable>(
        _ request: URLRequest,
        unwrapping: Payload.Type
    ) async throws -> Payload {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            // A cancelled request means the caller moved on — the dashboard stepping to
            // the next month, say. That is not a portal that cannot be reached, and it
            // must not be reported as one.
            if error.code == .cancelled { throw CancellationError() }
            throw PortalError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PortalError.malformedResponse("No HTTP response.")
        }

        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw PortalError.sessionExpired
        default:
            throw PortalError.httpStatus(http.statusCode, Self.errorMessage(in: data))
        }

        do {
            return try decoder.decode(SAPEnvelope<Payload>.self, from: data).d
        } catch {
            if let message = Self.errorMessage(in: data) {
                throw PortalError.httpStatus(http.statusCode, message)
            }
            throw PortalError.malformedResponse(String(describing: error))
        }
    }

    /// SAP wraps failures as `{"error":{"code":…,"message":{"value":…}}}`.
    private static func errorMessage(in data: Data) -> String? {
        struct Failure: Decodable {
            struct Inner: Decodable {
                struct Message: Decodable { let value: String }
                let message: Message
            }
            let error: Inner
        }
        return try? JSONDecoder().decode(Failure.self, from: data).error.message.value
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

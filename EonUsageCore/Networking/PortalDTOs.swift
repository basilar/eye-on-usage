import Foundation

// MARK: - Envelopes

/// Every SAP Gateway JSON response nests its payload under `d`.
struct SAPEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    let d: Payload
}

struct SAPResults<Element: Decodable & Sendable>: Decodable, Sendable {
    let results: [Element]

    init(results: [Element] = []) { self.results = results }
}

struct SAPMessage: Decodable, Sendable {
    let retcode: String?
    let retcodeText: String?
    let severity: String?
    let id: String?

    enum CodingKeys: String, CodingKey {
        case retcode = "Retcode"
        case retcodeText = "RetcodeText"
        case severity = "Severity"
        case id = "Id"
    }

    var text: String? {
        retcodeText?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - ZWB5_ONLINE_SRV (account service)

struct LoginRequestBody: Encodable, Sendable {
    let username: String
    /// Base64 of the UTF-8 password — the portal's own web client encodes it this way.
    let password: String
    var guid = ""
    var channel = "WEB"
    var passwordInit = false
    var fbId = ""
    var selectedelmu = false
    var delegate = false
    var recaptcha = ""
    var fb = false
    var kauGuid = ""
    /// `L000` is the residential ("lakossági") login event the web portal sends.
    var serverEvent = "L000"
    var partners = EmptyList()
    var message = EmptyList()

    struct EmptyList: Encodable, Sendable {
        let results: [String] = []
    }

    enum CodingKeys: String, CodingKey {
        case username = "Username"
        case password = "Password"
        case guid = "Guid"
        case channel = "Channel"
        case passwordInit = "PasswordInit"
        case fbId = "FbId"
        case selectedelmu = "Selectedelmu"
        case delegate = "Delegate"
        case recaptcha = "Recaptcha"
        case fb = "Fb"
        case kauGuid = "KauGuid"
        case serverEvent = "ServerEvent"
        case partners = "Partners"
        case message = "Message"
    }
}

struct LoginPayload: Decodable, Sendable {
    let ok: Bool
    let guid: String
    let retcodeText: String?
    let partners: SAPResults<PartnerDTO>
    let message: SAPResults<SAPMessage>

    enum CodingKeys: String, CodingKey {
        case ok = "Ok"
        case guid = "Guid"
        case retcodeText = "RetcodeText"
        case partners = "Partners"
        case message = "Message"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? container.decode(SAPBool.self, forKey: .ok).value) ?? false
        guid = (try? container.decode(String.self, forKey: .guid)) ?? ""
        retcodeText = try container.decodeIfPresent(String.self, forKey: .retcodeText)
        partners = (try? container.decode(SAPResults<PartnerDTO>.self, forKey: .partners)) ?? SAPResults()
        message = (try? container.decode(SAPResults<SAPMessage>.self, forKey: .message)) ?? SAPResults()
    }

    var failureText: String? {
        if let first = message.results.compactMap(\.text).first(where: { !$0.isEmpty }) { return first }
        let trimmed = retcodeText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}

struct PartnerDTO: Decodable, Sendable {
    let partner: String
    let sparte: String
    let authid: String
    let name: String?

    enum CodingKeys: String, CodingKey {
        case partner = "Partner"
        case sparte = "Sparte"
        case authid = "Authid"
        case name = "Name"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        partner = (try? container.decode(String.self, forKey: .partner)) ?? ""
        sparte = (try? container.decode(String.self, forKey: .sparte)) ?? ""
        authid = (try? container.decode(String.self, forKey: .authid)) ?? ""
        name = try? container.decodeIfPresent(String.self, forKey: .name)
    }
}

struct SessionRequestBody: Encodable, Sendable {
    let authid: String
    let guid: String
    let partner: String
    var channel = "WEB"
    var serverEvent = "changePartner"
    var vkont = ""
    var vstelle = ""
    var message = LoginRequestBody.EmptyList()

    enum CodingKeys: String, CodingKey {
        case authid = "Authid"
        case guid = "Guid"
        case partner = "Partner"
        case channel = "Channel"
        case serverEvent = "ServerEvent"
        case vkont = "Vkont"
        case vstelle = "Vstelle"
        case message = "Message"
    }
}

struct SessionPayload: Decodable, Sendable {
    let partner: String?
    let authid: String?

    enum CodingKeys: String, CodingKey {
        case partner = "Partner"
        case authid = "Authid"
    }
}

// MARK: - ZWB5_W1000 (metering service)

struct PodsPayload: Decodable, Sendable {
    let pods: SAPResults<PodDTO>

    enum CodingKeys: String, CodingKey {
        case pods = "Pods"
    }
}

struct PodDTO: Decodable, Sendable {
    let pod: String
    let sparte: String
    /// The service has carried different descriptive keys over time; whichever is present wins.
    let description: String?

    enum CodingKeys: String, CodingKey {
        case pod = "Pod"
        case sparte = "Sparte"
        case description = "Description"
        case text = "Text"
        case address = "Address"
        case vstelle = "Vstelle"
        case name = "Name"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pod = (try? container.decode(String.self, forKey: .pod)) ?? ""
        sparte = (try? container.decode(String.self, forKey: .sparte)) ?? ""
        let candidates: [CodingKeys] = [.description, .text, .address, .name, .vstelle]
        description = candidates.lazy
            .compactMap { try? container.decodeIfPresent(String.self, forKey: $0) }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

struct IntervalDTO: Decodable, Sendable {
    let intervalId: String
    let description: String
    let sparte: String
    /// Maximum number of days the service will return in one request for this interval.
    let horizon: Int

    enum CodingKeys: String, CodingKey {
        case intervalId = "IntervalId"
        case description = "Description"
        case sparte = "Sparte"
        case horizon = "Horizon"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intervalId = (try? container.decode(SAPString.self, forKey: .intervalId).value) ?? ""
        description = (try? container.decode(String.self, forKey: .description)) ?? ""
        sparte = (try? container.decode(String.self, forKey: .sparte)) ?? ""
        horizon = (try? container.decode(SAPInt.self, forKey: .horizon).value) ?? 0
    }
}

struct VariableDTO: Decodable, Sendable {
    let measVarId: String
    let description: String
    let intervalId: String
    let sparte: String
    let aggregate: Bool

    enum CodingKeys: String, CodingKey {
        case measVarId = "MeasVarId"
        case description = "Description"
        case intervalId = "IntervalId"
        case sparte = "Sparte"
        case aggregate = "Aggregate"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        measVarId = (try? container.decode(SAPString.self, forKey: .measVarId).value) ?? ""
        description = (try? container.decode(String.self, forKey: .description)) ?? ""
        intervalId = (try? container.decode(SAPString.self, forKey: .intervalId).value) ?? ""
        sparte = (try? container.decode(String.self, forKey: .sparte)) ?? ""
        aggregate = (try? container.decode(SAPBool.self, forKey: .aggregate).value) ?? true
    }
}

struct MeasDataPayload: Decodable, Sendable {
    let measDatas: SAPResults<MeasRowDTO>

    enum CodingKeys: String, CodingKey {
        case measDatas = "MeasDatas"
    }
}

/// One timestamped row. `MeasVarList` repeats the requested variable ids in order, so
/// `Value1` belongs to the first id, `Value2` to the second, and so on.
struct MeasRowDTO: Decodable, Sendable {
    let timestamp: Date
    let variableIds: [String]
    let values: [Double?]

    /// Rebuilt from the readings cache, which stores the values without their envelope.
    init(timestamp: Date, variableIds: [String], values: [Double?]) {
        self.timestamp = timestamp
        self.variableIds = variableIds
        self.values = values
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        init(_ name: String) { self.stringValue = name }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)

        let rawTimestamp = (try? container.decode(String.self, forKey: DynamicKey("Timestamp"))) ?? ""
        guard let parsed = SAPDate.parse(rawTimestamp) else {
            throw PortalError.malformedResponse("Unreadable timestamp \"\(rawTimestamp)\"")
        }
        timestamp = parsed

        let rawList = (try? container.decode(String.self, forKey: DynamicKey("MeasVarList"))) ?? ""
        variableIds = rawList
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        values = (1...max(variableIds.count, 1)).map { index in
            guard let raw = try? container.decodeIfPresent(SAPString.self, forKey: DynamicKey("Value\(index)")) else {
                return nil
            }
            return SAPNumber.parse(raw.value)
        }
    }
}

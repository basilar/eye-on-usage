import Foundation

/// Owns the portal session and turns raw MeasData rows into `EnergySeries`.
///
/// The portal hands out a session GUID that it expires after a short idle window, so the
/// repository keeps the GUID only as a cache: any call that comes back as "expired"
/// re-authenticates once from the keychain and retries.
///
/// Readings for finished days are served from `ReadingsCache` and never refetched — see
/// there for what counts as finished.
actor UsageRepository {
    struct Account: Sendable {
        var partners: [PartnerDTO]
    }

    struct Catalogue: Sendable {
        var interval: IntervalDTO
        var channels: [MeasurementChannel]
    }

    private let client: PortalClient
    private let credentials: CredentialStore
    private let cache: ReadingsCache

    private var guid: String?
    private var partner: PartnerDTO?

    init(
        client: PortalClient = PortalClient(),
        credentials: CredentialStore = .shared,
        cache: ReadingsCache = .shared
    ) {
        self.client = client
        self.credentials = credentials
        self.cache = cache
    }

    // MARK: - Session

    /// Authenticates with fresh credentials and stores them on success.
    func signIn(email: String, password: String) async throws -> Account {
        let result = try await client.logIn(email: email, password: password)
        guid = result.guid
        try credentials.save(.init(email: email, password: password))
        return Account(partners: result.partners)
    }

    func selectPartner(_ partner: PartnerDTO) async throws {
        let guid = try await currentGUID()
        try await client.selectPartner(guid: guid, partner: partner)
        self.partner = partner
    }

    /// Restores the partner selection after a cold launch, using the saved credentials.
    @discardableResult
    func restoreSession(partnerID: String) async throws -> PartnerDTO {
        let account = try await signInWithStoredCredentials()
        guard let match = account.partners.first(where: { $0.partner == partnerID }) ?? account.partners.first else {
            throw PortalError.notConfigured("No business partner is available on this account.")
        }
        try await selectPartner(match)
        return match
    }

    func signOut() async {
        guid = nil
        partner = nil
        credentials.clear()
        await cache.clear()
    }

    var hasStoredCredentials: Bool { credentials.load() != nil }

    // MARK: - Catalogue

    func deliveryPoints() async throws -> [DeliveryPoint] {
        let partnerID = try requirePartner().partner
        let pods = try await withSession { guid in
            try await self.client.pods(guid: guid, partner: partnerID)
        }
        return pods.map { DeliveryPoint(id: $0.pod, sparte: $0.sparte, subtitle: $0.description) }
    }

    /// The 15-minute resolution and the channels available at it, with directions applied.
    func catalogue(sparte: String, overrides: [String: ChannelDirection]) async throws -> Catalogue {
        let intervals = try await withSession { guid in
            try await self.client.intervals(guid: guid, sparte: sparte)
        }
        guard let interval = ChannelClassifier.quarterHourInterval(from: intervals) else {
            throw PortalError.notConfigured("The portal offers no resolutions for this delivery point.")
        }

        let variables = try await withSession { guid in
            try await self.client.variables(guid: guid, sparte: sparte)
        }

        let channels = variables
            .filter { $0.intervalId == interval.intervalId }
            .map { variable in
                MeasurementChannel(
                    id: variable.measVarId,
                    name: variable.description,
                    intervalID: variable.intervalId,
                    sparte: variable.sparte,
                    isSummable: variable.aggregate,
                    direction: overrides[variable.measVarId]
                        ?? ChannelClassifier.direction(id: variable.measVarId, name: variable.description)
                )
            }

        return Catalogue(interval: interval, channels: channels)
    }

    // MARK: - Readings

    /// Assembles an inclusive day range, taking settled days from the cache and fetching
    /// only what is left in requests the interval's horizon allows.
    func readings(
        podID: String,
        channels: [MeasurementChannel],
        interval: IntervalDTO,
        from: Date,
        to: Date
    ) async throws -> EnergySeries {
        let wanted = channels.filter { $0.direction != .other && $0.isSummable }
        guard !wanted.isEmpty else {
            throw PortalError.notConfigured(
                "None of this delivery point's channels could be read as consumption or feed-in. Pick them by hand in Settings."
            )
        }

        let ids = wanted.map(\.id)
        var directions: [String: ChannelDirection] = [:]
        for channel in wanted { directions[channel.id] = channel.direction }

        // Settled days come off disk; only the days the cache has no final answer for
        // reach the network, and they are regrouped into requests the horizon allows.
        var rows: [MeasRowDTO] = []
        var missing: [Date] = []

        for day in Self.days(from: from, to: to) {
            if let cached = await cache.rows(
                pod: podID, interval: interval.intervalId, day: day, ids: ids
            ) {
                rows.append(contentsOf: cached)
            } else {
                missing.append(day)
            }
        }

        for chunk in Self.chunks(days: missing, perRequest: max(interval.horizon, 1)) {
            let batch = try await withSession { guid in
                try await self.client.readings(
                    guid: guid,
                    pod: podID,
                    variableIds: ids,
                    intervalId: interval.intervalId,
                    from: chunk.lowerBound,
                    to: chunk.upperBound
                )
            }
            rows.append(contentsOf: batch)
            await cache.store(pod: podID, interval: interval.intervalId, ids: ids, rows: batch)
        }

        guard !rows.isEmpty else { throw PortalError.noData }
        return Self.series(from: rows, directions: directions, requestedIDs: ids)
    }

    // MARK: - Mapping

    /// Folds the wide `Value1…ValueN` rows into signed samples.
    static func series(
        from rows: [MeasRowDTO],
        directions: [String: ChannelDirection],
        requestedIDs: [String]
    ) -> EnergySeries {
        var samples: [Date: EnergySample] = [:]

        for row in rows {
            // `MeasVarList` echoes the request, but fall back to the order we asked in.
            let ids = row.variableIds.isEmpty ? requestedIDs : row.variableIds
            var sample = samples[row.timestamp] ?? EnergySample(start: row.timestamp, consumption: nil, feedIn: nil)

            for (index, id) in ids.enumerated() {
                guard index < row.values.count, let value = row.values[index] else { continue }
                switch directions[id] {
                case .consumption:
                    sample.consumption = (sample.consumption ?? 0) + value
                case .feedIn:
                    sample.feedIn = (sample.feedIn ?? 0) + value
                case .other, nil:
                    continue
                }
            }

            samples[row.timestamp] = sample
        }

        let ordered = samples.values.sorted { $0.start < $1.start }
        return EnergySeries(resolution: Self.resolution(of: ordered), samples: ordered)
    }

    /// Infers the resolution from the gap between the first two readings.
    private static func resolution(of samples: [EnergySample]) -> SeriesResolution {
        guard samples.count > 1 else { return .quarterHour }
        let gap = Int(samples[1].start.timeIntervalSince(samples[0].start) / 60)
        switch gap {
        case ..<31: return .quarterHour
        case ..<361: return .hour
        default: return .day
        }
    }

    /// Every day start in an inclusive range.
    static func days(from: Date, to: Date) -> [Date] {
        let calendar = Calendar.sapWallClock
        var result: [Date] = []
        var cursor = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)

        while cursor <= end {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    /// Packs the days that still need fetching into as few requests as the interval's
    /// horizon allows. Runs of consecutive days are kept together; a gap starts a new
    /// request rather than re-downloading the cached day in the middle.
    static func chunks(days: [Date], perRequest: Int) -> [ClosedRange<Date>] {
        let calendar = Calendar.sapWallClock
        var result: [ClosedRange<Date>] = []
        var run: [Date] = []

        func flush() {
            for start in stride(from: 0, to: run.count, by: perRequest) {
                result.append(run[start]...run[min(start + perRequest, run.count) - 1])
            }
            run = []
        }

        for day in days.sorted() {
            let followsRun = run.last.map { calendar.date(byAdding: .day, value: 1, to: $0) == day } ?? true
            if !followsRun { flush() }
            run.append(day)
        }
        flush()
        return result
    }

    // MARK: - Session plumbing

    private func requirePartner() throws -> PartnerDTO {
        guard let partner else {
            throw PortalError.notConfigured("No business partner has been selected yet.")
        }
        return partner
    }

    private func currentGUID() async throws -> String {
        if let guid { return guid }
        _ = try await signInWithStoredCredentials()
        guard let guid else { throw PortalError.sessionExpired }
        return guid
    }

    @discardableResult
    private func signInWithStoredCredentials() async throws -> Account {
        guard let saved = credentials.load() else { throw PortalError.sessionExpired }
        let result = try await client.logIn(email: saved.email, password: saved.password)
        guid = result.guid
        return Account(partners: result.partners)
    }

    /// Runs a call with the current GUID, re-authenticating once if the portal says the
    /// session has gone.
    private func withSession<T: Sendable>(_ body: (String) async throws -> T) async throws -> T {
        do {
            return try await body(try currentGUID())
        } catch let error as PortalError where error.isAuthenticationFailure {
            guid = nil
            let refreshed = try await currentGUID()
            if let partner {
                // Re-select the partner on the new session; a failure here surfaces from
                // the retried call itself, with a better message.
                _ = try? await client.selectPartner(guid: refreshed, partner: partner)
            }
            return try await body(refreshed)
        }
    }
}

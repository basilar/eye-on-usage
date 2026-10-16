import Foundation

/// Hourly cloud cover from Open-Meteo, for laying the weather over the readings.
///
/// Chosen because it needs no API key — this app has nowhere safe to put one, having no
/// server — and because it serves *history*, which matters more here than forecast: the
/// charts are almost always looking at days that have already happened.
///
/// Two endpoints, because neither covers the whole range on its own:
///
/// * `api.open-meteo.com/v1/forecast` serves roughly the last 93 days and a fortnight
///   ahead, from the best available model.
/// * `archive-api.open-meteo.com/v1/archive` serves ERA5 reanalysis back to 1940, but
///   runs about five days behind.
///
/// `timezone=auto` is what makes this line up with the meter. Open-Meteo then returns
/// local wall-clock stamps with no offset (`2026-09-03T12:00`), which is the same
/// convention the W1000 service uses — read both on `Calendar.sapWallClock` and noon in
/// one is noon in the other.
actor WeatherClient {
    struct Configuration: Sendable {
        var forecast = URL(string: "https://api.open-meteo.com/v1/forecast")!
        var archive = URL(string: "https://archive-api.open-meteo.com/v1/archive")!
        var geocoding = URL(string: "https://geocoding-api.open-meteo.com/v1/search")!
        /// How far back the forecast endpoint stops being the right source. Comfortably
        /// inside its ~93 day window, and comfortably past the archive's ~5 day lag.
        var archiveAfterDays = 7
    }

    private let configuration: Configuration
    private let session: URLSession
    private let cache: WeatherCache

    /// Open-Meteo's stamps carry no zone, and are read as the meter's wall clock.
    private let stamps: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.sapWallClock.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter
    }()

    init(configuration: Configuration = Configuration(), cache: WeatherCache = .shared) {
        self.configuration = configuration
        self.cache = cache
        let session = URLSessionConfiguration.ephemeral
        session.timeoutIntervalForRequest = 20
        session.timeoutIntervalForResource = 40
        self.session = URLSession(configuration: session)
    }

    // MARK: - Cloud cover

    /// Cloud cover and daylight over an inclusive day range. Settled ranges come off disk.
    ///
    /// Both in one request: the service charges the same for the extra `daily` fields, and
    /// a second round trip for sunrise would be pure waste.
    func sky(at location: WeatherLocation, from: Date, to: Date) async throws -> Sky {
        let calendar = Calendar.sapWallClock
        let start = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)

        if let cached = await cache.sky(at: location, from: start, to: end) {
            return cached
        }

        let today = calendar.startOfDay(for: Date())
        let boundary = calendar.date(byAdding: .day, value: -configuration.archiveAfterDays, to: today) ?? today
        let base = end < boundary ? configuration.archive : configuration.forecast

        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            // Two decimals is about a kilometre, which is finer than the cloud model's own
            // grid and is all it can use. Sending more would leak precision for nothing —
            // and it keeps the request in step with the cache key, which rounds the same.
            .init(name: "latitude", value: String(format: "%.2f", location.latitude)),
            .init(name: "longitude", value: String(format: "%.2f", location.longitude)),
            .init(name: "hourly", value: "cloud_cover"),
            .init(name: "daily", value: "sunrise,sunset"),
            .init(name: "timezone", value: "auto"),
            .init(name: "start_date", value: day(start)),
            .init(name: "end_date", value: day(end)),
        ]

        let payload: SkyPayload = try await get(components.url!)
        guard let hourly = payload.hourly else {
            throw PortalError.malformedResponse(payload.reason ?? "The weather service returned no hourly data.")
        }

        let samples = zip(hourly.time, hourly.cloudCover).compactMap { stamp, percent -> CloudCover.Sample? in
            guard let percent, let date = stamps.date(from: stamp) else { return nil }
            return CloudCover.Sample(start: date, percent: percent)
        }

        let days = zip(payload.daily?.sunrise ?? [], payload.daily?.sunset ?? [])
            .compactMap { rise, set -> Daylight.Day? in
                guard let rise = rise, let set = set,
                      let sunrise = stamps.date(from: rise), let sunset = stamps.date(from: set),
                      sunset > sunrise
                else { return nil }
                return Daylight.Day(sunrise: sunrise, sunset: sunset)
            }

        let sky = Sky(cloud: CloudCover(samples: samples), daylight: Daylight(days: days))
        await cache.store(sky, at: location, from: start, to: end)
        return sky
    }

    // MARK: - Places

    /// Looks a place up by name, so nobody has to type coordinates.
    func places(matching name: String) async throws -> [WeatherLocation] {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }

        var components = URLComponents(url: configuration.geocoding, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "name", value: query),
            .init(name: "count", value: "8"),
            .init(name: "format", value: "json"),
        ]

        let payload: PlacePayload = try await get(components.url!)
        return (payload.results ?? []).map { place in
            WeatherLocation(
                latitude: place.latitude,
                longitude: place.longitude,
                name: [place.name, place.admin1, place.countryCode]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
            )
        }
    }

    // MARK: - Plumbing

    private func day(_ date: Date) -> String {
        let parts = Calendar.sapWallClock.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func get<T: Decodable & Sendable>(_ url: URL) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw PortalError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PortalError.malformedResponse("No HTTP response from the weather service.")
        }
        guard (200...299).contains(http.statusCode) else {
            let reason = (try? JSONDecoder().decode(SkyPayload.self, from: data))?.reason
            throw PortalError.httpStatus(http.statusCode, reason)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PortalError.malformedResponse(String(describing: error))
        }
    }
}

// MARK: - DTOs

private struct SkyPayload: Decodable, Sendable {
    struct Hourly: Decodable, Sendable {
        let time: [String]
        let cloudCover: [Double?]

        enum CodingKeys: String, CodingKey {
            case time
            case cloudCover = "cloud_cover"
        }
    }

    /// Sunrise and sunset arrive in the same offset-free local form as the hourly stamps.
    struct Daily: Decodable, Sendable {
        let sunrise: [String?]
        let sunset: [String?]
    }

    let hourly: Hourly?
    let daily: Daily?
    let reason: String?
}

private struct PlacePayload: Decodable, Sendable {
    struct Place: Decodable, Sendable {
        let name: String
        let latitude: Double
        let longitude: Double
        let admin1: String?
        let countryCode: String?

        enum CodingKeys: String, CodingKey {
            case name, latitude, longitude, admin1
            case countryCode = "country_code"
        }
    }

    let results: [Place]?
}

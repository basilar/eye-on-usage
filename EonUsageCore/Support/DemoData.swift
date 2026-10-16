import Foundation

/// A believable stand-in so the app, previews and widget galleries have something to draw
/// before anyone signs in. Deterministic — the same day always yields the same curve.
enum DemoData {
    static let podID = "HU000210F11S00000000000005406518"

    static let deliveryPoints: [DeliveryPoint] = [
        DeliveryPoint(id: podID, sparte: Sparte.electricity, subtitle: "Demo delivery point")
    ]

    static let channels: [MeasurementChannel] = [
        MeasurementChannel(
            id: "1", name: "+A Vételezett hatásos energia", intervalID: "1",
            sparte: Sparte.electricity, isSummable: true, direction: .consumption
        ),
        MeasurementChannel(
            id: "2", name: "-A Betáplált hatásos energia", intervalID: "1",
            sparte: Sparte.electricity, isSummable: true, direction: .feedIn
        ),
    ]

    /// 15-minute samples for an inclusive range of days.
    /// Sample cloud cover, so the overlay can be seen without an account. Deliberately
    /// anti-correlated with the sample generation: cloudy hours are the flat ones.
    static func sky(from: Date, to: Date) -> Sky {
        Sky(cloud: cloudCover(from: from, to: to), daylight: daylight(from: from, to: to))
    }

    /// Roughly Hungarian daylight, so the shading lands where it would in life.
    static func daylight(from: Date, to: Date) -> Daylight {
        let calendar = Calendar.sapWallClock
        var days: [Daylight.Day] = []
        var day = calendar.startOfDay(for: from)
        let last = calendar.startOfDay(for: to)

        while day <= last {
            let yearDay = Double(calendar.ordinality(of: .day, in: .year, for: day) ?? 180)
            let swing = sin((yearDay - 80) / 365 * 2 * .pi) * 2.6
            let rise = 6.9 - swing
            let set = 17.3 + swing
            if let sunrise = calendar.date(byAdding: .second, value: Int(rise * 3600), to: day),
               let sunset = calendar.date(byAdding: .second, value: Int(set * 3600), to: day) {
                days.append(Daylight.Day(sunrise: sunrise, sunset: sunset))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return Daylight(days: days)
    }

    static func cloudCover(from: Date, to: Date) -> CloudCover {
        let calendar = Calendar.sapWallClock
        var samples: [CloudCover.Sample] = []
        var day = calendar.startOfDay(for: from)
        let last = calendar.startOfDay(for: to)

        while day <= last {
            // A per-day character, so some days read as overcast and some as clear.
            let seed = Double(calendar.component(.day, from: day) % 7) / 7
            for hour in 0..<24 {
                guard let slot = calendar.date(byAdding: .hour, value: hour, to: day) else { continue }
                let wobble = sin(Double(hour) / 3.5 + seed * 6) * 22
                let percent = min(100, max(0, seed * 90 + wobble + 8))
                samples.append(CloudCover.Sample(start: slot, percent: percent))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return CloudCover(samples: samples)
    }

    static func series(from: Date, to: Date) -> EnergySeries {
        let calendar = Calendar.sapWallClock
        var samples: [EnergySample] = []
        var day = calendar.startOfDay(for: from)
        let last = calendar.startOfDay(for: to)

        while day <= last {
            let dayOfYear = calendar.ordinality(of: .day, in: .year, for: day) ?? 1
            // Seasonal irradiance: a broad peak around midsummer.
            let season = 0.55 + 0.45 * cos((Double(dayOfYear) - 172) / 365 * 2 * .pi)
            // A slow cloud cycle so consecutive days differ without being random.
            let cloud = 0.7 + 0.3 * sin(Double(dayOfYear) * 1.7)

            for slot in 0..<96 {
                guard let start = calendar.date(byAdding: .minute, value: slot * 15, to: day) else { continue }
                let hour = Double(slot) / 4

                let base = 0.055 + 0.02 * sin(hour / 24 * 2 * .pi)
                let morning = 0.10 * bell(hour, centre: 7, width: 1.4)
                let evening = 0.22 * bell(hour, centre: 19, width: 2.2)
                let load = max(0.02, base + morning + evening)

                let daylight = max(0, sin((hour - 6) / 12 * .pi))
                let generation = 1.45 * season * cloud * pow(daylight, 1.6)

                let netExport = max(0, generation - load)
                let netImport = max(0, load - generation)

                samples.append(
                    EnergySample(
                        start: start,
                        consumption: (netImport * 1000).rounded() / 1000,
                        feedIn: (netExport * 1000).rounded() / 1000
                    )
                )
            }

            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        return EnergySeries(resolution: .quarterHour, samples: samples)
    }

    static func snapshot(for day: Date = Date()) -> UsageSnapshot {
        let calendar = Calendar.sapWallClock
        let target = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: day))
            ?? calendar.startOfDay(for: day)
        let daily = series(from: target, to: target)
        let hourly = daily.aggregated(to: .hour)

        return UsageSnapshot(
            podID: podID,
            day: target,
            consumption: daily.totalConsumption,
            feedIn: daily.totalFeedIn,
            bars: hourly.samples.map {
                UsageSnapshot.Bar(start: $0.start, consumption: $0.consumption ?? 0, feedIn: $0.feedIn ?? 0)
            },
            capturedAt: day
        )
    }

    private static func bell(_ x: Double, centre: Double, width: Double) -> Double {
        exp(-pow(x - centre, 2) / (2 * width * width))
    }
}

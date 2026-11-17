import Foundation
import HealthKit

/// Reads HealthKit and pushes it to the Homesplash server in Health Auto Export's JSON (v2)
/// format, which the server's apple_health module already understands.
@MainActor
final class HealthSync: ObservableObject {
    static let shared = HealthSync()

    let store = HKHealthStore()
    @Published var syncing = false
    @Published var lastResult: String = UserDefaults.standard.string(forKey: "lastResult") ?? "Never synced"
    @Published var lastSync: Date? = UserDefaults.standard.object(forKey: "lastSync") as? Date
    @Published var lastCounts: [String: Int] = [:]

    private var observersStarted = false

    static let bpm = HKUnit.count().unitDivided(by: .minute())

    var readTypes: Set<HKObjectType> {
        [HKQuantityType(.stepCount), HKQuantityType(.activeEnergyBurned), HKQuantityType(.heartRate),
         HKQuantityType(.restingHeartRate), HKQuantityType(.heartRateVariabilitySDNN),
         HKQuantityType(.oxygenSaturation), HKCategoryType(.sleepAnalysis)]
    }

    // MARK: - Authorization & background delivery

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw SyncError.message("Health data isn't available on this device") }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// Wake the app when new steps / heart rate / sleep arrive (at most hourly, iOS decides).
    func startObservers() {
        guard HKHealthStore.isHealthDataAvailable(), !observersStarted else { return }
        observersStarted = true
        let types: [HKSampleType] = [HKQuantityType(.stepCount), HKQuantityType(.heartRate),
                                     HKCategoryType(.sleepAnalysis)]
        for type in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                guard error == nil else { completion(); return }
                Task { @MainActor in
                    await HealthSync.shared.syncIfDue(minInterval: 10 * 60)
                    completion()
                }
            }
            store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
    }

    // MARK: - Sync

    func syncIfDue(minInterval: TimeInterval) async {
        if let last = lastSync, Date().timeIntervalSince(last) < minInterval { return }
        guard Settings.isConfigured else { return }
        await sync()
    }

    func sync() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            guard let url = Settings.pushURL else { throw SyncError.message("Set the server address first") }
            guard let token = Settings.token, !token.isEmpty else { throw SyncError.message("Set the push token first") }
            let (payload, counts) = try await buildPayload()
            lastCounts = counts
            if counts.values.reduce(0, +) == 0 {
                // Phone locked (Health data encrypted) or no access — don't overwrite anything.
                throw SyncError.message("No Health data readable — unlock the phone or check Health access")
            }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let stored = json?["stored"] as? Int ?? 0
                record(success: true, "Sent \(stored) readings")
            case 401: throw SyncError.message("Server rejected the push token (401)")
            case 404: throw SyncError.message("Server has no apple_health module (404)")
            default: throw SyncError.message("Server error \(status)")
            }
        } catch is CancellationError {
            record(success: false, "Cancelled")
        } catch let SyncError.message(text) {
            record(success: false, text)
        } catch {
            record(success: false, error.localizedDescription)
        }
    }

    private func record(success: Bool, _ text: String) {
        let stamp = Date()
        lastResult = (success ? "✓ " : "✗ ") + text
        UserDefaults.standard.set(lastResult, forKey: "lastResult")
        if success {
            lastSync = stamp
            UserDefaults.standard.set(stamp, forKey: "lastSync")
        }
    }

    // MARK: - Payload

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    private func stamp(_ date: Date) -> String { Self.dateFormat.string(from: date) }

    func buildPayload() async throws -> ([String: Any], [String: Int]) {
        var metrics: [[String: Any]] = []
        var counts: [String: Int] = [:]

        func add(_ name: String, _ units: String, _ points: [[String: Any]]) {
            counts[name] = points.count
            if !points.isEmpty { metrics.append(["name": name, "units": units, "data": points]) }
        }

        // Hourly totals for the last 7 days — HealthKit statistics de-duplicate iPhone + Watch.
        let steps = (try? await hourlyStatistics(.stepCount, options: .cumulativeSum, days: 7)) ?? []
        add("step_count", "count", steps.compactMap { s in
            s.sumQuantity().map { ["date": stamp(s.startDate), "qty": $0.doubleValue(for: .count())] }
        })

        let energy = (try? await hourlyStatistics(.activeEnergyBurned, options: .cumulativeSum, days: 7)) ?? []
        add("active_energy", "kcal", energy.compactMap { s in
            s.sumQuantity().map { ["date": stamp(s.startDate), "qty": $0.doubleValue(for: .kilocalorie())] }
        })

        // Heart rate: hourly min/avg/max for today and yesterday.
        let heart = (try? await hourlyStatistics(.heartRate, options: [.discreteMin, .discreteAverage, .discreteMax], days: 2)) ?? []
        add("heart_rate", "count/min", heart.compactMap { s in
            guard let avg = s.averageQuantity() else { return nil }
            return ["date": stamp(s.startDate),
                    "Min": s.minimumQuantity()?.doubleValue(for: Self.bpm) ?? avg.doubleValue(for: Self.bpm),
                    "Avg": avg.doubleValue(for: Self.bpm),
                    "Max": s.maximumQuantity()?.doubleValue(for: Self.bpm) ?? avg.doubleValue(for: Self.bpm)]
        })

        let resting = (try? await samples(.restingHeartRate, days: 7, limit: 14)) ?? []
        add("resting_heart_rate", "count/min", resting.map {
            ["date": stamp($0.startDate), "qty": $0.quantity.doubleValue(for: Self.bpm)]
        })

        let hrv = (try? await samples(.heartRateVariabilitySDNN, days: 7, limit: 30)) ?? []
        add("heart_rate_variability", "ms", hrv.map {
            ["date": stamp($0.startDate), "qty": $0.quantity.doubleValue(for: .secondUnit(with: .milli))]
        })

        let spo2 = (try? await samples(.oxygenSaturation, days: 3, limit: 30)) ?? []
        add("blood_oxygen_saturation", "%", spo2.map {
            ["date": stamp($0.startDate), "qty": $0.quantity.doubleValue(for: .percent()) * 100]
        })

        let sleep = (try? await sleepSegments(hours: 36)) ?? []
        add("sleep_analysis", "hr", sleep)

        return (["data": ["metrics": metrics]], counts)
    }

    private func hourlyStatistics(_ id: HKQuantityTypeIdentifier, options: HKStatisticsOptions,
                                  days: Int) async throws -> [HKStatistics] {
        let cal = Calendar.current
        let now = Date()
        let start = cal.startOfDay(for: cal.date(byAdding: .day, value: -(days - 1), to: now) ?? now)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(id), predicate: predicate),
            options: options,
            anchorDate: start,
            intervalComponents: DateComponents(hour: 1))
        return try await descriptor.result(for: store).statistics()
    }

    private func samples(_ id: HKQuantityTypeIdentifier, days: Int, limit: Int) async throws -> [HKQuantitySample] {
        let predicate = HKQuery.predicateForSamples(withStart: Date(timeIntervalSinceNow: -Double(days) * 86_400), end: Date())
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(id), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: limit)
        return try await descriptor.result(for: store)
    }

    /// Sleep stage segments from ONE source (watch, ring, Zepp...) so overlapping sources
    /// don't double-count. Prefers the source with the most staged (core/deep/REM) sleep.
    private func sleepSegments(hours: Double) async throws -> [[String: Any]] {
        let predicate = HKQuery.predicateForSamples(withStart: Date(timeIntervalSinceNow: -hours * 3600), end: Date())
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)])
        let all = try await descriptor.result(for: store)

        let staged: Set<Int> = [HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                                HKCategoryValueSleepAnalysis.asleepREM.rawValue]
        let bySource = Dictionary(grouping: all) { $0.sourceRevision.source.bundleIdentifier }
        func score(_ items: [HKCategorySample]) -> (Double, Double) {
            let stagedMins = items.filter { staged.contains($0.value) }.reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
            let asleep = items.filter { $0.value != HKCategoryValueSleepAnalysis.inBed.rawValue
                && $0.value != HKCategoryValueSleepAnalysis.awake.rawValue }
                .reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
            return (stagedMins, asleep)
        }
        guard let best = bySource.values.max(by: { score($0) < score($1) }) else { return [] }

        return best.map { s in
            let label: String
            switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
            case .inBed: label = "In Bed"
            case .awake: label = "Awake"
            case .asleepCore: label = "Core"
            case .asleepDeep: label = "Deep"
            case .asleepREM: label = "REM"
            default: label = "Asleep"
            }
            return ["date": stamp(s.startDate), "start": stamp(s.startDate), "end": stamp(s.endDate),
                    "qty": s.endDate.timeIntervalSince(s.startDate) / 3600, "value": label,
                    "source": s.sourceRevision.source.name]
        }
    }
}

enum SyncError: Error {
    case message(String)
}

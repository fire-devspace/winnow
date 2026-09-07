import Foundation
import TestSupport
import XCTest

/// Per-scenario wall-clock timing for the e2e suite. Each test records named
/// step durations (e.g. onboarding: wallet-create; funding:
/// mined→detected-by-filters); every record rewrites
/// docs/screenshots/timings.json (next to the PNGs) so a failing run still
/// leaves the timings of the scenarios that completed.
///
/// Schema: {run: ISO date, device: simulator name,
///          scenarios: [{name, steps: [{step, seconds}]}],
///          totals: {<scenario>: seconds, "all": seconds}}
enum Timings {
    struct Step: Codable, Equatable {
        var step: String
        var seconds: Double
    }

    struct Scenario: Codable, Equatable {
        var name: String
        var steps: [Step]
    }

    struct Report: Codable {
        var run: String
        var device: String
        var scenarios: [Scenario]
        var totals: [String: Double]
    }

    private static let lock = NSLock()
    /// Guarded by `lock` (same pattern as the suite's `funding` static).
    nonisolated(unsafe) private static var stepsByScenario: [String: [Step]] = [:]
    /// One stamp per test-runner process = one report per suite run.
    private static let runStamp = ISO8601DateFormatter().string(from: Date())

    /// Canonical scenario order in the report (suite order), then alphabetical.
    private static let scenarioOrder = ["onboarding", "receive", "funding", "send",
                                        "vault", "settings", "import"]

    /// Records a named step duration (seconds since `start`) for a scenario.
    static func record(_ scenario: String, step: String, from start: Date) {
        record(scenario, step: step, seconds: Date().timeIntervalSince(start))
    }

    /// Records a named step duration (seconds, rounded to centiseconds).
    static func record(_ scenario: String, step: String, seconds: TimeInterval) {
        lock.lock()
        stepsByScenario[scenario, default: []].append(
            Step(step: step, seconds: (seconds * 100).rounded() / 100))
        lock.unlock()
        save()
    }

    /// The report destination: alongside the screenshots.
    static var reportURL: URL {
        Screenshots.directory.appending(path: "timings.json")
    }

    /// The simulator's device name (e.g. "iPhone 17"), resolved host-side via
    /// simctl against the runner's SIMULATOR_UDID.
    static var deviceName: String {
        let environment = ProcessInfo.processInfo.environment
        if let udid = environment["SIMULATOR_UDID"],
           let listed = try? HostProcess.run("/usr/bin/xcrun",
                                             ["simctl", "list", "devices", "booted", "-j"]),
           listed.status == 0,
           let data = listed.stdout.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let runtimes = parsed["devices"] as? [String: [[String: Any]]] {
            for devices in runtimes.values {
                for device in devices where device["udid"] as? String == udid {
                    if let name = device["name"] as? String { return name }
                }
            }
        }
        return environment["SIMULATOR_DEVICE_NAME"] ?? "iOS Simulator"
    }

    /// Rewrites timings.json: this run's scenarios overlaid on the existing
    /// file (partial runs keep the previous run's other scenarios), totals
    /// recomputed.
    private static func save() {
        lock.lock()
        let fresh = stepsByScenario
        lock.unlock()

        var byName: [String: Scenario] = [:]
        if let data = try? Data(contentsOf: reportURL),
           let existing = try? JSONDecoder().decode(Report.self, from: data) {
            for scenario in existing.scenarios { byName[scenario.name] = scenario }
        }
        for (name, steps) in fresh { byName[name] = Scenario(name: name, steps: steps) }

        let scenarios = byName.values.sorted {
            let order = scenarioOrder
            switch (order.firstIndex(of: $0.name), order.firstIndex(of: $1.name)) {
            case let (a?, b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return $0.name < $1.name
            }
        }
        var totals: [String: Double] = [:]
        for scenario in scenarios {
            totals[scenario.name] = scenario.steps.reduce(0) { $0 + $1.seconds }
        }
        totals["all"] = totals.values.reduce(0, +)
        totals = totals.mapValues { ($0 * 100).rounded() / 100 }

        let report = Report(run: runStamp, device: deviceName, scenarios: scenarios, totals: totals)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report) else { return }
        do {
            try FileManager.default.createDirectory(at: Screenshots.directory, withIntermediateDirectories: true)
            try data.write(to: reportURL, options: .atomic)
        } catch {
            // Same host-fallback as Screenshots: direct writes can be refused
            // from the sim container.
            do {
                let staging = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "timings.json")
                try data.write(to: staging)
                _ = try HostProcess.run("/bin/mkdir", ["-p", Screenshots.directory.path])
                let copy = try HostProcess.run("/bin/cp", [staging.path, reportURL.path])
                if copy.status != 0 {
                    print("Timings: could not save report: \(copy.stderr)")
                }
            } catch {
                print("Timings: could not save report: \(error.localizedDescription)")
            }
        }
    }
}

import Foundation
import Testing
import WinnowFuzzCore

/// One replayed fuzz input, `Cases/<target>/<name>.bin`.
struct RegressionCase: Sendable, CustomTestStringConvertible {
    let directory: String
    let name: String
    let url: URL

    var testDescription: String { "\(directory)/\(name)" }

    /// Every case shipped in the bundle, in a stable order. A directory that
    /// names no target is kept, so its cases fail instead of being skipped.
    static let all: [RegressionCase] = {
        guard let root = Bundle.module.url(forResource: "Cases", withExtension: nil),
              let paths = try? FileManager.default.subpathsOfDirectory(atPath: root.path) else { return [] }
        return paths.sorted().compactMap { path in
            let parts = path.split(separator: "/")
            guard parts.count == 2, parts[1].hasSuffix(".bin") else { return nil }
            return RegressionCase(directory: String(parts[0]), name: String(parts[1]),
                                  url: root.appendingPathComponent(path))
        }
    }()
}

/// Inputs the fuzzer once broke a parser with, replayed on every `swift test`
/// under the harness's own invariant for their target, so a fix stays fixed
/// without waiting for the weekly lane to wander back to it. A reproducer that
/// `WinnowFuzz --artifact-dir` saved joins the corpus by being copied under
/// `Cases/<target>/`; nothing else changes.
@Suite("Fuzz regressions")
struct FuzzRegressionTests {
    @Test("every case in the crash corpus replays without an invariant failure",
          arguments: RegressionCase.all)
    func replay(_ regression: RegressionCase) throws {
        let target = try #require(FuzzTarget(rawValue: regression.directory),
                                  "Cases/\(regression.directory) names no fuzz target")
        // The generator only varies how the framing target chunks its input.
        var rng = SplitMix64(state: 0x5749_4E4E_4F57_4655)
        try exercise(target, data: Data(contentsOf: regression.url), rng: &rng)
    }

    @Test("the corpus is found in the bundle")
    func corpusIsPresent() {
        #expect(!RegressionCase.all.isEmpty)
    }
}

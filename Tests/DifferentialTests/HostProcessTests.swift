import Foundation
import Testing

@Suite("Shared host process runner")
struct HostProcessTests {
    @Test func drainsBothLargeStreams() throws {
        let result = try HostProcess.run("/bin/sh", ["-c",
            "head -c 131072 /dev/zero >&2; head -c 131072 /dev/zero"])
        #expect(result.status == 0)
        #expect(result.stdout.utf8.count == 131072)
        #expect(result.stderr.utf8.count == 131072)
    }

    @Test func roundTripsLargeInput() throws {
        let data = Data(repeating: 65, count: 262144)
        let result = try HostProcess.run("/bin/cat", input: data)
        #expect(result.status == 0)
        #expect(Data(result.stdout.utf8) == data)
    }

    @Test func preservesFailureStatus() throws {
        let result = try HostProcess.run("/bin/sh", ["-c", "printf failed >&2; exit 7"])
        #expect(result.status == 7)
        #expect(result.stderr == "failed")
    }
}

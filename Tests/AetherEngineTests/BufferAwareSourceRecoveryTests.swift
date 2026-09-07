import Foundation
import Testing
@testable import AetherEngine

struct BufferAwareSourceRecoveryTests {
    @Test func playbackIntentGuards() {
        #expect(SourceReadRecoveryPolicy.permitsRecovery(
            playing: true, rendered: true, seeking: false, live: false, sequential: false))
        for values in [(false, true, false, false, false), (true, false, false, false, false),
                       (true, true, true, false, false), (true, true, false, true, false),
                       (true, true, false, false, true)] {
            #expect(!SourceReadRecoveryPolicy.permitsRecovery(
                playing: values.0, rendered: values.1, seeking: values.2,
                live: values.3, sequential: values.4))
        }
    }

    @Test func healthyBuffersAndServerRefusalsArePreserved() {
        func decision(buffer: Double = 2, gap: Double = 6, active: Bool = true,
                      status: Int = 206, recoveries: Int = 0, allowed: Bool = true) -> Bool {
            SourceReadRecoveryPolicy.shouldEndRequest(
                allowed: allowed, bufferedSeconds: buffer, gapSeconds: gap,
                requestActive: active, status: status, recentRecoveries: recoveries)
        }
        #expect(decision())
        #expect(!decision(buffer: 8))
        #expect(!decision(buffer: .nan))
        #expect(!decision(buffer: -1))
        #expect(!decision(gap: 4.99))
        #expect(!decision(active: false))
        #expect(!decision(allowed: false))
        #expect(!decision(recoveries: 2))
        for status in [0, 401, 403, 429, 500, 503, 509] {
            #expect(!decision(status: status))
        }
    }

    @Test("silent request is cancelled and reading continues from the delivered frontier",
          .timeLimit(.minutes(1)))
    func silentRequestRecovery() async throws {
        let firstRange: Int64 = 2 * 1024 * 1024
        let silentBytes: Int64 = 64 * 1024
        let origin = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, offset, _ in
                offset == firstRange ? .serveThenGoSilent(afterBytes: silentBytes) : .serve206
            })
        let server = try #require(origin)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                boundedInitialFetch: firstRange, connStallTimeout: 20)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        try await waitUntil { !reader.hasLiveConnectionForTesting }
        #expect(read(reader, count: 512 * 1024) == 512 * 1024)
        try await waitUntil { reader.windowDiagnostics.aheadBytes >= Int(firstRange + silentBytes) - 512 * 1024
            && server.requestedRanges.contains { $0.start == firstRange } }

        let afterSilence = DispatchTime.now() + 6
        #expect(!reader.sourceReadHealth(bufferedAhead: 20, allowRecovery: true,
                                        now: afterSilence).didRecover)
        #expect(!reader.sourceReadHealth(bufferedAhead: 2, allowRecovery: false,
                                        now: afterSilence).didRecover)
        let health = reader.sourceReadHealth(bufferedAhead: 2, allowRecovery: true, now: afterSilence)
        #expect(health.didRecover)
        #expect(health.recoveryCount == 1)
        #expect(!reader.hasLiveConnectionForTesting)
        #expect(!reader.sourceReadHealth(bufferedAhead: 2, allowRecovery: true,
                                        now: afterSilence).didRecover)
        #expect(read(reader, count: 4 * 1024 * 1024) == 4 * 1024 * 1024)
        #expect(server.requestedRanges.contains { $0.start == firstRange + silentBytes })
        reader.markClosed()
        #expect(!reader.sourceReadHealth(bufferedAhead: 0, allowRecovery: true,
                                        now: afterSilence + 30).didRecover)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try #require(predicate())
    }

    private func read(_ reader: AVIOReader, count: Int) -> Int {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { buffer.deallocate() }
        return Int(reader.read(into: buffer, size: Int32(count)))
    }
}

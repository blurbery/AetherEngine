import Foundation
import Testing
@testable import AetherEngine

@MainActor
struct ExternalSubtitleFillPriorityTests {
    @Test func selectedTrackBypassesBackgroundQueueWithoutDroppingOtherTracks() throws {
        let stores = (0..<3).map { _ in NativeSubtitleCueStore() }
        let jobs = stores.enumerated().map { index, store in
            AetherEngine.ExternalSubtitleFillJob(
                url: URL(string: "https://example.invalid/\(index).srt")!, headers: [:],
                targets: [.init(streamIndex: nil, store: store)])
        }
        let priority = Set([ObjectIdentifier(stores[2])])
        #expect(AetherEngine.nextExternalSubtitleFillJob(
            jobs: jobs, priorityStores: priority, canPrefetch: false) == 2)
        let remaining = Array(jobs.prefix(2))
        #expect(AetherEngine.nextExternalSubtitleFillJob(
            jobs: remaining, priorityStores: priority, canPrefetch: false) == nil)
        #expect(AetherEngine.nextExternalSubtitleFillJob(
            jobs: remaining, priorityStores: priority, canPrefetch: true) == 0)
        #expect(AetherEngine.nextExternalSubtitleFillJob(
            jobs: remaining, priorityStores: [ObjectIdentifier(stores[1])], canPrefetch: false) == 1)
        #expect(jobs.count == 3)
    }

    @Test func sharedContainerIsPrioritisedAsOneJob() {
        let a = NativeSubtitleCueStore(), b = NativeSubtitleCueStore()
        let job = AetherEngine.ExternalSubtitleFillJob(
            url: URL(string: "https://example.invalid/subtitles.mkv")!, headers: ["Accept": "*/*"],
            targets: [.init(streamIndex: 1, store: a), .init(streamIndex: 2, store: b)])
        #expect(AetherEngine.nextExternalSubtitleFillJob(
            jobs: [job], priorityStores: [ObjectIdentifier(b)], canPrefetch: false) == 0)
        #expect(job.targets.count == 2)
    }

    @Test func schedulingRejectsAReplacedSession() throws {
        let engine = try AetherEngine()
        engine.prioritizeSelectedExternalSubtitles = true
        let oldSession = HLSVideoEngine(url: URL(string: "https://example.invalid/old.mkv")!)
        let newSession = HLSVideoEngine(url: URL(string: "https://example.invalid/new.mkv")!)
        let generation = engine.loadGeneration
        engine.nativeVideoSession = newSession
        defer { engine.stop() }
        #expect(!engine.externalSubtitleFillDecision(
            jobs: [], session: oldSession, generation: generation).current)
        #expect(!engine.externalSubtitleFillDecision(
            jobs: [], session: newSession, generation: generation + 1).current)
        #expect(engine.externalSubtitleFillDecision(
            jobs: [], session: newSession, generation: generation).current)
    }
}

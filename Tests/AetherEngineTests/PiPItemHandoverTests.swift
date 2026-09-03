import Testing
import AVFoundation
import Combine
import os
@testable import AetherEngine

/// AE#158: a native player can lose its visible presentation when its source layer's player drops
/// its item, so PiP and explicit foreground replacements keep the running item attached until the
/// new master swaps in place. See AetherEngine.shouldHandOverItemInPlace.
@Suite("Native in-place item handover policy")
struct PiPItemHandoverTests {
    @Test("handover retires replayed EOF while retaining the actual player item and layer")
    @MainActor
    func handoverRetiresSessionBeforeResubscription() throws {
        let engine = try AetherEngine()
        let host = NativeAVPlayerHost()
        engine.nativeHost = host
        let item = AVPlayerItem(asset: AVMutableComposition())
        host.avPlayer.replaceCurrentItem(with: item)
        host.markEndOfMediaReached()
        #expect(host.didReachEnd)
        let layer = host.playerLayer
        let itemChanges = OSAllocatedUnfairLock(initialState: 0)
        let observation = host.avPlayer.observe(\.currentItem, options: [.new]) { _, _ in
            itemChanges.withLock { $0 += 1 }
        }

        engine.stopInternal(resetDisplayCriteria: false, keepNativeHost: true, keepCurrentItem: true)

        var replayedEnd: Bool?
        let subscription = host.$didReachEnd.sink { replayedEnd = $0 }
        #expect(replayedEnd == false)
        #expect(!host.isReady && !host.isVideoReadyForDisplay)
        #expect(host.failure == nil)
        #expect(host.currentTime == 0 && host.renderedTime == 0 && host.duration == 0)
        #expect(engine.nativeHost === host)
        #expect(host.avPlayer.currentItem === item)
        #expect(host.playerLayer === layer && layer.player === host.avPlayer)
        #expect(itemChanges.withLock { $0 } == 0)
        subscription.cancel()
        observation.invalidate()
        engine.stop()
        #expect(host.avPlayer.currentItem == nil)
    }

    @Test("queued outgoing end notification cannot end a prepared successor")
    @MainActor
    func queuedEndCannotEscapeHandover() async throws {
        let engine = try AetherEngine()
        let host = NativeAVPlayerHost()
        engine.nativeHost = host
        defer { engine.stop() }
        host.load(url: URL(string: "http://127.0.0.1:9/retired.m3u8")!, startPosition: 0)
        let item = try #require(host.avPlayer.currentItem)
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: item)
        // The notification queues its MainActor work. Retire it before yielding.
        engine.stopInternal(resetDisplayCriteria: false, keepNativeHost: true, keepCurrentItem: true)
        for _ in 0..<5 { await Task.yield() }
        #expect(!host.didReachEnd)
        #expect(host.failure == nil)
        #expect(host.avPlayer.currentItem === item)
    }

    @Test("hands over for PiP or an explicit host request only from a native session")
    func handsOverForNativePiPOrHostRequest() {
        #expect(AetherEngine.shouldHandOverItemInPlace(
            pipActive: true, hostRequested: false, priorBackendWasNative: true
        ))
        #expect(AetherEngine.shouldHandOverItemInPlace(
            pipActive: false, hostRequested: true, priorBackendWasNative: true
        ))
        #expect(AetherEngine.shouldHandOverItemInPlace(
            pipActive: true, hostRequested: true, priorBackendWasNative: true
        ))
        #expect(!AetherEngine.shouldHandOverItemInPlace(
            pipActive: false, hostRequested: false, priorBackendWasNative: true
        ))
        #expect(!AetherEngine.shouldHandOverItemInPlace(
            pipActive: true, hostRequested: true, priorBackendWasNative: false
        ))
    }

    @Test("a foreground request is consumed exactly once")
    @MainActor
    func foregroundRequestIsOneShot() throws {
        let engine = try AetherEngine()

        engine.prepareForItemReplacement()

        #expect(engine.consumeInPlaceItemHandoverRequest(priorBackendWasNative: true))
        #expect(!engine.consumeInPlaceItemHandoverRequest(priorBackendWasNative: true))
        engine.stop()
    }

    @Test("a non-native load consumes rather than leaks the foreground request")
    @MainActor
    func nonNativeLoadConsumesRequest() throws {
        let engine = try AetherEngine()

        engine.prepareForItemReplacement()

        #expect(!engine.consumeInPlaceItemHandoverRequest(priorBackendWasNative: false))
        #expect(!engine.consumeInPlaceItemHandoverRequest(priorBackendWasNative: true))
        engine.stop()
    }

    @Test("a final stop cancels a pending foreground request")
    @MainActor
    func stopCancelsPendingRequest() throws {
        let engine = try AetherEngine()

        engine.prepareForItemReplacement()
        engine.stop()

        #expect(!engine.consumeInPlaceItemHandoverRequest(priorBackendWasNative: true))
    }

    @Test("PiP remains mandatory without a foreground request")
    @MainActor
    func pipHandoverRemainsIndependent() throws {
        let engine = try AetherEngine()
        engine.pictureInPictureActive = true

        #expect(engine.consumeInPlaceItemHandoverRequest(priorBackendWasNative: true))
        #expect(engine.consumeInPlaceItemHandoverRequest(priorBackendWasNative: true))
        engine.stop()
    }
}

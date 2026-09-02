import Testing
@testable import AetherEngine

/// AE#158: a native player can lose its visible presentation when its source layer's player drops
/// its item, so PiP and explicit foreground replacements keep the running item attached until the
/// new master swaps in place. See AetherEngine.shouldHandOverItemInPlace.
@Suite("Native in-place item handover policy")
struct PiPItemHandoverTests {
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

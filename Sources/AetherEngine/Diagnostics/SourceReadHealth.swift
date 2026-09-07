import Foundation

public struct SourceReadHealth: Equatable, Sendable {
    public let generation: Int
    public let offset: Int64
    public let readerAheadBytes: Int
    public let bufferedAheadSeconds: Double
    public let noDataSeconds: Double
    public let hasActiveRequest: Bool
    public let recoveryCount: Int
    public let didRecover: Bool
}

struct SourceReadRecoveryPolicy {
    static func permitsRecovery(playing: Bool, rendered: Bool, seeking: Bool,
                                live: Bool, sequential: Bool) -> Bool {
        playing && rendered && !seeking && !live && !sequential
    }

    static func shouldEndRequest(allowed: Bool, bufferedSeconds: Double,
                                 gapSeconds: Double, requestActive: Bool,
                                 status: Int, recentRecoveries: Int) -> Bool {
        allowed && bufferedSeconds.isFinite && bufferedSeconds >= 0 && bufferedSeconds < 8
            && gapSeconds.isFinite && gapSeconds >= 5 && requestActive
            && (status == 200 || status == 206) && recentRecoveries < 2
    }
}

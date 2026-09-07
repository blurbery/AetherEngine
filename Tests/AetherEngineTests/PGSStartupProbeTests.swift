import Foundation
import Testing
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

@Suite("PGS startup canvas")
struct PGSStartupProbeTests {
    @Test("sparse PGS does not extend the video probe and remains selectable")
    func sparsePGS() throws {
        let data = fixture()
        let baseline = try open(data, seed: false)
        let improved = try open(data, seed: true)
        #expect(improved.bytes < baseline.bytes)
        #expect(improved.videoWidth == baseline.videoWidth)
        #expect(improved.videoWidth == 16)
        #expect(improved.subtitleCodec == AV_CODEC_ID_HDMV_PGS_SUBTITLE)
        #expect(improved.subtitleWidth == 16)
        print("PGS probe bytes: baseline=\(baseline.bytes) changed=\(improved.bytes)")
    }

    @Test("known subtitle dimensions and other codecs are preserved")
    func preserveKnown() throws {
        try withContext { ctx, video, subtitle in
            video.pointee.width = 3840; video.pointee.height = 2160
            subtitle.pointee.width = 1920; subtitle.pointee.height = 1080
            Demuxer.seedMissingPGSCanvas(ctx)
            #expect(subtitle.pointee.width == 1920)
            #expect(subtitle.pointee.height == 1080)
            subtitle.pointee.width = 0; subtitle.pointee.height = 0
            subtitle.pointee.codec_id = AV_CODEC_ID_DVD_SUBTITLE
            Demuxer.seedMissingPGSCanvas(ctx)
            #expect(subtitle.pointee.width == 0)
        }
    }

    @Test("missing video dimensions and other containers retain normal probing")
    func fallback() throws {
        try withContext { ctx, video, subtitle in
            Demuxer.seedMissingPGSCanvas(ctx)
            #expect(subtitle.pointee.width == 0)
            video.pointee.width = 1920; video.pointee.height = 1080
            ctx.pointee.iformat = av_find_input_format("mpegts")
            Demuxer.seedMissingPGSCanvas(ctx)
            #expect(subtitle.pointee.width == 0)
        }
    }

    @Test("the real PGS presentation replaces the fallback canvas")
    func actualCanvasWins() throws {
        let codec = try #require(avcodec_find_decoder(AV_CODEC_ID_HDMV_PGS_SUBTITLE))
        var ctx = try #require(avcodec_alloc_context3(codec)) as UnsafeMutablePointer<AVCodecContext>?
        defer { avcodec_free_context(&ctx) }
        let c = try #require(ctx)
        c.pointee.width = 3840; c.pointee.height = 2160
        #expect(avcodec_open2(c, codec, nil) == 0)
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let p = try #require(packet)
        let pcs: [UInt8] = [0x16,0,11, 0x07,0x80,0x04,0x38, 0x10,0,1,0x80,0,0,0, 0x80,0,0]
        #expect(av_new_packet(p, Int32(pcs.count)) == 0)
        pcs.withUnsafeBytes { src in p.pointee.data!.update(from: src.baseAddress!.assumingMemoryBound(to: UInt8.self), count: pcs.count) }
        var sub = AVSubtitle(); var got: Int32 = 0
        _ = avcodec_decode_subtitle2(c, &sub, &got, p)
        defer { avsubtitle_free(&sub) }
        #expect(c.pointee.width == 1920)
        #expect(c.pointee.height == 1080)
    }

    private func withContext(_ body: (UnsafeMutablePointer<AVFormatContext>, UnsafeMutablePointer<AVCodecParameters>, UnsafeMutablePointer<AVCodecParameters>) throws -> Void) throws {
        let ctx = avformat_alloc_context()
        defer { avformat_free_context(ctx) }
        let c = try #require(ctx)
        c.pointee.iformat = av_find_input_format("matroska")
        let video = try #require(avformat_new_stream(c, nil)?.pointee.codecpar)
        let subtitle = try #require(avformat_new_stream(c, nil)?.pointee.codecpar)
        video.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        video.pointee.codec_id = AV_CODEC_ID_H264
        subtitle.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
        subtitle.pointee.codec_id = AV_CODEC_ID_HDMV_PGS_SUBTITLE
        try body(c, video, subtitle)
    }

    private func open(_ data: Data, seed: Bool) throws -> (bytes: Int, videoWidth: Int32, subtitleCodec: AVCodecID, subtitleWidth: Int32) {
        let reader = PGSProbeReader(data)
        let demuxer = Demuxer()
        var profile = DemuxerOpenProfile.playback
        profile.seedPGSCanvas = seed
        try demuxer.open(reader: reader, formatHint: "matroska", profile: profile)
        defer { demuxer.close() }
        let v = try #require(demuxer.stream(at: 0)?.pointee.codecpar)
        let s = try #require(demuxer.stream(at: 1)?.pointee.codecpar)
        #expect(s.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE)
        return (reader.bytes, v.pointee.width, s.pointee.codec_id, s.pointee.width)
    }

    // The H.264 access unit and configuration come from MultiSubtitleContainerFixture.
    // A declared PGS track has no packets: video still has to analyse correctly, but
    // waiting for the first subtitle can never improve this file's startup.
    private func fixture() -> Data {
        func element(_ id: [UInt8], _ payload: Data) -> Data {
            let size = UInt64(payload.count) | (1 << 56)
            var bytes = (0..<8).reversed().map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) }
            bytes[0] = 1
            return Data(id + bytes) + payload
        }
        func integer(_ id: [UInt8], _ value: UInt64) -> Data {
            element(id, Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }))
        }
        let avcc = Data(base64Encoded: "AULACv/hABVnQsAK2nsBEAAAAwAQAAADACDxImoBAAVozgGXIA==")!
        let frame = Data(base64Encoded: "AAAACWWIhDomKAAVwA==")!
        let header = element([0x1a,0x45,0xdf,0xa3], element([0x42,0x82], Data("matroska".utf8)))
        let info = element([0x15,0x49,0xa9,0x66], integer([0x2a,0xd7,0xb1], 1_000_000))
        let video = integer([0xd7], 1) + integer([0x73,0xc5], 1) + integer([0x83], 1)
            + element([0x86], Data("V_MPEG4/ISO/AVC".utf8)) + element([0x63,0xa2], avcc)
            + element([0xe0], integer([0xb0], 16) + integer([0xba], 16))
        let subtitle = integer([0xd7], 2) + integer([0x73,0xc5], 2) + integer([0x83], 17)
            + element([0x86], Data("S_HDMV/PGS".utf8))
        let tracks = element([0x16,0x54,0xae,0x6b], element([0xae], video) + element([0xae], subtitle))
        var clusters = Data()
        for i in 0..<100 {
            let block = element([0xa3], Data([0x81,0,0,0x80]) + frame)
            let padding = element([0xec], Data(repeating: 0, count: 16384))
            clusters += element([0x1f,0x43,0xb6,0x75], integer([0xe7], UInt64(i * 1000)) + block + padding)
        }
        return header + element([0x18,0x53,0x80,0x67], info + tracks + clusters)
    }
}

private final class PGSProbeReader: IOReader, @unchecked Sendable {
    private let data: Data
    private var position = 0
    private(set) var bytes = 0
    var discImageProbeEnabled: Bool { false }
    init(_ data: Data) { self.data = data }
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return -1 }
        let count = min(Int(size), data.count - position)
        guard count > 0 else { return 0 }
        data.copyBytes(to: UnsafeMutableBufferPointer(start: buffer, count: count), from: position..<(position + count))
        position += count; bytes += count
        return Int32(count)
    }
    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence & 0x10000 != 0 { return Int64(data.count) }
        let base = whence & 3
        let target = (base == 0 ? 0 : base == 1 ? position : data.count) + Int(offset)
        guard target >= 0, target <= data.count else { return -1 }
        position = target; return Int64(target)
    }
    func close() {}
}

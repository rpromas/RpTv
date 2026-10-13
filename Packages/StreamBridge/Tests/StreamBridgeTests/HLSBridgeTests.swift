// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import FFmpeg
import Foundation
@testable import StreamBridge
import Testing

/// Runs the synthetic fixtures (test pattern plus a tone, six seconds each) through the bridge.
struct HLSBridgeTests {
    let directory: URL

    init() throws {
        directory = URL.temporaryDirectory.appending(component: "HLSBridgeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "ts", subdirectory: "Fixtures"))
    }

    /// Bridges a whole file and returns the plan it used.
    private func bridge(_ name: String) async throws -> BridgePlan {
        let bridge = HLSBridge(source: BridgeSource(url: try fixture(name), isLive: false), directory: directory)
        let events = AsyncStream<HLSBridge.Event> { continuation in
            bridge.start { event in
                continuation.yield(event)
                if case .ready = event { return }
                continuation.finish()
            }
        }
        var plan: BridgePlan?
        for await event in events {
            switch event {
            case .ready(let ready): plan = ready
            case .failed(let message): Issue.record("Bridge failed: \(message)")
            case .finished: break
            }
        }
        return try #require(plan)
    }

    private var playlist: String {
        get throws { try String(contentsOf: directory.appending(component: HLSBridge.playlistName), encoding: .utf8) }
    }

    /// Codec names and, for video, the field order and frame rate of a media file.
    private func probe(_ fileName: String) throws -> [String: String] {
        var context: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_open_input(&context, directory.appending(component: fileName).path, nil, nil) >= 0)
        defer { avformat_close_input(&context) }
        try #require(avformat_find_stream_info(context, nil) >= 0)
        var result: [String: String] = [:]
        for index in 0..<Int(context!.pointee.nb_streams) {
            let stream = context!.pointee.streams[index]!
            let parameters = stream.pointee.codecpar.pointee
            let name = String(cString: avcodec_get_name(parameters.codec_id))
            if parameters.codec_type == AVMEDIA_TYPE_VIDEO {
                result["video"] = name
                result["tag"] = parameters.codec_tag == 0 ? nil : String(bytes: withUnsafeBytes(of: parameters.codec_tag.littleEndian) { Array($0) }, encoding: .ascii)
                result["size"] = "\(parameters.width)x\(parameters.height)"
                result["level"] = String(parameters.level)
                let rate = av_guess_frame_rate(context, stream, nil)
                result["fps"] = String(Int((Double(rate.num) / Double(rate.den)).rounded()))
            } else if parameters.codec_type == AVMEDIA_TYPE_AUDIO {
                result["audio"] = name
            }
        }
        return result
    }

    @Test func copiesH264AndReencodesMP2ToAAC() async throws {
        let plan = try await bridge("h264_mp2")
        #expect(plan.video == .copy)
        #expect(plan.audio == .transcode)

        let text = try playlist
        #expect(text.contains("#EXT-X-ENDLIST"))
        #expect(text.components(separatedBy: "#EXTINF").count - 1 >= 2)
        let codecs = try probe("segment00000.ts")
        #expect(codecs["video"] == "h264")
        #expect(codecs["audio"] == "aac")
    }

    @Test func reencodesInterlacedMPEG2ToProgressiveH264() async throws {
        let plan = try await bridge("mpeg2_ac3_interlaced")
        #expect(plan.video == .transcode(deinterlace: true))
        #expect(plan.audio == .transcode)

        let codecs = try probe("segment00000.ts")
        #expect(codecs["video"] == "h264")
        #expect(codecs["audio"] == "aac")
        // One frame per field: 25i becomes 50p.
        #expect(codecs["fps"] == "50")
        // The fixture is anamorphic 16:9 (720×576 with 64:45 pixels): the output has square pixels instead.
        #expect(codecs["size"] == "1024x576")
        // 1024×576 at 50 fps needs level 3.2.
        #expect(codecs["level"] == "32")
    }

    @Test func deinterlacesInterlacedH264() async throws {
        let plan = try await bridge("h264_interlaced_mp2")
        #expect(plan.video == .transcode(deinterlace: true))
        #expect(plan.audio == .transcode)

        let codecs = try probe("segment00000.ts")
        #expect(codecs["video"] == "h264")
        #expect(codecs["audio"] == "aac")
        #expect(codecs["fps"] == "50")
    }

    @Test func remuxesHEVCIntoFragmentedMP4() async throws {
        let plan = try await bridge("hevc_aac")
        #expect(plan.segmentFormat == .fmp4)
        #expect(plan.isRemuxOnly)

        #expect(try playlist.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        let codecs = try probe("init.mp4")
        #expect(codecs["video"] == "hevc")
        #expect(codecs["tag"] == "hvc1")
        #expect(codecs["audio"] == "aac")
    }

    @Test func reportsMissingStreams() async throws {
        let bridge = HLSBridge(source: BridgeSource(url: directory.appending(component: "missing.ts"), isLive: false),
                               directory: directory)
        let failure = await withCheckedContinuation { continuation in
            bridge.start { event in
                if case .failed(let message) = event { continuation.resume(returning: message) }
                if case .finished = event { continuation.resume(returning: "") }
            }
        }
        #expect(!failure.isEmpty)
    }
}

// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import FFmpeg
@testable import StreamBridge
import Testing

struct BridgePlanTests {
    @Test func copiesWhatApplePlays() {
        let plan = BridgePlan(videoCodec: "h264", interlaced: false, audioCodec: "aac")
        #expect(plan.video == .copy)
        #expect(plan.audio == .copy)
        #expect(plan.segmentFormat == .mpegts)
        #expect(plan.isRemuxOnly)
    }

    /// The common European DVB case: H.264 with MPEG-1 Layer II audio.
    @Test func reencodesMP2Audio() {
        let plan = BridgePlan(videoCodec: "h264", interlaced: false, audioCodec: "mp2")
        #expect(plan.video == .copy)
        #expect(plan.audio == .transcode)
        #expect(!plan.isRemuxOnly)
    }

    /// 1080i broadcast channels: Apple's players won't take interlaced H.264 from HLS.
    @Test func deinterlacesInterlacedH264() {
        let plan = BridgePlan(videoCodec: "h264", interlaced: true, audioCodec: "mp2")
        #expect(plan.video == .transcode(deinterlace: true))
        #expect(plan.segmentFormat == .mpegts)
    }

    @Test func reencodesMPEG2Video() {
        let plan = BridgePlan(videoCodec: "mpeg2video", interlaced: true, audioCodec: "ac3")
        #expect(plan.video == .transcode(deinterlace: true))
        #expect(plan.audio == .transcode)
        #expect(plan.segmentFormat == .mpegts)
    }

    @Test func usesFragmentedMP4ForHEVC() {
        let plan = BridgePlan(videoCodec: "hevc", interlaced: false, audioCodec: "aac")
        #expect(plan.video == .copy)
        #expect(plan.audio == .copy)
        #expect(plan.segmentFormat == .fmp4)
    }

    /// Dolby audio is valid HLS but didn't start on Apple TV over AirPlay; AAC always does.
    @Test(arguments: ["ac3", "eac3", "mp3"])
    func reencodesOtherAudioToAAC(_ codec: String) {
        #expect(BridgePlan(videoCodec: "h264", interlaced: false, audioCodec: codec).audio == .transcode)
    }

    @Test func reencodesLATMAudio() {
        #expect(BridgePlan(videoCodec: "h264", interlaced: false, audioCodec: "aac_latm").audio == .transcode)
    }

    @Test func handlesRadio() {
        let plan = BridgePlan(videoCodec: nil, interlaced: false, audioCodec: "mp2")
        #expect(plan.video == nil)
        #expect(plan.audio == .transcode)
    }
}

struct EncoderLevelTests {
    @Test(arguments: [
        (704, 480, 30, "3.0"),
        // 480i60 SD after deinterlacing and square pixels: too fast for 3.0.
        (852, 480, 60, "3.1"),
        (1024, 576, 50, "3.2"),
        (1280, 720, 60, "3.2"),
        (1920, 1080, 25, "4.0"),
        (1920, 1080, 50, "4.2"),
        (3840, 2160, 50, "5.2"),
    ])
    func picksLevel(width: Int32, height: Int32, fps: Int32, expected: String) {
        #expect(VideoTranscoder.level(width: width, height: height, frameRate: AVRational(num: fps, den: 1)) == expected)
    }
}

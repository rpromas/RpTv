// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import FFmpeg
import Testing

/// Checks that the FFmpeg build has what the app relies on, and nothing it mustn't ship.
struct BuildConfigurationTests {
    @Test func isLGPL() {
        let license = String(cString: avcodec_license())
        #expect(license.contains("LGPL"))
        let configuration = String(cString: avcodec_configuration())
        #expect(!configuration.contains("--enable-gpl"))
        #expect(!configuration.contains("--enable-nonfree"))
    }

    /// The broadcast codecs Apple's players can't handle, which the app has to decode itself.
    @Test(arguments: ["mp2", "mpeg2video", "ac3", "eac3", "h264", "hevc", "aac", "mp3", "vc1"])
    func decodes(_ name: String) {
        #expect(avcodec_find_decoder_by_name(name) != nil)
    }

    /// Re-encoding goes through Apple's hardware encoders, with FFmpeg's own AAC encoder as a fallback.
    @Test(arguments: ["aac_at", "h264_videotoolbox", "hevc_videotoolbox", "aac"])
    func encodes(_ name: String) {
        #expect(avcodec_find_encoder_by_name(name) != nil)
    }

    // RTSP is a demuxer in FFmpeg, not an I/O protocol.
    @Test(arguments: ["mpegts", "hls", "mp4", "matroska", "flv", "rtsp"])
    func demuxes(_ name: String) {
        #expect(av_find_input_format(name) != nil)
    }

    @Test(arguments: ["mpegts", "hls", "mp4"])
    func muxes(_ name: String) {
        #expect(av_guess_format(name, nil, nil) != nil)
    }

    @Test(arguments: ["http", "https", "rtmp", "udp", "rtp"])
    func readsOverNetwork(_ name: String) {
        #expect(avio_find_protocol_name("\(name)://example.com/stream") != nil)
    }
}

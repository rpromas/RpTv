// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import FFmpeg
import Foundation

/// Demuxed packets of one stream, waiting for its decoder. The reading thread pushes; one decoding thread pops.
///
/// Every packet carries the queue's serial at the time it was pushed. A seek flushes the queue and moves to a new
/// serial, so a decoder that sees a new serial knows to flush itself too.
final class PacketQueue: @unchecked Sendable {
    enum Item {
        /// A packet the caller now owns and frees with `av_packet_free`.
        case packet(UnsafeMutablePointer<AVPacket>, serial: Int)
        /// The stream has ended and every packet has been taken.
        case end(serial: Int)
        case timedOut
    }

    private struct Entry {
        var packet: UnsafeMutablePointer<AVPacket>
        var time: Double?
        var serial: Int
    }

    private let condition = NSCondition()
    private var entries: [Entry] = []
    private var head = 0
    private var _serial = 0
    private var _isFinished = false
    private var _bytes = 0
    private var _latestTime: Double?

    deinit {
        for entry in entries[head...] {
            var packet: UnsafeMutablePointer<AVPacket>? = entry.packet
            av_packet_free(&packet)
        }
    }

    var serial: Int { locked { _serial } }
    var bytes: Int { locked { _bytes } }
    var isFinished: Bool { locked { _isFinished } }
    /// The latest timestamp pushed since the last flush: how far this stream has been read.
    var latestTime: Double? { locked { _latestTime } }

    /// How much playing time is waiting, from the oldest packet to the newest.
    var duration: Double {
        locked {
            guard head < entries.count, let first = entries[head...].lazy.compactMap(\.time).first,
                  let latest = _latestTime else { return 0 }
            return max(0, latest - first)
        }
    }

    /// Takes over `packet`'s data, leaving it empty for reuse.
    func push(_ packet: UnsafeMutablePointer<AVPacket>, time: Double?) {
        let copy = av_packet_alloc()!
        av_packet_move_ref(copy, packet)
        condition.lock()
        entries.append(Entry(packet: copy, time: time, serial: _serial))
        _bytes += Int(copy.pointee.size)
        if let time { _latestTime = max(_latestTime ?? time, time) }
        condition.signal()
        condition.unlock()
    }

    /// The next packet, or `.timedOut` when none arrives within `timeout` seconds.
    func pop(timeout: TimeInterval) -> Item {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while head == entries.count {
            if _isFinished { return .end(serial: _serial) }
            if !condition.wait(until: deadline) { return .timedOut }
        }
        let entry = entries[head]
        head += 1
        _bytes -= Int(entry.packet.pointee.size)
        compact()
        return .packet(entry.packet, serial: entry.serial)
    }

    /// Drops everything and starts a new serial.
    func flush(serial: Int) {
        condition.lock()
        for entry in entries[head...] {
            var packet: UnsafeMutablePointer<AVPacket>? = entry.packet
            av_packet_free(&packet)
        }
        entries = []
        head = 0
        _bytes = 0
        _latestTime = nil
        _isFinished = false
        _serial = serial
        condition.broadcast()
        condition.unlock()
    }

    /// Drops packets from before `time`. Keeps the queues of tracks nobody listens to short, while leaving what a
    /// switch to them needs.
    func dropOlder(than time: Double) {
        condition.lock()
        while head < entries.count, let packetTime = entries[head].time, packetTime < time {
            _bytes -= Int(entries[head].packet.pointee.size)
            var packet: UnsafeMutablePointer<AVPacket>? = entries[head].packet
            av_packet_free(&packet)
            head += 1
        }
        compact()
        condition.unlock()
    }

    /// No more packets will come until the next flush.
    func finish() {
        condition.lock()
        _isFinished = true
        condition.broadcast()
        condition.unlock()
    }

    /// Reclaims the space of popped entries now and then. Called with the lock held.
    private func compact() {
        if head > 256, head * 2 > entries.count {
            entries.removeFirst(head)
            head = 0
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        condition.lock()
        defer { condition.unlock() }
        return body()
    }
}

// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum LocalNetwork {
    /// The device's IPv4 address on Wi-Fi (or wired Ethernet), which an AirPlay receiver on the same network can
    /// reach. `nil` when there's no such network.
    public static func address() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }

        var candidates: [(name: String, address: String)] = []
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: interface.pointee.ifa_name)
            candidates.append((name, host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }))
        }
        // en0 is Wi-Fi on iPhone and iPad; other en* interfaces are Ethernet adapters. Cellular (pdp_ip*) can't
        // reach an Apple TV, so it's never used.
        return candidates.first { $0.name == "en0" }?.address
            ?? candidates.first { $0.name.hasPrefix("en") }?.address
    }
}

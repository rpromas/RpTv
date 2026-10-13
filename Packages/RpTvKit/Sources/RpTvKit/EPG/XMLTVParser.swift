// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public struct XMLTVChannel: Sendable, Hashable {
    public var id: String
    public var displayNames: [String]
    public var iconURL: String?
}

public struct XMLTVProgramme: Sendable, Hashable {
    public var channel: String
    public var start: Date
    public var stop: Date?
    public var title: String
    public var summary: String?
    public var category: String?
    public var iconURL: String?
}

public enum XMLTVError: LocalizedError, Equatable {
    case invalid(line: Int)

    public var errorDescription: String? {
        switch self {
        case .invalid(let line): "The TV guide isn't valid XMLTV (line \(line))."
        }
    }
}

/// Streams an XMLTV file, handing each `<channel>` and `<programme>` to a callback as it is read,
/// so even a guide of several hundred megabytes never sits in memory.
public enum XMLTVParser {
    /// Parses `file`. Programmes without a valid `start` or `channel` are skipped. When the XML breaks
    /// partway (a truncated download, a stray `&`), whatever was read before stays delivered; it only
    /// throws when nothing usable was found. Errors thrown by the callbacks stop parsing and are rethrown.
    public static func parse(
        _ file: URL,
        channel: (XMLTVChannel) throws -> Void,
        programme: (XMLTVProgramme) throws -> Void
    ) throws {
        guard let stream = InputStream(url: file) else { throw CocoaError(.fileReadNoSuchFile) }
        try withoutActuallyEscaping(channel) { channel in
            try withoutActuallyEscaping(programme) { programme in
                let parser = XMLParser(stream: stream)
                let delegate = Delegate(onChannel: channel, onProgramme: programme)
                parser.delegate = delegate
                parser.shouldResolveExternalEntities = false
                if parser.parse() { return }
                if let error = delegate.error { throw error }
                if delegate.itemCount == 0 {
                    if let streamError = stream.streamError { throw streamError }
                    throw XMLTVError.invalid(line: parser.lineNumber)
                }
            }
        }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let onChannel: (XMLTVChannel) throws -> Void
        let onProgramme: (XMLTVProgramme) throws -> Void
        var error: Error?
        var itemCount = 0

        private var channel: XMLTVChannel?
        private var programme: XMLTVProgramme?
        /// The leaf element whose text is being collected.
        private var textElement: String?
        private var text = ""

        init(onChannel: @escaping (XMLTVChannel) throws -> Void, onProgramme: @escaping (XMLTVProgramme) throws -> Void) {
            self.onChannel = onChannel
            self.onProgramme = onProgramme
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            switch name {
            case "programme":
                guard let channel = attributes["channel"]?.trimmed.nonEmpty,
                      let start = attributes["start"].flatMap(XMLTVDate.parse) else { return }
                programme = XMLTVProgramme(channel: channel, start: start, stop: attributes["stop"].flatMap(XMLTVDate.parse), title: "")
            case "channel":
                guard let id = attributes["id"]?.trimmed.nonEmpty else { return }
                channel = XMLTVChannel(id: id, displayNames: [])
            case "title", "desc", "category":
                if programme != nil { beginText(name) }
            case "display-name":
                if channel != nil { beginText(name) }
            case "icon":
                let src = attributes["src"]?.trimmed.nonEmpty
                if programme != nil, programme?.iconURL == nil {
                    programme?.iconURL = src
                } else if channel != nil, channel?.iconURL == nil {
                    channel?.iconURL = src
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if textElement != nil { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == textElement {
                let value = text.trimmed.nonEmpty
                textElement = nil
                switch name {
                case "title" where programme?.title.isEmpty == true: programme?.title = value ?? ""
                case "desc" where programme?.summary == nil: programme?.summary = value
                case "category" where programme?.category == nil: programme?.category = value
                case "display-name": if let value { channel?.displayNames.append(value) }
                default: break
                }
                return
            }
            switch name {
            case "programme":
                guard let item = programme else { return }
                programme = nil
                deliver(parser) { try onProgramme(item) }
            case "channel":
                guard let item = channel else { return }
                channel = nil
                deliver(parser) { try onChannel(item) }
            default:
                break
            }
        }

        private func beginText(_ name: String) {
            textElement = name
            text = ""
        }

        private func deliver(_ parser: XMLParser, _ body: () throws -> Void) {
            do {
                itemCount += 1
                if itemCount.isMultiple(of: 4096) { try Task.checkCancellation() }
                try body()
            } catch {
                self.error = error
                parser.abortParsing()
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

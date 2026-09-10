import Foundation

/// Message framing on the Scope socket.
///
/// The socket carries two kinds of traffic. `scope-hook` writes one JSON object and half-closes, so a hook
/// message is delimited by end-of-file and never answered. A control request (the `scope` CLI, the MCP
/// server) needs an answer on the same connection, which rules out end-of-file as its delimiter: the client
/// keeps the connection open to read the reply.
///
/// A control frame therefore announces itself:
///
/// ```
/// scope-rpc/1\n{"method":"list",…}\n
/// ```
///
/// The magic header is what tells the two apart — not a field inside the JSON. `JSONStore.makeEncoder` is
/// pretty-printed, so a hook message contains literal newlines and cannot be delimited by scanning for one;
/// a hook message also always starts with `{`, so it can never be mistaken for a frame.
public enum SocketFrame {
    /// Start of a control frame's header line.
    public static let magic = "scope-rpc/"
    /// Framing version this build writes. Bumped only if the *framing* changes; the payload carries its own.
    public static let version = 1
    /// Longest header line accepted before the frame is called malformed.
    static let maxHeaderBytes = 32

    /// What the bytes read so far amount to.
    public enum Classification: Equatable {
        /// Could still become a control frame; read more.
        case incomplete
        /// Not a control frame: a hook message, delimited by end-of-file.
        case hookMessage
        /// A complete control frame.
        case frame(version: Int, body: Data)
        /// Starts like a frame but cannot be one.
        case malformed(String)
    }

    /// Wraps `body` (one line of JSON) as a control frame.
    public static func encode(_ body: Data, version: Int = SocketFrame.version) -> Data {
        var data = Data("\(magic)\(version)\n".utf8)
        data.append(body)
        data.append(0x0A)
        return data
    }

    /// Classifies the bytes received so far. Pure; called on every socket read.
    public static func classify(_ buffer: Data) -> Classification {
        let magicBytes = Array(magic.utf8)
        if buffer.count < magicBytes.count {
            return buffer.elementsEqual(magicBytes[..<buffer.count]) ? .incomplete : .hookMessage
        }
        guard buffer.prefix(magicBytes.count).elementsEqual(magicBytes) else { return .hookMessage }
        guard let headerEnd = buffer.firstIndex(of: 0x0A) else {
            return buffer.count > maxHeaderBytes ? .malformed("header line has no newline") : .incomplete
        }
        let header = String(decoding: buffer[buffer.startIndex..<headerEnd], as: UTF8.self)
        guard let version = Int(header.dropFirst(magic.count)), version > 0 else {
            return .malformed("unreadable header “\(header)”")
        }
        let bodyStart = buffer.index(after: headerEnd)
        guard let bodyEnd = buffer[bodyStart...].firstIndex(of: 0x0A) else { return .incomplete }
        return .frame(version: version, body: Data(buffer[bodyStart..<bodyEnd]))
    }

    /// Splits a reply — newline-separated JSON lines — into its frames. Empty lines are dropped.
    public static func lines(_ data: Data) -> [Data] {
        data.split(separator: UInt8(0x0A), omittingEmptySubsequences: true).map { Data($0) }
    }
}

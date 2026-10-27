import Foundation

/// A problem's title as written at the call site: the text the user reads, and the same text with every
/// interpolation replaced by `{}`. The journal keeps the second, which holds what the code says and nothing the
/// user named — `"The setup of {} failed"`, never the task.
public struct ProblemTitle: ExpressibleByStringInterpolation, Sendable, Equatable {
    public let text: String
    /// `nil` for a title built at run time (`init(verbatim:)`): nothing tells its words from the data.
    public let template: String?

    public init(stringLiteral value: String) {
        text = value
        template = value
    }

    public init(stringInterpolation: Interpolation) {
        text = stringInterpolation.text
        template = stringInterpolation.template
    }

    /// A title that came whole from elsewhere (an error's own title): shown as is, never journaled.
    public init(verbatim text: String) {
        self.text = text
        template = nil
    }

    public struct Interpolation: StringInterpolationProtocol {
        var text = ""
        var template = ""

        public init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity)
        }

        public mutating func appendLiteral(_ literal: String) {
            text += literal
            template += literal
        }

        public mutating func appendInterpolation(_ value: some Any) {
            text += String(describing: value)
            template += "{}"
        }
    }
}

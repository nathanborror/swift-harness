import Foundation
import Testing

enum Fixtures {
    static func sse(_ name: String) throws -> [String] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "sse", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.components(separatedBy: "\n")
    }
}

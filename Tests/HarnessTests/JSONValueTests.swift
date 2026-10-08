import Foundation
import Testing
@testable import Harness

@Suite struct JSONValueTests {
    @Test func roundTripsThroughCodable() throws {
        let value: JSONValue = ["a": 1, "b": [true, "x", nil], "c": ["d": 2.5]]
        let data = try value.encoded()
        let decoded = try JSONValue(data: data)
        #expect(decoded == value)
        #expect(decoded["c"]?["d"]?.doubleValue == 2.5)
        #expect(decoded["a"]?.intValue == 1)
        #expect(decoded["b"]?[2]?.isNull == true)
    }

    @Test func encodesIntegersWithoutFraction() throws {
        let text = try JSONValue.object(["n": 3]).encodedString()
        #expect(text == "{\"n\":3}")
    }

    @Test func sortsKeysForStableBytes() throws {
        let first = try JSONValue.object(["b": 1, "a": 2]).encodedString()
        let second = try JSONValue.object(["a": 2, "b": 1]).encodedString()
        #expect(first == second)
    }
}

import Foundation
import GelKit
import GelMCP

/// The most a tool takes. These match the limits GelKit puts on a project it loads, so whatever an LLM sends can't crash
/// the app, and can't be saved into a project that crashes when it's opened.
enum Limits {
    /// A position in pixels, either way from the corner.
    static let coordinate = 1_000_000.0
    /// A ladder size (kDa or bp).
    static let size = 1e12
    /// Lanes in a gel: also the most dividers and the most lanes a detection may be asked for.
    static let lanes = 4096
    /// Label rows above the gel.
    static let rows = 64
    /// Ticks in one set_ladder call.
    static let ticks = 1000
    /// One title, name, unit or font, in bytes.
    static let text = 4096
    /// The lane-label shorthand, in bytes.
    static let shorthand = 200_000
}

/// Numbers as the messages say them: no ".0" on whole values.
private func show(_ d: Double) -> String {
    d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
}

/// Reading a tool's arguments. A present argument must be the right kind and inside its range, or the call fails with a
/// message that names it; nothing is ignored silently, and nothing that isn't a sane number gets past here.
extension JSONValue {
    /// A given argument. Null counts as not given (models often send null for what they leave out). (Not a `flatMap` with
    /// `nil` inside: JSONValue takes a nil literal itself, so that would hand back `.null` instead of nothing.)
    private func given(_ key: String) -> JSONValue? {
        guard let v = self[key], !v.isNull else { return nil }
        return v
    }

    func optString(_ key: String, max: Int = Limits.text) throws -> String? {
        guard let v = given(key) else { return nil }
        guard let s = v.stringValue else { throw MCPToolError("\(key) must be text.") }
        guard s.utf8.count <= max else { throw MCPToolError("\(key) is too long (at most \(max) characters).") }
        return s
    }

    func reqString(_ key: String, max: Int = Limits.text) throws -> String {
        guard let s = try optString(key, max: max) else { throw MCPToolError("\(key) is required.") }
        return s
    }

    func optInt(_ key: String, _ range: ClosedRange<Int>) throws -> Int? {
        guard let v = given(key) else { return nil }
        guard let i = v.intValue, range.contains(i) else {
            throw MCPToolError("\(key) must be a whole number from \(range.lowerBound) to \(range.upperBound).")
        }
        return i
    }

    func reqInt(_ key: String, _ range: ClosedRange<Int>) throws -> Int {
        guard let i = try optInt(key, range) else { throw MCPToolError("\(key) is required.") }
        return i
    }

    func optNumber(_ key: String, _ range: ClosedRange<Double>) throws -> Double? {
        guard let v = given(key) else { return nil }
        guard let d = v.doubleValue, range.contains(d) else {   // a range never holds NaN or infinity
            throw MCPToolError("\(key) must be a number from \(show(range.lowerBound)) to \(show(range.upperBound)).")
        }
        return d
    }

    func reqNumber(_ key: String, _ range: ClosedRange<Double>) throws -> Double {
        guard let d = try optNumber(key, range) else { throw MCPToolError("\(key) is required.") }
        return d
    }

    /// A ladder size: above 0, or null/absent for none.
    func optSize(_ key: String) throws -> Double? {
        guard let v = given(key) else { return nil }
        guard let d = v.doubleValue, d > 0, d <= Limits.size else {
            throw MCPToolError("\(key) must be a number above 0 and at most \(show(Limits.size)), or null.")
        }
        return d
    }

    func optBool(_ key: String) throws -> Bool? {
        guard let v = given(key) else { return nil }
        guard let b = v.boolValue else { throw MCPToolError("\(key) must be true or false.") }
        return b
    }

    /// A list of at most `count` numbers, each inside `range`.
    func numbers(_ key: String, in range: ClosedRange<Double>, atMost count: Int) throws -> [Double] {
        guard let a = self[key]?.arrayValue else { throw MCPToolError("\(key) must be a list of numbers.") }
        guard a.count <= count else { throw MCPToolError("\(key) has too many numbers (at most \(count)).") }
        return try a.map { v in
            guard let d = v.doubleValue, range.contains(d) else {
                throw MCPToolError("\(key) must hold only numbers from \(show(range.lowerBound)) to \(show(range.upperBound)).")
            }
            return d
        }
    }
}

extension Optional {
    func orThrow(_ msg: String) throws -> Wrapped {
        guard let v = self else { throw MCPToolError(msg) }
        return v
    }
}

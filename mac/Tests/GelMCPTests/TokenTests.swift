import Foundation
import Testing
@testable import GelMCP

// The token's whole life, on a stand-in for the Keychain: these never touch the real one.

private final class FakeSecrets: SecretStore, @unchecked Sendable {
    struct Refused: Error, LocalizedError { var errorDescription: String? { "refused" } }
    private let lock = NSLock()
    private var value: String?
    var failRead = false, failSave = false
    private(set) var saves = 0

    init(_ value: String? = nil) { self.value = value }
    var stored: String? { lock.lock(); defer { lock.unlock() }; return value }
    func read() throws -> String? {
        if failRead { throw Refused() }
        return stored
    }
    func save(_ secret: String) throws {
        if failSave { throw Refused() }
        lock.lock(); value = secret; saves += 1; lock.unlock()
    }
}

private let oldToken = String(repeating: "ab12", count: 12)
private let newToken = String(repeating: "cd34", count: 12)

@Suite struct Tokens {
    @Test func aFreshInstallMakesOneAndKeepsItInTheKeychain() throws {
        let kc = FakeSecrets()
        let a = TokenStore(secrets: kc).load(legacy: nil, forgetLegacy: { Issue.record("nothing to forget") })
        #expect(MCPToken.isUsable(a.token) && a.note == nil)
        #expect(kc.stored == a.token)
        // the next launch finds the same one
        #expect(TokenStore(secrets: kc).load(legacy: nil, forgetLegacy: {}, make: { Issue.record("not needed"); return "x" }).token == a.token)
    }

    @Test func anOldTokenInThePreferencesMovesOnceAndIsThenForgotten() {
        let kc = FakeSecrets()
        var forgotten = 0
        let a = TokenStore(secrets: kc).load(legacy: oldToken, forgetLegacy: { forgotten += 1 })
        #expect(a.token == oldToken && a.note == nil, "the commands people already set up keep working")
        #expect(kc.stored == oldToken && forgotten == 1)
        // only after the Keychain holds it
        let locked = FakeSecrets(); locked.failSave = true
        var kept = true
        let b = TokenStore(secrets: locked).load(legacy: oldToken, forgetLegacy: { kept = false })
        #expect(b.token == oldToken && b.note != nil && kept, "not removed from the preferences until it is safe")
    }

    @Test func theKeychainWinsOverAnOldCopyWhichIsThenRemoved() {
        let kc = FakeSecrets(newToken)
        var forgotten = 0
        let a = TokenStore(secrets: kc).load(legacy: oldToken, forgetLegacy: { forgotten += 1 })
        #expect(a.token == newToken && kc.stored == newToken && forgotten == 1 && kc.saves == 0)
    }

    @Test func aKeychainThatCantBeReadIsNeverWrittenOver() {
        let kc = FakeSecrets(newToken); kc.failRead = true
        var forgotten = 0
        let a = TokenStore(secrets: kc).load(legacy: nil, forgetLegacy: { forgotten += 1 })
        #expect(MCPToken.isUsable(a.token) && a.token != newToken && a.note != nil, "a token for this session, said so")
        #expect(kc.stored == newToken && kc.saves == 0, "what may be in the Keychain stays")
        let b = TokenStore(secrets: kc).load(legacy: oldToken, forgetLegacy: { forgotten += 1 })
        #expect(b.token == oldToken && forgotten == 0 && kc.saves == 0)
    }

    @Test func aKeychainThatWontTakeItGivesASessionTokenAndSaysSo() {
        let kc = FakeSecrets(); kc.failSave = true
        let a = TokenStore(secrets: kc).load(legacy: nil, forgetLegacy: {})
        #expect(MCPToken.isUsable(a.token) && a.note?.contains("until GelScribe quits") == true)
    }

    @Test func noSecureTokenMeansNoToken() {
        struct NoRandom: Error {}
        let a = TokenStore(secrets: FakeSecrets()).load(legacy: nil, forgetLegacy: {}, make: { throw NoRandom() })
        #expect(a.token.isEmpty && a.note != nil && !MCPToken.isUsable(a.token))
        #expect(throws: NoRandom.self) { try TokenStore(secrets: FakeSecrets()).regenerate(make: { throw NoRandom() }) }
    }

    @Test func aNewTokenReplacesTheStoredOne() throws {
        let kc = FakeSecrets(oldToken)
        let a = try TokenStore(secrets: kc).regenerate()
        #expect(a.token != oldToken && kc.stored == a.token && a.note == nil)
        kc.failSave = true
        let b = try TokenStore(secrets: kc).regenerate()
        #expect(b.note != nil && kc.stored == a.token)
    }

    @Test func tokensAreLongRandomAndShownMasked() throws {
        let a = try MCPToken.make(), b = try MCPToken.make()
        #expect(a.count == 48 && a != b && a.allSatisfy(\.isHexDigit))
        #expect(MCPToken.masked(a) == String(a.prefix(4)) + "••••••••" && !MCPToken.masked(a).contains(a.dropFirst(4)))
    }
}

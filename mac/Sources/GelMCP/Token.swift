import Foundation
import Security

/// Where the HTTP token is kept between launches. The Keychain, never a preferences file (a protocol, so tests use a
/// stand-in and never touch the real one).
public protocol SecretStore: Sendable {
    /// The stored secret, or nil when there isn't one. Throws when the store can't be read (locked, access refused).
    func read() throws -> String?
    func save(_ secret: String) throws
}

public struct SecurityError: Error, LocalizedError, Sendable {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
    public var errorDescription: String? { SecCopyErrorMessageString(status, nil) as String? ?? "Security error \(status)" }
}

/// One generic-password item in the user's login keychain.
public struct KeychainSecret: SecretStore {
    public let service: String
    public let account: String
    /// What Keychain Access calls it.
    public let label: String
    public init(service: String, account: String, label: String = "GelScribe LLM access token") {
        self.service = service; self.account = account; self.label = label
    }

    private var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read() throws -> String? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        switch status {
        case errSecSuccess: return (found as? Data).flatMap { String(data: $0, encoding: .utf8) }
        case errSecItemNotFound: return nil
        default: throw SecurityError(status: status)
        }
    }

    public func save(_ secret: String) throws {
        let data = Data(secret.utf8)
        let updated = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw SecurityError(status: updated) }
        var add = item
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecurityError(status: status) }
    }
}

public enum MCPToken {
    /// Shortest token the server runs with.
    public static let minLength = 32

    /// 24 random bytes as 48 hex digits. Throws if the system can't supply random bytes: nothing weaker is ever used.
    public static func make() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw SecurityError(status: status) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func isUsable(_ token: String) -> Bool { token.count >= minLength }

    /// The token with all but its first four characters hidden, for showing on screen.
    public static func masked(_ token: String) -> String { token.prefix(4) + String(repeating: "•", count: 8) }
}

/// Finds, makes and replaces the token. An older version kept it in the preferences file; that copy is moved to the
/// Keychain once and removed from the file only after the Keychain holds it.
public struct TokenStore {
    public let secrets: SecretStore
    public init(secrets: SecretStore) { self.secrets = secrets }

    public struct Loaded: Sendable {
        /// Empty only when no secure token could be made: the server must not run then.
        public var token: String
        /// Something to tell the user, when the token isn't safely kept.
        public var note: String?
    }

    static let session = "It lasts until GelScribe quits, then a new one is made."

    /// `legacy`: the token an older version left in the preferences file, if any. `forgetLegacy` removes it from there.
    public func load(legacy: String?, forgetLegacy: () -> Void, make: () throws -> String = MCPToken.make) -> Loaded {
        let old = legacy.flatMap { MCPToken.isUsable($0) ? $0 : nil }
        let stored: String?
        do { stored = try secrets.read() } catch {
            // The Keychain can't be read (locked, or access refused). What may be in it is never replaced.
            if let old { return Loaded(token: old, note: "The Keychain couldn't be read, so the token wasn't moved there yet.") }
            return fresh(make, note: "The Keychain couldn't be read. " + Self.session, save: false)
        }
        if let stored, MCPToken.isUsable(stored) {
            if legacy != nil { forgetLegacy() }   // an old copy in the preferences file isn't needed now
            return Loaded(token: stored, note: nil)
        }
        if let old {
            do { try secrets.save(old) } catch {
                return Loaded(token: old, note: "The token couldn't be moved to the Keychain yet: \(error.localizedDescription)")
            }
            forgetLegacy()
            return Loaded(token: old, note: nil)
        }
        return fresh(make, note: nil)
    }

    /// A new token, replacing the one stored.
    public func regenerate(make: () throws -> String = MCPToken.make) throws -> Loaded {
        let token = try make()
        do { try secrets.save(token) } catch {
            return Loaded(token: token, note: "The Keychain wouldn't take the token: \(error.localizedDescription). " + Self.session)
        }
        return Loaded(token: token, note: nil)
    }

    private func fresh(_ make: () throws -> String, note: String?, save: Bool = true) -> Loaded {
        guard let token = try? make() else { return Loaded(token: "", note: "GelScribe couldn't make a secure token, so LLM access is off.") }
        if save {
            do { try secrets.save(token) } catch {
                return Loaded(token: token, note: "The Keychain wouldn't take the token: \(error.localizedDescription). " + Self.session)
            }
        }
        return Loaded(token: token, note: note)
    }
}

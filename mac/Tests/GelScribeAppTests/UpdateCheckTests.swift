import Foundation
import Testing
@testable import GelScribeApp

private let sample = Data(#"{"tag_name":"v0.1.2","html_url":"https://github.com/pratiman-de/GelScribe/releases/tag/v0.1.2","body":"Fixes\n\n- one\n- two"}"#.utf8)

private func freshDefaults() -> UserDefaults {
    let name = "UpdateCheckTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

private final class Counter: @unchecked Sendable { var n = 0; var agent: String? }

@MainActor @Suite struct UpdateCheckTests {
    @Test func versionOrder() {
        let order = ["0.1", "0.1.1", "0.1.10", "0.2", "0.10", "1.0"]
        for i in order.indices { for j in order.indices {
            #expect(UpdateCheck.isNewer(order[i], than: order[j]) == (i > j), "\(order[i]) vs \(order[j])")
        } }
        #expect(UpdateCheck.isNewer("v0.1.1", than: "0.1"))
        #expect(!UpdateCheck.isNewer("v0.1.1", than: "0.1.1"))
        #expect(!UpdateCheck.isNewer("0.1.0", than: "0.1"))
        #expect(!UpdateCheck.isNewer("nightly", than: "0.1"))
    }

    @Test func parsesRelease() throws {
        let r = try #require(UpdateCheck.parseRelease(sample))
        #expect(r.version == "0.1.2")
        #expect(r.url.absoluteString.hasSuffix("v0.1.2"))
        #expect(UpdateCheck.excerpt(r.notes) == "Fixes\n- one\n- two")
        #expect(UpdateCheck.excerpt(String(repeating: "x\n", count: 20)).split(separator: "\n").count == 6)
        #expect(UpdateCheck.parseRelease(Data("not json".utf8)) == nil)
        #expect(UpdateCheck.parseRelease(Data(#"{"tag_name":"v1"}"#.utf8)) == nil)
    }

    @Test func findsNewerAndSendsOnlyAUserAgent() async {
        let seen = Counter()
        let outcome = await UpdateCheck.run(manual: false, current: "0.1.1", defaults: freshDefaults()) { req in
            seen.n += 1; seen.agent = req.value(forHTTPHeaderField: "User-Agent")
            #expect(req.timeoutInterval == 10)
            return sample
        }
        guard case .newer(let r) = outcome else { Issue.record("expected newer"); return }
        #expect(r.version == "0.1.2")
        #expect(seen.agent == "GelScribe/0.1.1")
        #expect(await UpdateCheck.run(manual: false, current: "0.1.2", defaults: freshDefaults()) { _ in sample } == .upToDate)
    }

    @Test func throttlesToOncePerDay() async {
        let d = freshDefaults(), calls = Counter(), t0 = Date()
        let fetch: UpdateCheck.Fetch = { _ in calls.n += 1; return sample }
        _ = await UpdateCheck.run(manual: false, current: "0.1", now: t0, defaults: d, fetch: fetch)
        #expect(await UpdateCheck.run(manual: false, current: "0.1", now: t0 + 3600, defaults: d, fetch: fetch) == .skipped)
        #expect(calls.n == 1)
        _ = await UpdateCheck.run(manual: false, current: "0.1", now: t0 + 25 * 3600, defaults: d, fetch: fetch)
        #expect(calls.n == 2)
        _ = await UpdateCheck.run(manual: true, current: "0.1", now: t0 + 25 * 3600 + 1, defaults: d, fetch: fetch)
        #expect(calls.n == 3)   // a manual check ignores the throttle
    }

    @Test func disabledSettingStopsAutomaticOnly() async {
        let d = freshDefaults(), calls = Counter()
        d.set(false, forKey: UpdateCheck.enabledKey)
        let fetch: UpdateCheck.Fetch = { _ in calls.n += 1; return sample }
        #expect(await UpdateCheck.run(manual: false, current: "0.1", defaults: d, fetch: fetch) == .skipped)
        #expect(calls.n == 0)
        if case .newer = await UpdateCheck.run(manual: true, current: "0.1", defaults: d, fetch: fetch) {} else { Issue.record("manual should check") }
    }

    @Test func errorsAreSilentAndRetried() async {
        let d = freshDefaults()
        struct Offline: Error {}
        #expect(await UpdateCheck.run(manual: false, current: "0.1", defaults: d) { _ in throw Offline() } == .failed)
        #expect(await UpdateCheck.run(manual: false, current: "0.1", defaults: d) { _ in Data("{".utf8) } == .failed)
        #expect(d.object(forKey: UpdateCheck.lastCheckKey) == nil)   // nothing stored, so the next launch tries again
        if case .newer = await UpdateCheck.run(manual: false, current: "0.1", defaults: d) { _ in sample } {} else { Issue.record("retry should work") }
    }
}

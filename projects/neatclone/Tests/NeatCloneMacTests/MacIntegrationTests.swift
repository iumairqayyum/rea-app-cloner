#if os(macOS)
import XCTest
@testable import NeatClone
import NeatCloneCore

final class MacIntegrationTests: XCTestCase {
    func testIsolatedKeychainRoundTripAndExactScope() throws {
        let service = "org.neatclone.test." + UUID().uuidString
        let store = KeychainCredentialStore(service:service)
        let scope = try CredentialScope(url:URL(string:"https://credentials-test.invalid:8443")!)
        let other = try CredentialScope(url:URL(string:"https://credentials-test.invalid")!)
        defer { try? store.delete(for:scope); try? store.delete(for:other) }
        XCTAssertNil(try store.load(for:scope))
        let value = StoredCredential(username:"fixture-user",password:"local-fixture-password")
        try store.save(value,for:scope)
        XCTAssertEqual(try store.load(for:scope),value)
        XCTAssertNil(try store.load(for:other))
        let replaced = StoredCredential(username:"fixture-user",password:"replacement-fixture")
        try store.save(replaced,for:scope)
        XCTAssertEqual(try store.load(for:scope),replaced)
        try store.delete(for:scope); XCTAssertNil(try store.load(for:scope))
        XCTAssertThrowsError(try store.save(StoredCredential(username:"invalid:user",password:"not-saved"),for:scope))
    }
}
#endif

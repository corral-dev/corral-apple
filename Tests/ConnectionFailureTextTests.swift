import Foundation
import XCTest
@testable import Corral

final class ConnectionFailureTextTests: XCTestCase {
    func testKeychainFailuresGetRecoveryCopy() {
        XCTAssertEqual(ConnectionFailureText.copy(for: HostKeychainError.invalidKeyLength), .keychainUnavailable)
        XCTAssertEqual(ConnectionFailureText.copy(for: HostKeychainError.keychainReadFailed(-25293)), .keychainUnavailable)
        XCTAssertEqual(ConnectionFailureText.copy(for: HostKeychainError.keychainWriteFailed(-34018)), .keychainUnavailable)
    }

    func testOrdinaryErrorsKeepTheirOwnText() {
        struct PlainError: Error {}
        XCTAssertNil(ConnectionFailureText.copy(for: PlainError()))
    }
}

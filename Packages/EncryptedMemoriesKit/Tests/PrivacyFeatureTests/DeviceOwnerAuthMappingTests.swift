import Foundation
import LocalAuthentication
import PhotosCore
import PrivacyFeature
import XCTest

final class DeviceOwnerAuthMappingTests: XCTestCase {
    private var ownerFallback: DeviceOwnerAuthMethod {
        #if os(macOS)
            .accountPassword
        #else
            .devicePasscode
        #endif
    }

    func testBiometryIsNamedOnlyWhenBiometricEvaluationCanRun() {
        let named: [(LABiometryType, DeviceOwnerAuthMethod)] = [
            (.faceID, .faceID), (.touchID, .touchID), (.opticID, .opticID),
        ]
        for (type, method) in named {
            XCTAssertEqual(
                DeviceOwnerAuthMapping.availability(
                    biometrics: true, biometryType: type, deviceOwner: true, deviceOwnerError: nil),
                .available(method))
            XCTAssertEqual(
                DeviceOwnerAuthMapping.availability(
                    biometrics: false, biometryType: type, deviceOwner: true, deviceOwnerError: nil),
                .available(ownerFallback), "\(type) not enrolled or locked out names the passcode or password")
        }
    }

    func testWithoutBiometryTheDeviceOwnerMethodIsNamed() {
        XCTAssertEqual(
            DeviceOwnerAuthMapping.availability(
                biometrics: true, biometryType: .none, deviceOwner: true, deviceOwnerError: nil),
            .available(ownerFallback))
        XCTAssertEqual(
            DeviceOwnerAuthMapping.availability(
                biometrics: false, biometryType: .none, deviceOwner: true, deviceOwnerError: nil),
            .available(ownerFallback))
    }

    func testOnlyAMissingPasscodeMeansThereIsNoDeviceLock() {
        for type in [LABiometryType.none, .faceID, .touchID, .opticID] {
            XCTAssertEqual(
                DeviceOwnerAuthMapping.availability(
                    biometrics: false, biometryType: type, deviceOwner: false, deviceOwnerError: .passcodeNotSet),
                .noDeviceLock, "\(type)")
        }
    }

    /// A passing failure of the check must not turn the lock off; the authentication itself decides.
    func testAnyOtherFailedCheckNamesThePasscodeOrPassword() {
        let codes: [LAError.Code?] = [nil, .biometryLockout, .biometryNotAvailable, .notInteractive, .invalidContext]
        for code in codes {
            XCTAssertEqual(
                DeviceOwnerAuthMapping.availability(
                    biometrics: false, biometryType: .faceID, deviceOwner: false, deviceOwnerError: code),
                .available(ownerFallback), "\(String(describing: code))")
        }
    }

    func testResultsMapToTheFourOutcomes() {
        XCTAssertEqual(DeviceOwnerAuthMapping.result(success: true, error: nil), .success)
        for code in [LAError.Code.userCancel, .systemCancel, .appCancel, .notInteractive, .userFallback] {
            XCTAssertEqual(DeviceOwnerAuthMapping.result(success: false, error: LAError(code)), .cancelled, "\(code)")
        }
        XCTAssertEqual(DeviceOwnerAuthMapping.result(success: false, error: LAError(.passcodeNotSet)), .noDeviceLock)
        for code in [LAError.Code.authenticationFailed, .biometryLockout, .biometryNotAvailable, .invalidContext] {
            XCTAssertEqual(DeviceOwnerAuthMapping.result(success: false, error: LAError(code)), .failed, "\(code)")
        }
        XCTAssertEqual(DeviceOwnerAuthMapping.result(success: false, error: nil), .failed)
        XCTAssertEqual(
            DeviceOwnerAuthMapping.result(success: false, error: CocoaError(.featureUnsupported)), .failed)
    }
}

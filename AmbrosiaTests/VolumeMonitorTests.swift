import Foundation
import XCTest
@testable import Ambrosia

@MainActor
final class VolumeMonitorTests: XCTestCase {

    func testVolumeMonitorStartMonitoring() {
        let monitor = VolumeMonitor.shared
        let session = LibrarySession()
        monitor.startMonitoring(session: session)
        // Calling startMonitoring again should be safe and idempotent
        monitor.startMonitoring(session: session)
    }

    func testLibrarySessionDisconnectMatchingVolume() {
        let session = LibrarySession()
        session.setActivePathForTesting("/Volumes/ExternalUSB/CalibreLibrary")

        let matchingVolume = URL(fileURLWithPath: "/Volumes/ExternalUSB")
        session.handleActiveVolumeDisconnected(volumeURL: matchingVolume)

        XCTAssertTrue(session.isVolumeDisconnected)
        XCTAssertEqual(session.disconnectedVolumeName, "ExternalUSB")
    }

    func testLibrarySessionDisconnectIgnoresUnrelatedVolume() {
        let session = LibrarySession()
        session.setActivePathForTesting("/Volumes/ExternalUSB/CalibreLibrary")

        let unrelatedVolume = URL(fileURLWithPath: "/Volumes/OtherDrive")
        session.handleActiveVolumeDisconnected(volumeURL: unrelatedVolume)

        XCTAssertFalse(session.isVolumeDisconnected)
        XCTAssertNil(session.disconnectedVolumeName)
    }

    func testLibrarySessionNotificationOnDisconnect() {
        let session = LibrarySession()
        session.setActivePathForTesting("/Volumes/BackupDisk/MyLibrary")

        let expectation = expectation(forNotification: .libraryVolumeDidDisconnect, object: nil)
        session.handleActiveVolumeDisconnected(volumeURL: URL(fileURLWithPath: "/Volumes/BackupDisk"))

        wait(for: [expectation], timeout: 1.0)
        XCTAssertTrue(session.isVolumeDisconnected)
    }
}

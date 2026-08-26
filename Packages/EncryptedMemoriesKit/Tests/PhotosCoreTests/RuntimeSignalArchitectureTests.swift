import Foundation
import XCTest

final class RuntimeSignalArchitectureTests: XCTestCase {
    func testDynamicAppleRuntimeObserversHaveOneOwner() throws {
        var packageRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { packageRoot.deleteLastPathComponent() }
        let sourcesRoot = packageRoot.appendingPathComponent("Sources")
        let adapterRelativePath = "LibraryRuntimeAppleAdapter/AppleLibraryRuntimeAdapter.swift"

        let enumerator = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: nil
        )
        var networkOwners: [String] = []
        var thermalOwners: [String] = []
        var powerOwners: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            let relative = String(url.path.dropFirst(sourcesRoot.path.count + 1))
            if source.contains("NWPathMonitor()") { networkOwners.append(relative) }
            if source.contains("forName: ProcessInfo.thermalStateDidChangeNotification") {
                thermalOwners.append(relative)
            }
            if source.contains("forName: .NSProcessInfoPowerStateDidChange") { powerOwners.append(relative) }
        }

        XCTAssertEqual(networkOwners, [adapterRelativePath])
        XCTAssertEqual(thermalOwners, [adapterRelativePath])
        XCTAssertEqual(powerOwners, [adapterRelativePath])
    }
}

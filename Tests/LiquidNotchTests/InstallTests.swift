import XCTest
@testable import LiquidNotch

/// A proper app (11-11): it lives in Applications, and uninstalling takes only its own files.
@MainActor
final class InstallTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    private let downloaded = URL(fileURLWithPath: "/Users/someone/Downloads/Liquid Notch.app", isDirectory: true)

    func testAlreadyInApplicationsStays() {
        for app in ["/Applications/Liquid Notch.app", "/Applications/Utilities/Liquid Notch.app", "/Users/someone/Applications/Liquid Notch.app"] {
            XCTAssertEqual(ApplicationInstaller.plan(bundle: URL(fileURLWithPath: app), original: nil, home: home,
                                                     systemApplicationsWritable: true), .stay, app)
        }
    }

    func testFromDownloadsItMovesToApplications() {
        XCTAssertEqual(ApplicationInstaller.plan(bundle: downloaded, original: nil, home: home, systemApplicationsWritable: true),
                       .move(from: downloaded, to: URL(fileURLWithPath: "/Applications/Liquid Notch.app", isDirectory: true)))
    }

    func testWithoutWriteAccessItGoesToTheUsersOwnApplications() {
        XCTAssertEqual(ApplicationInstaller.plan(bundle: downloaded, original: nil, home: home, systemApplicationsWritable: false),
                       .move(from: downloaded, to: URL(fileURLWithPath: "/Users/someone/Applications/Liquid Notch.app", isDirectory: true)))
    }

    /// macOS runs a downloaded app from a random read-only copy: the real one is what moves.
    func testATranslocatedAppMovesItsRealCopy() {
        let random = URL(fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/1234/d/Liquid Notch.app")
        XCTAssertEqual(ApplicationInstaller.plan(bundle: random, original: downloaded, home: home, systemApplicationsWritable: true),
                       .move(from: downloaded, to: URL(fileURLWithPath: "/Applications/Liquid Notch.app", isDirectory: true)))
        let installed = URL(fileURLWithPath: "/Applications/Liquid Notch.app")
        XCTAssertEqual(ApplicationInstaller.plan(bundle: random, original: installed, home: home, systemApplicationsWritable: true), .stay)
    }

    func testAFolderNamedLikeApplicationsIsntApplications() {
        let lookalike = URL(fileURLWithPath: "/Applications Old/Liquid Notch.app")
        XCTAssertNotEqual(ApplicationInstaller.plan(bundle: lookalike, original: nil, home: home, systemApplicationsWritable: true), .stay)
    }

    /// Uninstalling deletes only files named after the app, inside the user's Library.
    func testUninstallTouchesOnlyTheAppsOwnFiles() {
        let urls = Uninstaller.leftovers(home: home)
        XCTAssertFalse(urls.isEmpty)
        for url in urls {
            XCTAssertTrue(url.path.hasPrefix("/Users/someone/Library/"), url.path)
            XCTAssertTrue(url.lastPathComponent.contains("liquidnotch") || url.lastPathComponent == "Liquid Notch", url.path)
        }
        XCTAssertFalse(urls.contains { $0.path.contains(".claude") || $0.path.contains(".codex") || $0.path.contains("com.apple") })
    }
}

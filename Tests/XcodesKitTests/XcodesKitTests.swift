import XCTest
import Version
import PromiseKit
import PMKFoundation
import Path
import AppleAPI
@testable import XcodesKit

final class XcodesKitTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        PromiseKit.conf.Q.map = nil
        PromiseKit.conf.Q.return = nil
    }

    override func setUp() {
        Current = .mock
    }

    let installer = XcodeInstaller(configuration: Configuration(), xcodeList: XcodeList())

    func test_ParseCertificateInfo_Succeeds() throws {
        let sampleRawInfo = """
        Executable=/Applications/Xcode-10.1.app/Contents/MacOS/Xcode
        Identifier=com.apple.dt.Xcode
        Format=app bundle with Mach-O thin (x86_64)
        CodeDirectory v=20200 size=434 flags=0x2000(library-validation) hashes=6+5 location=embedded
        Signature size=4485
        Authority=Software Signing
        Authority=Apple Code Signing Certification Authority
        Authority=Apple Root CA
        Info.plist entries=39
        TeamIdentifier=59GAB85EFG
        Sealed Resources version=2 rules=13 files=253327
        Internal requirements count=1 size=68
        """
        let info = installer.parseCertificateInfo(sampleRawInfo)

        XCTAssertEqual(info.authority, ["Software Signing", "Apple Code Signing Certification Authority", "Apple Root CA"])
        XCTAssertEqual(info.teamIdentifier, "59GAB85EFG")
        XCTAssertEqual(info.bundleIdentifier, "com.apple.dt.Xcode")
    }

    func test_DownloadOrUseExistingArchive_ReturnsExistingArchive() {
        Current.files.fileExistsAtPath = { _ in return true }
        var xcodeDownloadURL: URL?
        Current.network.downloadTask = { url, _, _ in
            xcodeDownloadURL = url.pmkRequest.url
            return (Progress(), Promise(error: PMKError.invalidCallingConvention))
        }

        let xcode = Xcode(version: Version("0.0.0")!, url: URL(string: "https://apple.com/xcode.xip")!, filename: "mock.xip")
        installer.downloadOrUseExistingArchive(for: xcode, progressChanged: { _ in })
            .tap { result in
                guard case .fulfilled(let value) = result else { XCTFail("downloadOrUseExistingArchive rejected."); return }
                XCTAssertEqual(value, Path.applicationSupport.join("com.robotsandpencils.xcodes").join("Xcode-0.0.0.xip").url)
                XCTAssertNil(xcodeDownloadURL)
            }
            .cauterize()
    }

    func test_DownloadOrUseExistingArchive_DownloadsArchive() {
        Current.files.fileExistsAtPath = { _ in return false }
        var xcodeDownloadURL: URL?
        Current.network.downloadTask = { url, destination, _ in
            xcodeDownloadURL = url.pmkRequest.url
            return (Progress(), Promise.value((destination, HTTPURLResponse(url: url.pmkRequest.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)))
        }

        let xcode = Xcode(version: Version("0.0.0")!, url: URL(string: "https://apple.com/xcode.xip")!, filename: "mock.xip")
        installer.downloadOrUseExistingArchive(for: xcode, progressChanged: { _ in })
            .tap { result in
                guard case .fulfilled(let value) = result else { XCTFail("downloadOrUseExistingArchive rejected."); return }
                XCTAssertEqual(value, Path.applicationSupport.join("com.robotsandpencils.xcodes").join("Xcode-0.0.0.xip").url)
                XCTAssertEqual(xcodeDownloadURL, URL(string: "https://apple.com/xcode.xip")!)
            }
            .cauterize()
    }

    func test_InstallArchivedXcode_SecurityAssessmentFails_Throws() {
        Current.shell.spctlAssess = { _ in return Promise(error: Process.PMKError.execution(process: Process(), standardOutput: nil, standardError: nil)) }

        let xcode = Xcode(version: Version("0.0.0")!, url: URL(fileURLWithPath: "/"), filename: "mock")
        let installedXcode = InstalledXcode(path: Path("/Applications/Xcode-0.0.0.app")!)!
        installer.installArchivedXcode(xcode, at: URL(fileURLWithPath: "/Xcode-0.0.0.xip"))
            .catch { error in XCTAssertEqual(error as! XcodeInstaller.Error, XcodeInstaller.Error.failedSecurityAssessment(xcode: installedXcode, output: "")) }
    }

    func test_InstallArchivedXcode_VerifySigningCertificateFails_Throws() {
        Current.shell.codesignVerify = { _ in return Promise(error: Process.PMKError.execution(process: Process(), standardOutput: nil, standardError: nil)) }

        let xcode = Xcode(version: Version("0.0.0")!, url: URL(fileURLWithPath: "/"), filename: "mock")
        installer.installArchivedXcode(xcode, at: URL(fileURLWithPath: "/Xcode-0.0.0.xip"))
            .catch { error in XCTAssertEqual(error as! XcodeInstaller.Error, XcodeInstaller.Error.codesignVerifyFailed(output: "")) }
    }

    func test_InstallArchivedXcode_VerifySigningCertificateDoesntMatch_Throws() {
        Current.shell.codesignVerify = { _ in return Promise.value((0, "", "")) }

        let xcode = Xcode(version: Version("0.0.0")!, url: URL(fileURLWithPath: "/"), filename: "mock")
        installer.installArchivedXcode(xcode, at: URL(fileURLWithPath: "/Xcode-0.0.0.xip"))
            .catch { error in XCTAssertEqual(error as! XcodeInstaller.Error, XcodeInstaller.Error.unexpectedCodeSigningIdentity(identifier: "", certificateAuthority: [])) }
    }

    func test_InstallArchivedXcode_TrashesXIPWhenFinished() {
        var trashedItemAtURL: URL?
        Current.files.trashItem = { itemURL in
            trashedItemAtURL = itemURL
            return URL(fileURLWithPath: "\(NSHomeDirectory())/.Trash/\(itemURL.lastPathComponent)")
        }

        let xcode = Xcode(version: Version("0.0.0")!, url: URL(fileURLWithPath: "/"), filename: "mock")
        let xipURL = URL(fileURLWithPath: "/Xcode-0.0.0.xip")
        installer.installArchivedXcode(xcode, at: xipURL)
            .ensure { XCTAssertEqual(trashedItemAtURL, xipURL) }
            .cauterize()
    }

    func test_InstallLogging_FullHappyPath() {
        var log = ""
        Current.logging.log = { log.append($0 + "\n") }

        // Don't have a valid session
        Current.network.validateSession = { Promise(error: AppleAPI.Client.Error.invalidSession) }
        // It hasn't been downloaded
        Current.files.fileExistsAtPath = { path in
            if path == (Path.xcodesApplicationSupport/"Xcode-0.0.0.xip").string {
                return false
            }
            else {
                return true
            }
        }
        // It's an available release version
        Current.network.dataTask = { url in
            if url.pmkRequest.url! == URLRequest.downloads.url! {
                let downloads = Downloads(downloads: [Download(name: "Xcode 0.0.0", files: [Download.File(remotePath: "https://apple.com/xcode.xip")])])
                let downloadsData = try! JSONEncoder().encode(downloads)
                return Promise.value((data: downloadsData, response: HTTPURLResponse(url: url.pmkRequest.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
            }

            return Promise.value((data: Data(), response: HTTPURLResponse(url: url.pmkRequest.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        }
        // It downloads and updates progress
        Current.network.downloadTask = { (url, saveLocation, _) -> (Progress, Promise<(saveLocation: URL, response: URLResponse)>) in
            let progress = Progress(totalUnitCount: 100)
            return (progress,
                    Promise { resolver in
                        // Need this to run after the Promise has returned to the caller. This makes the test async, requiring waiting for an expectation.
                        DispatchQueue.main.async {
                            for i in 0...100 {
                                progress.completedUnitCount = Int64(i)
                            }
                            resolver.fulfill((saveLocation: saveLocation,
                                              response: HTTPURLResponse(url: url.pmkRequest.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
                        }
                    })
        }
        // It's a valid .app
        Current.shell.codesignVerify = { _ in
            return Promise.value(
                ProcessOutput(
                    status: 0,
                    out: "",
                    err: """
                        TeamIdentifier=\(XcodeInstaller.XcodeTeamIdentifier)
                        Authority=\(XcodeInstaller.XcodeCertificateAuthority[0])
                        Authority=\(XcodeInstaller.XcodeCertificateAuthority[1])
                        Authority=\(XcodeInstaller.XcodeCertificateAuthority[2])
                        """))
        }
        // Don't have superuser privileges the first time
        var validateSudoAuthenticationCallCount = 0
        Current.shell.validateSudoAuthentication = {
            validateSudoAuthenticationCallCount += 1

            if validateSudoAuthenticationCallCount == 1 {
                return Promise(error: Process.PMKError.execution(process: Process(), standardOutput: nil, standardError: nil))
            }
            else {
                return Promise.value(Shell.processOutputMock)
            }
        }
        // User enters password
        Current.shell.readSecureLine = { prompt in
            Current.logging.log(prompt)
            return "password"
        }
        // User enters something
        Current.shell.readLine = { prompt in
            Current.logging.log(prompt)
            return "asdf"
        }

        let expectation = self.expectation(description: "Finished")

        installer.install("0.0.0", nil)
            .ensure {
                let url = URL(fileURLWithPath: "LogOutput-FullHappyPath.txt", 
                              relativeTo: URL(fileURLWithPath: #file).deletingLastPathComponent())
                XCTAssertEqual(log, try! String(contentsOf: url))
                expectation.fulfill()
            }
            .catch {
                XCTFail($0.localizedDescription)
                expectation.fulfill()
            }

        waitForExpectations(timeout: 1.0)
    }

    func test_UninstallXcode_TrashesXcode() {
        let installedXcode = InstalledXcode(path: Path("/Applications/Xcode-0.0.0.app")!)!
        var trashedItemAtURL: URL?
        Current.files.trashItem = { itemURL in
            trashedItemAtURL = itemURL
            return URL(fileURLWithPath: "\(NSHomeDirectory())/.Trash/\(itemURL.lastPathComponent)")
        }
        Current.files.installedXcodes = { [installedXcode] }

        installer.uninstallXcode("0.0.0")
            .ensure { XCTAssertEqual(trashedItemAtURL, installedXcode.path.url) }
            .cauterize()
    }

    func test_VerifySecurityAssessment_Fails() {
        Current.shell.spctlAssess = { _ in return Promise(error: Process.PMKError.execution(process: Process(), standardOutput: nil, standardError: nil)) }

        let installedXcode = InstalledXcode(path: Path("/Applications/Xcode-0.0.0.app")!)!
        installer.verifySecurityAssessment(of: installedXcode)
            .tap { result in XCTAssertFalse(result.isFulfilled) }
            .cauterize()
    }

    func test_VerifySecurityAssessment_Succeeds() {
        Current.shell.spctlAssess = { _ in return Promise.value((0, "", "")) }

        let installedXcode = InstalledXcode(path: Path("/Applications/Xcode-0.0.0.app")!)!
        installer.verifySecurityAssessment(of: installedXcode)
            .tap { result in XCTAssertTrue(result.isFulfilled) }
            .cauterize()
    }

    func test_MigrateApplicationSupport_NoSupportFiles() {
        Current.files.fileExistsAtPath = { _ in return false }
        var source: URL?
        var destination: URL?
        Current.files.moveItem = { source = $0; destination = $1 } 
        var removedItemAtURL: URL?
        Current.files.removeItem = { removedItemAtURL = $0 } 

        migrateApplicationSupportFiles()

        XCTAssertNil(source)
        XCTAssertNil(destination)
        XCTAssertNil(removedItemAtURL)
    }

    func test_MigrateApplicationSupport_OnlyOldSupportFiles() {
        Current.files.fileExistsAtPath = { return $0.contains("ca.brandonevans") }
        var source: URL?
        var destination: URL?
        Current.files.moveItem = { source = $0; destination = $1 } 
        var removedItemAtURL: URL?
        Current.files.removeItem = { removedItemAtURL = $0 } 

        migrateApplicationSupportFiles()

        XCTAssertEqual(source, Path.applicationSupport.join("ca.brandonevans.xcodes").url)
        XCTAssertEqual(destination, Path.applicationSupport.join("com.robotsandpencils.xcodes").url)
        XCTAssertNil(removedItemAtURL)
    }

    func test_MigrateApplicationSupport_OldAndNewSupportFiles() {
        Current.files.fileExistsAtPath = { _ in return true }
        var source: URL?
        var destination: URL?
        Current.files.moveItem = { source = $0; destination = $1 } 
        var removedItemAtURL: URL?
        Current.files.removeItem = { removedItemAtURL = $0 } 

        migrateApplicationSupportFiles()

        XCTAssertNil(source)
        XCTAssertNil(destination)
        XCTAssertEqual(removedItemAtURL, Path.applicationSupport.join("ca.brandonevans.xcodes").url)
    }

    func test_MigrateApplicationSupport_OnlyNewSupportFiles() {
        Current.files.fileExistsAtPath = { return $0.contains("com.robotsandpencils") }
        var source: URL?
        var destination: URL?
        Current.files.moveItem = { source = $0; destination = $1 } 
        var removedItemAtURL: URL?
        Current.files.removeItem = { removedItemAtURL = $0 } 

        migrateApplicationSupportFiles()

        XCTAssertNil(source)
        XCTAssertNil(destination)
        XCTAssertNil(removedItemAtURL)
    }

    func test_ParsePrereleaseXcodes() {
        let url = URL(fileURLWithPath: "developer.apple.com-download-19-6-9.html", relativeTo: URL(fileURLWithPath: #file).deletingLastPathComponent())
        let data = try! Data(contentsOf: url)

        let xcodes = try! XcodeList().parsePrereleaseXcodes(from: data)

        XCTAssertEqual(xcodes.count, 1)
        XCTAssertEqual(xcodes[0].version, Version("11.0.0-beta+11M336W"))
    }
}

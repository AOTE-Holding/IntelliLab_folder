import Foundation
import Testing
@testable import FolderApp

private final class UpdateStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var statusCode = 200
    private var body = Data()
    private var requestError: Error?

    func configure(statusCode: Int? = nil, body: Data? = nil, requestError: Error?? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let statusCode { self.statusCode = statusCode }
        if let body { self.body = body }
        if let requestError { self.requestError = requestError }
    }

    func response() -> (statusCode: Int, body: Data, requestError: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (statusCode, body, requestError)
    }
}

private final class UpdateStubProtocol: URLProtocol {
    private static let state = UpdateStubState()

    static func configure(statusCode: Int? = nil, body: Data? = nil, requestError: Error?? = nil) {
        state.configure(statusCode: statusCode, body: body, requestError: requestError)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.state.response()
        if let error = response.requestError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let httpResponse = HTTPURLResponse(url: request.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test @MainActor func newerReleaseWithoutZipIsNotReportedAsCurrent() throws {
    let payload = """
    {"tag_name":"v1.2.5","body":"Changes","assets":[
      {"name":"Source.zip","browser_download_url":"https://example.com/source.zip"}
    ]}
    """
    let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(payload.utf8))

    #expect(UpdateService.assess(release, currentVersion: "1.2.4") == .missingAsset(version: "1.2.5"))
    #expect(UpdateService.assess(release, currentVersion: "1.2.5") == .upToDate)
}

@Test @MainActor func newerReleaseWithZipIsInstallable() throws {
    let payload = """
    {"tag_name":"v1.2.5","body":"Changes","assets":[
      {"name":"Folder.app.zip","browser_download_url":"https://example.com/Folder.app.zip"}
    ]}
    """
    let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(payload.utf8))

    #expect(UpdateService.assess(release, currentVersion: "1.2.4") == .installable(
        version: "1.2.5",
        notes: "Changes",
        downloadURL: URL(string: "https://example.com/Folder.app.zip")!
    ))
}

@Test @MainActor func failedManualCheckClearsOldUpdateAndThrottlesBackground() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UpdateStubProtocol.self]
    let session = URLSession(configuration: configuration)
    let suite = "UpdateServiceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel() }
    let service = UpdateService(session: session, defaults: defaults)

    UpdateStubProtocol.configure(statusCode: 200, body: Data("""
    {"tag_name":"v999.0.0","body":"Changes","assets":[
      {"name":"Folder.app.zip","browser_download_url":"https://example.com/Folder.app.zip"}
    ]}
    """.utf8))
    guard case .installable = await service.check(silent: false) else {
        Issue.record("The first response should offer the update")
        return
    }
    #expect(service.updateAvailable)

    UpdateStubProtocol.configure(statusCode: 503)
    guard case .failed = await service.check(silent: false) else {
        Issue.record("The manual HTTP failure must stay a failure")
        return
    }
    #expect(!service.updateAvailable)
    #expect(defaults.object(forKey: "UpdateService.lastCheckDate") as? Date != nil)

    UpdateStubProtocol.configure(statusCode: 200, body: Data("not JSON".utf8))
    guard case .failed = await service.check(silent: false) else {
        Issue.record("Malformed JSON must stay a failure")
        return
    }

    UpdateStubProtocol.configure(requestError: URLError(.notConnectedToInternet))
    defer { UpdateStubProtocol.configure(requestError: nil) }
    guard case .failed = await service.check(silent: false) else {
        Issue.record("Network errors must stay failures")
        return
    }
    #expect(await service.check(silent: true) == .skipped)
}

@Test @MainActor func failedInstallerCopyRestoresOriginalApp() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let target = root.appendingPathComponent("Folder.app")
    let backup = root.appendingPathComponent(".Folder.previous.app")
    let source = root.appendingPathComponent("New.app")
    let bin = root.appendingPathComponent("bin")
    let script = root.appendingPathComponent("install.sh")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let original = target.appendingPathComponent("original.txt")
    try Data("old app".utf8).write(to: original)
    try UpdateService.installerScript.write(to: script, atomically: true, encoding: .utf8)
    let fakeDitto = bin.appendingPathComponent("ditto")
    try "#!/bin/bash\nmkdir -p \"$2\"\necho partial > \"$2/partial.txt\"\nexit 9\n"
        .write(to: fakeDitto, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeDitto.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [script.path, source.path, target.path, backup.path]
    process.environment = ["PATH": "\(bin.path):/usr/bin:/bin"]
    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus != 0)
    #expect(try String(contentsOf: original, encoding: .utf8) == "old app")
    #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("partial.txt").path))
    #expect(!FileManager.default.fileExists(atPath: backup.path))
}

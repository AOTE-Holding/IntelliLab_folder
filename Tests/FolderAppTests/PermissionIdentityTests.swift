import Foundation
import Testing
@testable import FolderApp

@Test func onlyActualAccessDenialsOfferTheRecoveryPermissionFlow() {
    let denied = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
    let missingDrive = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)

    #expect(FileExplorerViewModel.isPermissionDenied(denied))
    #expect(!FileExplorerViewModel.isPermissionDenied(missingDrive))
}

@Test func onboardingCheckpointIsClampedToTheSixStepWalkthrough() {
    #expect(PermissionCenter.normalizedOnboardingStep(-1) == 0)
    #expect(PermissionCenter.normalizedOnboardingStep(4) == 4)
    #expect(PermissionCenter.normalizedOnboardingStep(99) == 5)
}

@Test func fullDiskAccessSkipsTheAdditionalFoldersOnboardingStep() {
    #expect(PermissionCenter.onboardingStepIndices(fullDiskAccessGranted: false) == [0, 1, 2, 3, 4, 5])
    #expect(PermissionCenter.onboardingStepIndices(fullDiskAccessGranted: true) == [0, 1, 3, 4, 5])
}

@Test func permissionStandardFoldersUseTheLoginUsersRealHome() throws {
    let fileManager = FileManager.default
    let expected = try #require(fileManager.homeDirectory(forUser: NSUserName()))

    let actual = PermissionCenter.loginUserHomeDirectory(
        fileManager: fileManager,
        userName: NSUserName()
    )

    #expect(actual.standardizedFileURL == expected.standardizedFileURL)
}

@Test func permissionIdentityAcceptsAlternateURLForTheSameDirectory() throws {
    let root = try temporaryPermissionDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("Desktop", isDirectory: true)
    let alias = root.appendingPathComponent("Desktop Alias", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

    #expect(PermissionCenter.urlsReferToSameDirectory(alias, target, fileManager: .default))
}

@Test func permissionIdentityRejectsDifferentDirectoriesWithTheSameName() throws {
    let root = try temporaryPermissionDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let firstParent = root.appendingPathComponent("First", isDirectory: true)
    let secondParent = root.appendingPathComponent("Second", isDirectory: true)
    try FileManager.default.createDirectory(at: firstParent, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondParent, withIntermediateDirectories: true)
    let first = firstParent.appendingPathComponent("Desktop", isDirectory: true)
    let second = secondParent.appendingPathComponent("Desktop", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)

    #expect(!PermissionCenter.urlsReferToSameDirectory(first, second, fileManager: .default))
}

private func temporaryPermissionDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("FolderPermissionTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

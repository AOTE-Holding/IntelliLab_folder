import Foundation
import Testing
@testable import FolderApp

@Test func firstNavigationEnablesBack() {
    let home = URL(fileURLWithPath: "/home")
    let documents = URL(fileURLWithPath: "/home/Documents")
    var history = NavigationHistory(initialURL: home)
    history.navigate(to: documents)

    #expect(history.canGoBack)
    #expect(!history.canGoForward)
    #expect(history.goBack() == home)
}

@Test func navigationAfterBackTruncatesForwardEntries() {
    var history = NavigationHistory(initialURL: URL(fileURLWithPath: "/a"))
    history.navigate(to: URL(fileURLWithPath: "/b"))
    history.navigate(to: URL(fileURLWithPath: "/c"))
    _ = history.goBack()
    history.navigate(to: URL(fileURLWithPath: "/d"))

    #expect(history.entries == [
        URL(fileURLWithPath: "/a"),
        URL(fileURLWithPath: "/b"),
        URL(fileURLWithPath: "/d")
    ])
    #expect(!history.canGoForward)
}

@Test func duplicateCurrentLocationDoesNotCreateEntry() {
    let location = URL(fileURLWithPath: "/a")
    var history = NavigationHistory(initialURL: location)
    history.navigate(to: location)
    #expect(history.entries == [location])
}

@Test func ejectingVolumeFindsLastLocationOutsideThatVolume() {
    let desktop = URL(fileURLWithPath: "/Users/test/Desktop")
    let volume = URL(fileURLWithPath: "/Volumes/External", isDirectory: true)
    var history = NavigationHistory(initialURL: desktop)
    history.navigate(to: volume)
    history.navigate(to: volume.appendingPathComponent("Projects", isDirectory: true))

    #expect(history.lastLocationOutsideVolume(volume) == desktop)
}

# Folder App — Review, Done Work & Roadmap

This is the authoritative implementation checklist. `FIXES.md` is retained as a legacy snapshot.

Last verified: 2026-08-24

## Done

### P0 — Security & Trust

- [x] Added one background-isolated `FileOperationService` for copy, move, trash, rename, duplicate, compression and safe rotation.
- [x] Replaced child-process compression with pinned ZIPFoundation 0.9.20; multi-item archives are written to a hidden temporary file, validated and moved into place only when complete.
- [x] Added shared previews and conflict choices: Replace, Keep Both, Skip and Cancel.
- [x] Added progress, cancellation and a final per-item success/failure/skipped report.
- [x] Replaced silent replace behavior with preserve-and-rollback behavior.
- [x] Made Undo/Redo partial-failure aware; successful and failed pairs remain in the correct stacks.
- [x] Fixed Pasteboard ownership: Folder Cut followed by Finder Copy always pastes as Copy.
- [x] Routed Grid, List, Search, shortcuts, context menus and Drag-to-Trash through the shared coordinator.
- [x] Made drop behavior volume-aware: same volume moves; cross-volume copies; Option forces copy.
- [x] Standardized Trash confirmation and Undo history across all entry points.
- [x] Limited rotation to JPEG, PNG, HEIC/HEIF and TIFF encoders.
- [x] Rotation copies encoded pixels losslessly and changes only the composed EXIF orientation; TIFF/EXIF/GPS/XMP-compatible metadata, gain maps, image count, ACLs, extended attributes, permissions and timestamps are preserved and recursively validated before a named sibling copy appears. Originals are never overwritten.
- [x] Removed GIF/BMP/WebP rotation offers.
- [x] Removed the unsigned ZIP self-updater and all self-delete, shell-copy and quarantine-clearing code.
- [x] Integrated pinned Sparkle 2.9.4 with EdDSA appcast configuration.
- [x] Added release gates for Developer ID identity, Team ID, final Bundle ID, feed URL and Sparkle public key.
- [x] Added hardened signing verification, notarization, stapling and Gatekeeper assessment to CI.
- [x] Re-signs every nested Sparkle helper inside-out; local ad-hoc builds use a development-only library-validation entitlement while release entitlements remain strict.
- [x] Reworked manual installation to stage, verify, back up and roll back instead of deleting the working app first.
- [x] Enabled App Sandbox, user-selected read/write bookmarks, network client and Apple Events entitlements.
- [x] Added six-step first-launch permission onboarding and a persistent Permissions Center; the optional Full Disk Access card lives beside the standard-folder choices rather than as a mandatory-looking separate step.
- [x] Gated browser construction behind onboarding, so the walkthrough is the only clean-install window and no standard-folder TCC prompt can appear before its explanation.
- [x] Persists the current six-step onboarding checkpoint across Quit/relaunch and clears it only after completion or an explicit permission reset.
- [x] Persists an explicit Full Disk Access confirmation because sandboxed apps cannot query that System Settings toggle through a public API; both onboarding and Permissions Center expose confirm/revoke actions.
- [x] Requests Terminal/iTerm Automation by stable bundle identifier, persists the requested state and displays Allowed/Retry feedback.
- [x] Fixed standard-folder and re-authorization pickers to open at the parent and preselect the requested root instead of forcing users to select an impossible current directory; standard roots come from the login user's real home rather than the sandbox container.
- [x] Validates standard-folder selections by filesystem identity (including APFS aliases/symlinks) instead of brittle path-string equality, while still rejecting a different same-named directory.
- [x] Security-scoped bookmarks are persisted, stale bookmarks are rejected, descendant paths resolve through the nearest authorized root, and every read/mutation/Undo operation holds its scope for its full duration.
- [x] Permission and bookmark failures are visible in the UI.
- [x] Limited selectable terminal presets to Terminal, iTerm and Warp; legacy unsupported settings migrate to Terminal.
- [x] Tracks and requests Terminal and iTerm Automation independently; Warp is explicitly identified as URL-scheme based.
- [x] Explains in onboarding and Settings that Full Disk Access does not bypass the App Sandbox or replace a selected bookmark root.

### P1 — Reliability & Performance

- [x] Replaced navigation history with a conventional current-entry/index model and unit tests.
- [x] Moved directory reads, recursive search, folder sizing and file mutations off the MainActor.
- [x] Added cancellation and generation guards so stale navigation/search results cannot overwrite current state.
- [x] File-watcher refreshes are silent, preserve stable item identities, publish only real directory changes and reuse the existing watcher, eliminating repeated Skeleton flashes on active folders.
- [x] Recursive search retains every encountered access error (up to its bounded collection limit) and exposes the complete list from an in-context warning instead of hiding inaccessible locations.
- [x] Made recursive folder sizes opt-in instead of calculating every visible folder.
- [x] Added reusable operation result UI with per-item reasons and “Show in Finder”.
- [x] Quick Look zooms from the exact visible icon/thumbnail frame, returns the same rendered transition image plus content rect, tracks scroll/window geometry, and cleanly fades when the source is clipped or invisible.
- [x] Mouse-wheel and trackpad scrolling inside Quick Look advances/reverses through the current file list with gesture thresholds, momentum throttling and bounded first/last-item behavior.
- [x] Quick Look arrow navigation is single-step and synchronized with the browser selection: Left/Right move one item, Up/Down move one grid row (or one list item), and the event is never processed twice.
- [x] A native AppKit Quick Look Preview Extension renders Folder's private folder payload as a Finder-style list with its folder heading and native folder/file icons; preview generations cannot delete newer session data, and no HTML/WebView or `public.folder` override is used.
- [x] Folder Quick Look performs no directory enumeration on the main actor or before the panel becomes visible; the selected folder and later folder previews hydrate on demand with cancellation and stale-generation protection.
- [x] Startup and navigation no longer synchronously probe volumes, permission bookmarks, Full Disk Access, Google Drive or destination existence on the main actor; slow and disconnected locations resolve on utility workers.
- [x] Quick Look acquires its data source and delegate through the native window-controller responder chain, eliminating repeated “panel has no controller” work during first presentation; passive Terminal/iTerm status probes also run off the main actor.
- [x] Grid, list, search and tag-result clicks use native mouse-down selection with no double-click timeout; the second mouse-up opens exactly once, and folder-preview list double-clicks navigate to child folders or open child files.
- [x] Replaced NSImage concurrency crossings with Sendable CGImage payloads.
- [x] Passed full strict-concurrency compilation with warnings treated as errors.

### P2 — Product & Technical Foundation

- [x] Added independent per-window tabs; each tab owns path, history, selection, search and view state.
- [x] Added tab creation/switch/close, `Cmd+T`, `Cmd+W`, plus button and “Open in New Tab”.
- [x] Added tab drag-reorder and an overflow menu for large tab sets.
- [x] Added clickable breadcrumbs and a distinct path-edit mode.
- [x] Added Loading, Error, Empty and Data states for folder/search surfaces.
- [x] Wired default view mode, live icon size, hidden-file refresh and native `SMAppService` Launch at Login.
- [x] Enforced at least one modifier for global hotkeys.
- [x] Stored and removed the local event-monitor token correctly.
- [x] Added a SwiftPM test target and tests for history, Pasteboard cut/copy provenance, file-operation conflicts, multi-item archives, permission identity and tab-manager lifecycle/reorder behavior.
- [x] Removed the missing SwiftPM resource-directory reference.
- [x] Added a strict build/test gate before release packaging.
- [x] Development builds do not start Sparkle with placeholder feed/key values, preventing misleading background updater failure alerts.

## Remaining

### P0 release and permission gates

- [ ] Supply the final production Bundle ID and add an explicit one-time migration map for settings stored under the legacy production identifier.
- [ ] Supply real Developer ID, Team ID, notarization credentials, Sparkle EdDSA keypair and HTTPS appcast URL in repository secrets; publish the first signed/notarized release.
- [ ] Verify Sparkle InstallerLauncher/XPC behavior in a signed sandboxed production bundle and test rollback on an intentionally broken update.

### P1 follow-ups

- [ ] Add Retry to the reusable result report using a persisted operation request.
- [ ] Add byte-level progress for large copies, moves and archives; current progress is per item.
- [ ] Add automated Quick Look transition tests for scroll, resize and selection changes.

### P2 product work

- [ ] Add tab UI tests and active-tab URL-scheme routing tests (unit coverage now verifies creation, inheritance, closing and reorder).
- [ ] Implement Finder-like grouping (Name, Date, Kind, Size, Tags), Option-key Sort→Group behavior and per-tab grouping persistence.
- [ ] Replace the custom Grid/List gesture selection surfaces with native selectable AppKit collection/table controls, preserving complete VoiceOver semantics.
- [ ] Move all menu commands to a shared responder-chain command layer.
- [ ] Add aligned interactive list headers, compact Grid sort/group menu and item/selection/free-space status bar.
- [ ] Audit every control’s VoiceOver role, label, hint, focus order, high contrast and reduced-motion behavior.
- [ ] Add UI tests for onboarding, destructive confirmations, tabs, shortcuts, selection and Quick Look.
- [ ] Add injected adapters for FileManager, Pasteboard, Workspace, Updater and Clock; expand unit coverage for Undo/Redo, bookmarks and filenames.
- [ ] Commit a production Xcode project or workspace that consumes the Swift package and defines app/UI-test schemes.
- [ ] Reconcile README, changelog, shortcut guides and screenshots with the shipped sandbox/tab/updater behavior.

## Verification Record

- `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`: 23 tests passed, including Quick Look folder/scroll/arrow navigation, lossless rotation/metadata, watcher identity, onboarding-checkpoint, multi-item archive, sandbox-home/permission-identity and tab-manager lifecycle validation.
- `swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`: passed with Sparkle 2.9.4 and ZIPFoundation 0.9.20.
- `./build.sh` and `codesign --verify --deep --strict`: development app bundle passed; Sparkle resolves through `@executable_path/../Frameworks` and ZIPFoundation is linked in-process.
- `git diff --check`, Plist validation, shell syntax checks and Swift package manifest parsing: passed.
- Real signing, notarization, appcast publication and sandboxed update installation require the release credentials listed above.

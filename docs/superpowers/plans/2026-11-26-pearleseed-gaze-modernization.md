# Pearleseed Gaze Modernization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform the forked Gaze repository into an independent, high-performance, Swift 6 multi-module macOS application under `com.pearleseed.Gaze` (`https://github.com/pearleseed/Gaze`) with GitHub Releases self-updating, modernized dependencies, and Swift Testing (`swift test`).

**Architecture:** Reorganize the codebase into a root `Package.swift` with 9 strictly acyclic local library targets (`GazeCore`, `GazeDesign`, `GazeTourKit`, `GazeCamera`, `GazeRecognition`, `GazeLockScreen`, `GazeSecurity`, `GazeUpdates`, `GazeApp`) compiled under Swift 6 strict concurrency using `package` access control, linked into `Gaze.xcodeproj` (`Gaze.app` + `GazeFinder.appex` + `LiquidGlass.metal` + Core ML models + `pam_gaze.so` + AppIntents) and unified `build.sh`. Headless suites migrate to 6 Swift Testing targets under `swift test`, while desktop-session/visual/release checks live under `Tests/Scripts/`.

**Tech Stack:** Swift 6.4+ (`swift-tools-version: 6.0`, `.swiftLanguageMode(.v6)`), macOS 26.0+ SDK, SwiftUI, AppKit, AVFoundation, Vision, Core ML, Accelerate (`vDSP`), Metal, Swift Testing (`Testing`), Xcode 26+/27+, Python 3.15 (`dmgbuild==2.0.0`, `Pillow==13.0.0`).

**Spec:** `docs/superpowers/specs/2026-11-26-pearleseed-gaze-modernization-design.md`

## Global Constraints

- Bundle identifier is `com.pearleseed.Gaze`; Finder extension is `com.pearleseed.Gaze.Finder`; App Group is `group.com.pearleseed.Gaze`; Keychain service and `os.Logger` subsystem are `com.pearleseed.Gaze`; distributed notifications use `com.pearleseed.Gaze.status.` and `com.pearleseed.Gaze.state`.
- Canonical repository is `https://github.com/pearleseed/Gaze`; zero active references to `OwenCope`, `gazeunlock.com`, `com.gazeunlock.*`, or upstream Discord remain outside historical attribution in `NOTICE.md` and `docs/licensing/`.
- Minimum platform is macOS 26.0 (`MACOSX_DEPLOYMENT_TARGET = 26.0`, `LSMinimumSystemVersion = 26.0`, `Package.swift` `.macOS("26.0")`); every Swift target compiles with Swift 6 strict concurrency (`SWIFT_VERSION = 6`, `.swiftLanguageMode(.v6)`) and zero warnings.
- Zero external SwiftPM network dependencies; `GazeTourKit` stays vendored locally preserving its explicit resting Liquid Glass navigation buttons (`.glassEffect(.regular.interactive(), in: .circle)` in `GlassEffectContainer`) and `pageMedia` hook per `ThirdParty/TourKit/LOCAL-CHANGES.md`, shipping `TourKit-LICENSE.txt` in bundle resources.
- Legacy `Plugin/`, `UnlockService.swift`, `Sources/Browser/` (`GazeBrowser` + `.browserOnly`), and duplicate `Tools/Release/BuildDMG.sh` are removed completely; active sudo PAM (`Sources/PAM/pam_gaze.c` + `SudoApproval` + `SudoInstallScript`) is preserved.
- Preserve all biometric and security invariants: matching thresholds, 500 ms max frame age, 240 ms continuity gap, 4 s sustained walk-away absence, fail-closed anti-spoof, camera pinning, `LockScreenPasswordSubmission` verification guards, and mandatory HTTPS + SHA-256 verification on in-app updates.
- Canonical DMG packager is `Tools/Release/DMG/package.py` producing per-arch `Gaze-<version>-<build>-<arch>.dmg` + `.sha256` sidecars, supporting un-notarized local/ad-hoc releases by default while keeping optional `--notary-profile` / `GAZE_REQUIRE_DEVELOPER_ID=1` enforcement; Homebrew cask uses `on_arm`/`on_intel` with `postflight_steps` clearing `com.apple.quarantine`.
- Preserve the 108 uncommitted baseline refactoring changes from the working tree as the starting baseline on an isolated branch/worktree; never discard them and never push to a remote without explicit user instruction.

## Review Focus

- **Fresh fork HTTP 404 or missing SHA-256 on GitHub Release:** `ReleaseUpdateChecker` must treat HTTP 404 from `api.github.com/repos/pearleseed/Gaze/releases/latest` as `.upToDate` (no error banner) and refuse in-app install (degrading to browser download only) whenever neither `asset.digest` nor `<dmg>.sha256` provides a valid 64-hex SHA-256. *(Pinned in Task 5 tests.)*
- **Frame overwrite under MainActor stall:** When the 1-slot camera mailbox drops an unconsumed frame under main-thread pressure, it must flag a continuity break before delivering the next frame so `CameraEvidenceContinuity` never treats non-contiguous frames as uninterrupted proof. *(Pinned in Task 7 tests.)*
- **Delete All racing an in-flight JPEG encode:** Calling `UnlockAttemptLog.deleteAll()` while a background JPEG write for a prior attempt is still encoding must discard the late file/snapshot so deleted attempts never reappear on disk or leave orphan `.jpg` files. *(Pinned in Task 10 tests.)*
- **Legacy `"authPlugin"` in persisted `UserDefaults`:** After removing `Plugin/` and `.authPlugin`, reading `"authPlugin"` from `UserDefaults` must decode safely to `.none` without crashing or starting a removed service. *(Pinned in Task 1 tests.)*
- **Ad-hoc vs. Team-signed update verification:** `UpdateInstaller.verify(app:expectedVersion:)` must enforce team-matched `SecCodeCopyDesignatedRequirement` when the running app has a Team ID (rejecting other teams/unsigned apps), while allowing version upgrades between ad-hoc signed `com.pearleseed.Gaze` builds (whose `cdhash` changes every build) backed by strict nested signature validation + mandatory HTTPS + SHA-256. *(Pinned in Task 5 tests.)*

---

## File Structure Overview

```
Package.swift                                # Root Swift 6 manifest (9 library targets + 6 test targets)
Sources/
  GazeCore/                                  # AppIdentity, Preferences, Vault/Keychain, AppLockStore/StateMachine, Broadcast, Diagnostics
  GazeDesign/                                # Theme, Typography, Controls, Glass, FaceMark, Companion Metal renderer
  GazeTourKit/                               # Vendored TourKit.swift (Liquid Glass controls preserved)
  GazeCamera/                                # CameraDevice, FacePose, Lease, Continuity, Quality, Brightness, Preview, CameraController
  GazeRecognition/                           # ModelResidency, Aligner, Embedder, Matcher, EnrollmentStore, Spoof, Iris, Liveness/*, Evaluator
  GazeLockScreen/                            # Notch/*, Light, Space, LookTarget, NativeUnlock, WallpaperGlass, AppLockShield, Preview/Shoot
  GazeSecurity/                              # LockWatcher/*, PresenceWatcher, Lockout, InputGuard, AttemptLog, Backend, Keystrokes, AdminPrompt, Sudo, AppLockWatcher/Recognizer
  GazeUpdates/                               # ReleaseURLPolicy, ReleaseUpdateChecker, UpdateInstaller, RepoRevealHelper
  GazeApp/                                   # GazeApp views/services, AppDelegate, AppServices, MenuBarContent, DesktopWallpaper, Settings/*, Enrollment/*, Setup/*, AppIntents
  GazeEntry/                                 # Minimal @main entry point + LiquidGlass.metal resource hook for Gaze.app
  FinderExtension/                           # GazeFinder.appex (links GazeCore)
  PAM/                                       # pam_gaze.c -> pam_gaze.so
Tests/
  GazeCoreTests/                             # Swift Testing
  GazeCameraTests/                           # Swift Testing
  GazeRecognitionTests/                      # Swift Testing
  GazeSecurityTests/                         # Swift Testing
  GazeUpdatesTests/                          # Swift Testing
  GazeUITests/                               # Swift Testing (fast headless logic/geometry/invariants)
  Scripts/
    AppIntegration/                          # Desktop-session / .app-bundle / Metal cadence / PNG capture scripts
    Release/                                 # Signing, DMG package.py, source-archive, space checks
    MultiFace/                               # Opt-in fixture download suite
  run.sh                                     # Runs `swift test` + local non-network scripts
```

---

### Task 1: Remove Legacy Subsystems (`Plugin/`, `UnlockService`, `GazeBrowser`, `BuildDMG.sh`) & Update Git Remote

**Files:**
- Delete: `Plugin/` (entire directory), `Sources/Security/UnlockService.swift`, `Sources/Browser/` (4 files), `Tools/Release/BuildDMG.sh`
- Modify: `Sources/Security/UnlockExecutionPolicy.swift`, `Sources/Security/UnlockBackend.swift`, `Sources/App/Preferences.swift`, `Sources/App/AppServices.swift`, `Sources/App/MenuBarContent.swift`, `Sources/Security/AdminPromptApproval.swift`, `Tests/PresenceLifecycle/LifecycleTests.swift`, `Tests/PresenceLifecycle/test-wiring.sh`, `Tests/LockScreenSecurity/SubmissionTests.swift`

**Interfaces:**
- Consumes: Existing working tree baseline (preserved on isolated branch/worktree during setup).
- Produces:
  - `UnlockExecutionPolicy` cases: `.normal`, `.uiReview`, `.scanOnly` (no `.browserOnly`), with `func permitsAdminPromptApproval(passwordReplayEnabled: Bool) -> Bool`.
  - `UnlockBackendKind` cases: `.none`, `.keystroke` (no `.authPlugin`; legacy `"authPlugin"` in `UserDefaults` falls back safely to `.none`).
  - `git remote origin` set to `https://github.com/pearleseed/Gaze.git`.

- [ ] **Step 1: Add regression assertions for legacy `"authPlugin"` fallback and `.browserOnly` removal**
  In `Tests/PresenceLifecycle/LifecycleTests.swift`, add a check verifying `UnlockExecutionPolicy(arguments: ["--browser-only"]) == .normal` (no `.browserOnly` case) and `UnlockBackendKind(rawValue: "authPlugin") == nil` with `Preferences` defaulting unknown backend strings safely to `.none`. Update `Tests/PresenceLifecycle/test-wiring.sh` and `Tests/LockScreenSecurity/SubmissionTests.swift` to remove `.browserOnly`, `browserApprovals`, and `unlockService` references.

- [ ] **Step 2: Run affected suites to confirm failing state before cleanup**
  Run: `Tests/run.sh PresenceLifecycle LockScreenSecurity`
  Expected: FAIL because `UnlockExecutionPolicy.browserOnly` / `UnlockBackendKind.authPlugin` still exist.

- [ ] **Step 3: Point `origin` remote to `pearleseed/Gaze` and delete legacy files**
  Run `git remote set-url origin https://github.com/pearleseed/Gaze.git` (verify with `git remote -v`).
  Remove `Plugin/`, `Sources/Security/UnlockService.swift`, `Sources/Browser/`, and `Tools/Release/BuildDMG.sh`.

- [ ] **Step 4: Clean `UnlockExecutionPolicy`, `UnlockBackend`, `Preferences`, `AppServices`, `MenuBarContent`, `AdminPromptApproval`, and any Settings views referencing `.authPlugin`**
  - In `Sources/Security/UnlockExecutionPolicy.swift`: delete `.browserOnly` and `--browser-only`; rename `permitsBrowserApproval(passwordReplayEnabled:)` to `permitsAdminPromptApproval(passwordReplayEnabled:)` returning `self == .scanOnly || self == .normal`.
  - In `Sources/Security/UnlockBackend.swift`: remove `.authPlugin`, `AuthPluginUnlockBackend`, `UnlockError.pluginNotBuilt`, and `AuthorizationRules` if unused; verify `UnlockBackendKind.selectableCases == [.none, .keystroke]`.
  - In `Sources/App/Preferences.swift`: ensure `unlockBackend` getter/init safely defaults any unrecognized raw value (including `"authPlugin"`) to `.none`.
  - In `Sources/App/AppServices.swift`: remove `browserApprovals`, `unlockService`, `.browserOnly` notice branch, and `.authPlugin` switch case.
  - In `Sources/App/MenuBarContent.swift`: remove `.browserOnly` and `.authPlugin` switch cases.
  - In `Sources/Security/AdminPromptApproval.swift`: call `permitsAdminPromptApproval(passwordReplayEnabled:)`.
  - Check `Sources/App/Settings/` with `grep -rn "authPlugin\|AuthPlugin\|browserOnly\|GazeBrowser\|UnlockService" Sources/` and remove any dead UI/recovery rows referencing `.authPlugin`.

- [ ] **Step 5: Run tests and local build check**
  Run: `Tests/run.sh PresenceLifecycle LockScreenSecurity AppReadiness ProductBoundary`
  Expected: 4/4 suites passed.

- [ ] **Step 6: Commit**
  ```bash
  git add -A
  git commit -m "refactor: remove legacy Plugin, UnlockService, GazeBrowser, and BuildDMG"
  ```

---

### Task 2: Complete Rebrand to `com.pearleseed.Gaze` & `AppIdentity` Single Source of Truth

**Files:**
- Create: `Sources/App/AppIdentity.swift`
- Modify: All files referencing `com.gazeunlock`, `OwenCope`, `gazeunlock.com`, or upstream Discord across `Sources/`, `Resources/Info.plist`, `Sources/FinderExtension/{Info.plist,GazeFinder.entitlements}`, `Xcode/{Gaze,GazeFinder}.xcconfig`, `build.sh`, `Tools/Release/{preflight.sh,verify.sh,DMG/package.py,Homebrew/gaze.rb}`, `Tools/Scripts/install-local.sh`, `Integrations/DynamicLake/`, `README.md`, `Tests/`

**Interfaces:**
- Produces:
  ```swift
  enum AppIdentity {
      static let bundleIdentifier = "com.pearleseed.Gaze"
      static let finderExtensionIdentifier = "com.pearleseed.Gaze.Finder"
      static let appGroupIdentifier = "group.com.pearleseed.Gaze"
      static let keychainService = "com.pearleseed.Gaze"
      static let loggerSubsystem = "com.pearleseed.Gaze"
      static let statusNotificationPrefix = "com.pearleseed.Gaze.status."
      static let stateNotificationName = "com.pearleseed.Gaze.state"
      static let pendingSettingsPaneKey = "com.pearleseed.Gaze.pendingSettingsPane"
      static let urlScheme = "gaze"
      static let repositorySlug = "pearleseed/Gaze"
      static let repositoryURL = URL(string: "https://github.com/pearleseed/Gaze")!
      static let releasesURL = URL(string: "https://github.com/pearleseed/Gaze/releases")!
      static let issuesURL = URL(string: "https://github.com/pearleseed/Gaze/issues")!
  }
  ```

- [ ] **Step 1: Update identity assertions in `Tests/StatusBroadcast/StatusBroadcastTests.swift`, `Tests/AppLock/Tests.swift`, `Tests/SudoInstall/SudoInstallScriptTests.swift`, and `Tests/Release/verify-artifact.sh`**
  Update expected prefix/bundle/app-group strings to `com.pearleseed.Gaze`, `group.com.pearleseed.Gaze`, `com.pearleseed.Gaze.status.`, and `com.pearleseed.Gaze.Finder`.

- [ ] **Step 2: Run suites to verify they fail before rebrand**
  Run: `Tests/run.sh StatusBroadcast AppLock`
  Expected: FAIL on old `com.gazeunlock.Gaze` constants.

- [ ] **Step 3: Create `Sources/App/AppIdentity.swift` and rebrand all Swift, plist, xcconfig, shell, Python, DynamicLake, and documentation files**
  - Replace every `"com.gazeunlock.Gaze"` in `Sources/` with `AppIdentity.*` constants (for standalone single-file test suites that compile without `AppIdentity.swift` prior to Task 3 SPM migration, include `AppIdentity.swift` in their `run.sh` source list).
  - Update `Resources/Info.plist`, `Sources/FinderExtension/Info.plist`, `Sources/FinderExtension/GazeFinder.entitlements`, `Xcode/Gaze.xcconfig`, `Xcode/GazeFinder.xcconfig`, `build.sh`, `Tools/Release/{preflight.sh,verify.sh,DMG/package.py,Homebrew/gaze.rb}`, `Tools/Scripts/install-local.sh`.
  - Update `Sources/App/Settings/SettingsAboutPane.swift`: Website → `github.com/pearleseed/Gaze` (`AppIdentity.repositoryURL`), Release notes → `AppIdentity.releasesURL`, Report a problem → `AppIdentity.issuesURL`; remove Discord link and `donationURL` section.
  - In `Sources/App/ReleaseURLPolicy.swift`, update `/OwenCope/Gaze/releases/download/` → `/pearleseed/Gaze/releases/download/` immediately so no `OwenCope` strings remain (Task 5 completes the full GitHub Releases API rewrite).
  - Update `Integrations/DynamicLake/Resources/plugin.json`, `Integrations/DynamicLake/Sources/main.swift`, and `Integrations/DynamicLake/Tests/simulate-gaze.swift`.
  - Update `README.md` with `pearleseed/Gaze` URLs, Homebrew cask instructions, Gatekeeper first-launch note for un-notarized builds, and remove broken links to deleted `.github`/upstream files.

- [ ] **Step 4: Verify zero stale upstream references and run tests**
  Run:
  ```bash
  ! grep -rn -i "com\.gazeunlock\|owencope\|discord\.gg/BFgKT5YJH" Sources/ Resources/ Xcode/ Tools/ Integrations/ README.md build.sh
  Tests/run.sh StatusBroadcast AppLock SudoInstall SettingsSearch
  ```
  Expected: grep returns zero matches; 4/4 suites passed.

- [ ] **Step 5: Commit**
  ```bash
  git add -A
  git commit -m "chore: rebrand completely to com.pearleseed.Gaze and pearleseed/Gaze"
  ```

---

### Task 3: Multi-Module Swift Package Workspace (`Package.swift`) & Swift 6 Strict Concurrency

**Files:**
- Create: `Package.swift`, `Sources/GazeEntry/GazeEntryApp.swift` (minimal `@main` wrapper calling `GazeApp`), `Sources/GazeCore/...`, `Sources/GazeDesign/...`, `Sources/GazeTourKit/...`, `Sources/GazeCamera/...`, `Sources/GazeRecognition/...`, `Sources/GazeLockScreen/...`, `Sources/GazeSecurity/...`, `Sources/GazeUpdates/...`, `Sources/GazeApp/...`
- Move (with `git mv`): all Swift files from `Sources/{App,Camera,Companion,Design,Enrollment,LockScreen,Recognition,Security,Setup}` and `ThirdParty/TourKit/TourKit.swift` into the 9 acyclic targets defined in Spec §5.2.
- Modify: Cross-module declarations to `package`, decouple `AppLockShield.attach` from `AppLockWatcher` via closure (`func attach(toShieldTrigger:)`) so `GazeLockScreen` does not import `GazeSecurity`, migrate `MenuBarVisibility` from `ObservableObject` to `@Observable`, convert non-recursive `NSLock` + `@unchecked Sendable` state in `ModelSlot`, `IrisLocator`, and `CoreMLEmbedder` to `Synchronization.Mutex` where safe, remove `typealias UpdateChecker = RepoRevealHelper`.

**Interfaces:**
- Consumes: `AppIdentity` from Task 2; cleaned codebase from Task 1.
- Produces:
  - Root `Package.swift` (`swift-tools-version: 6.0`, `platforms: [.macOS("26.0")]`) exporting library products `GazeCore`, `GazeDesign`, `GazeTourKit`, `GazeCamera`, `GazeRecognition`, `GazeLockScreen`, `GazeSecurity`, `GazeUpdates`, `GazeApp`, every target using `.swiftLanguageMode(.v6)`.
  - Strictly acyclic DAG:
    - `GazeCore` -> `[]`
    - `GazeTourKit` -> `[]`
    - `GazeDesign` -> `["GazeCore"]`
    - `GazeCamera` -> `["GazeCore"]`
    - `GazeRecognition` -> `["GazeCore", "GazeCamera"]`
    - `GazeLockScreen` -> `["GazeCore", "GazeDesign", "GazeRecognition"]`
    - `GazeSecurity` -> `["GazeCore", "GazeCamera", "GazeRecognition", "GazeLockScreen"]`
    - `GazeUpdates` -> `["GazeCore"]`
    - `GazeApp` -> all 8 targets above
  - Note: Keep `LiquidGlass.metal` under `Sources/GazeEntry/LiquidGlass.metal` (or `Resources/Shaders/LiquidGlass.metal`) so the Xcode app target and `build.sh` compile it directly into `Contents/Resources/default.metallib` (keeping `Package.swift` free of unused `.metal` warnings).

- [ ] **Step 1: Move files via `git mv` into the 9 SPM target folders and write `Package.swift`**
  Follow the exact target-to-file mapping in Spec §5.2, keeping `GazeCore` strictly free of upward dependencies:
  - `Sources/GazeCore/`: `AppIdentity.swift`, `Preferences.swift`, `DetectionDistance.swift` (extracted from `FrameQuality.swift`), `UnlockBackendKind.swift` (extracted from `UnlockBackend.swift`), `UnlockExecutionPolicy.swift`, `AutofillSecurity.swift`, `Keychain.swift`, `SecureVault.swift`, `PasswordVault.swift`, `BiometricGate.swift`, `AppLockStore.swift`, `AppLockStateMachine.swift`, `StatusBroadcast.swift`, `StateBroadcast.swift`, `StartupTiming.swift`, `ProductCaptureDemo.swift` (`enum ProductCaptureDemo` only; its `SettingsView`/`GazeBrand` extensions stay in `GazeApp`).
  - `Sources/GazeDesign/`: `Theme.swift`, `Typography.swift`, `GazeGlassPanel.swift`, `SettingsControls.swift`, `SettingsSection.swift`, `WindowAppearance.swift`, `GazeFaceMark.swift`, `GazeCompanionMotion.swift`, `GazeCompanionRenderer.swift`, `GazeCompanionShader.swift`, `GazeCompanionView.swift`, `GazeCuriosityMotion.swift`, `GazeRenderDiagnostics.swift`.
  - `Sources/GazeTourKit/`: `TourKit.swift` (keep `ThirdParty/TourKit/{LICENSE,SOURCE.json,LOCAL-CHANGES.md}` intact).
  - `Sources/GazeCamera/`: `CameraDevice.swift`, `FacePose.swift`, `CameraFrameLease.swift`, `CameraEvidenceContinuity.swift`, `CameraSessionGate.swift`, `ForegroundCameraClaim.swift`, `FrameQuality.swift`, `FrameBrightness.swift`, `CameraPreview.swift`, `CameraController.swift`.
  - `Sources/GazeRecognition/`: `ModelResidency.swift`, `FaceAligner.swift`, `FaceEmbedder.swift`, `AdjustedThresholdEmbedder.swift`, `FaceTemplateMatcher.swift`, `FaceEnrollment.swift`, `SpoofDetector.swift`, `AntiSpoofGate.swift`, `DeviceBezelGate.swift`, `GlareCue.swift`, `IrisLocator.swift`, `PupilLocator.swift`, `LivenessChallenge.swift`, `RecognitionFrameGate.swift`, `RecognitionScanPacing.swift`, `UnlockFrameEvaluator.swift`, `EnrollmentModel.swift`, `DatasetCapture.swift`.
  - `Sources/GazeLockScreen/`: `NotchMetrics.swift`, `NotchPanelShape.swift`, `NotchAppearance.swift`, `NotchCapsuleModel.swift`, `NotchCapsule.swift`, `NotchCapsuleController.swift`, `NotchPreviewCanvas.swift`, `LockScreenSpace.swift`, `LockScreenLight.swift`, `LookTargetOverlay.swift`, `NativeMovementMark.swift`, `NativeUnlockAnimation.swift`, `WallpaperBrightness.swift`, `WallpaperGlass.swift`, `AppLockShield.swift`, `LockPanelPreview.swift`, `LockScreenShoot.swift`.
  - `Sources/GazeSecurity/`: `LockWatcher.swift`, `PresenceWatcher.swift`, `PresenceAbsenceGate.swift`, `PresenceCheckSchedule.swift`, `LockoutManager.swift`, `LockScanDiagnostics.swift`, `LockScreenInputGuard.swift`, `LockScreenPasswordSubmission.swift`, `UnlockChallengeGate.swift`, `UnlockAttemptLog.swift`, `UnlockBackend.swift`, `Keystrokes.swift`, `ScreenLock.swift`, `SpaceKeyMonitor.swift`, `TamperGuard.swift`, `IntruderNotice.swift`, `StalePasswordNotice.swift`, `LoginItem.swift`, `FaceApprovalCheck.swift`, `AdminPromptApproval.swift`, `AdminPromptRules.swift`, `SudoApproval.swift`, `SudoInstallScript.swift`, `AppLockWatcher.swift`, `AppLockRecognizer.swift`, `AppLockURLAction.swift`.
  - `Sources/GazeUpdates/`: `ReleaseURLPolicy.swift`, `ReleaseUpdateChecker.swift`, `UpdateInstaller.swift`, `RepoRevealHelper.swift` (renamed from `UpdateChecker.swift`, dropping `typealias UpdateChecker`).
  - `Sources/GazeApp/`: `GazeApp.swift`, `AppDelegate.swift`, `AppServices.swift`, `AppActivation.swift`, `MenuBarContent.swift`, `DesktopWallpaper.swift`, `GazeBrand.swift`, `GazeDiagnostics.swift`, `GazeTips.swift`, `ProductCaptureDemoExtensions.swift`, `ConfirmIdentityIntent.swift`, `ReleaseNotesView.swift`, `DatasetCaptureView.swift`, `Enrollment/{EnrollmentRing,EnrollmentWindow,RecognitionTestPanel,RecognitionTestView}.swift`, `Settings/*.swift`, `Setup/*.swift`.
  - `Sources/GazeEntry/`: `GazeEntry.swift` (`@main` delegating to `GazeApp`) + `LiquidGlass.metal` (excluded from SPM target, compiled by Xcode/build.sh).
  - Verify `GazeApp.swift` exposes `package struct GazeApp: App` (without `@main` inside the library target, while `GazeEntry.swift` holds `@main` for the app executable).

- [ ] **Step 2: Add `import` statements, `package` visibility, decouple `AppLockShield`, migrate `MenuBarVisibility`, and fix all Swift 6 concurrency errors**
  - Add `package` visibility to cross-module types/methods/properties and explicit `import GazeCore` / `import GazeDesign` / etc.
  - Replace `AppLockShield.attach(to watcher: AppLockWatcher)` with an extension in `GazeSecurity` (`extension AppLockWatcher { package func attach(shield: AppLockShield) }`) so `GazeLockScreen` has zero dependency on `GazeSecurity`.
  - Convert `MenuBarVisibility` to `@Observable @MainActor final class MenuBarVisibility` (keeping equality guard in `isVisible` setter to prevent SwiftUI scene-rebuild recursion!) and update `GazeApp` to `@State private var menuBarVisibility = MenuBarVisibility.shared` + `$menuBarVisibility.isVisible` via `@Bindable` or explicit `Binding`.
  - Adopt `import Synchronization` `Mutex` in `ModelSlot`, `IrisLocator`, and `CoreMLEmbedder` prediction lock (keeping `Sendable` soundness under Swift 6 strict concurrency).
  - Audit `Sources/GazeTourKit/TourKit.swift` for Swift 6 cleanliness while keeping every custom resting Liquid Glass control untouched.

- [ ] **Step 3: Build all 9 targets under Swift 6 with warnings-as-errors**
  Run: `swift build -Xswiftc -warnings-as-errors`
  Expected: `Build complete!` with 0 errors and 0 warnings.

- [ ] **Step 4: Commit**
  ```bash
  git add -A
  git commit -m "refactor: adopt multi-module Package.swift architecture and Swift 6 concurrency"
  ```

---

### Task 4: Wire `Gaze.xcodeproj`, Unify `build.sh` & Optimize Incremental Build Speed

**Files:**
- Modify: `Gaze.xcodeproj/project.pbxproj`, `Xcode/Shared.xcconfig`, `build.sh`, `Tools/Scripts/xcode-bundle-resources.sh`, `Tools/Scripts/BundleResources.sh`, `Tools/Scripts/build_and_run.sh`, `Tools/Scripts/source-archive.sh`, `Tests/ProductBoundary/run.sh`
- Delete: `Tools/Scripts/MainAppSources.sh` (retired once `build.sh` builds from the unified package/Xcode project)

**Interfaces:**
- Consumes: Root `Package.swift` library products from Task 3.
- Produces:
  - `Xcode/Shared.xcconfig` with `SWIFT_VERSION = 6`.
  - `Gaze.xcodeproj` linking local Swift package products (`GazeApp` + transitive libs into `Gaze.app`, `GazeCore` into `GazeFinder.appex`), compiling `Sources/GazeEntry/GazeEntry.swift`, `Sources/GazeEntry/LiquidGlass.metal`, `AppIcon.icon`, Core ML models, `pam_gaze.so`, and `AppIntents` metadata.
  - `build.sh` defaulting local builds to `GAZE_ARCHS="$(uname -m)"` while keeping `DIST=1 GAZE_ARCHS=arm64|x86_64`, atomic `$TMPDIR` staging, iCloud `xattr` signing retries, and un-notarized release signing support (strict Developer ID enforced when `GAZE_REQUIRE_DEVELOPER_ID=1`).
  - `Tools/Scripts/xcode-bundle-resources.sh` skipping Core ML model staging when input fingerprint matches cached `.models.stamp`.

- [ ] **Step 1: Update `Xcode/Shared.xcconfig` and `Gaze.xcodeproj/project.pbxproj`**
  - Set `SWIFT_VERSION = 6` in `Xcode/Shared.xcconfig`.
  - Update `Gaze.xcodeproj/project.pbxproj` to add a local Swift package reference (`XCLocalSwiftPackageReference` at `.`), link `GazeApp` (and `GazeCore` for `GazeFinder.appex`) via `XCSwiftPackageProductDependency`, include `Sources/GazeEntry/GazeEntry.swift` and `Sources/GazeEntry/LiquidGlass.metal` in `Gaze`, and remove obsolete direct source folder groups that now compile via SwiftPM.
  - Verify `ConfirmIdentityIntent` (`AppIntents`) metadata is still emitted by Xcode when linked through `GazeApp` (if `appintentsmetadataprocessor` requires the intent type in the main app target, place `ConfirmIdentityIntent.swift` directly in `Sources/GazeEntry/` and verify `Metadata.appintents` exists inside the built `.app`!).

- [ ] **Step 2: Add incremental fingerprint caching to `Tools/Scripts/xcode-bundle-resources.sh`**
  Compute a deterministic stamp over `Resources/{FaceEmbedding,IrisLandmarks,Spoof}*`, `local_models`, and `ThirdParty/TourKit/LICENSE` (file paths, sizes, mtimes) stored at `$resources/.models.stamp`; when stamp matches and expected outputs exist, exit 0 immediately without copying/recompiling models. When a model is added, changed, or deleted, rebuild cleanly.

- [ ] **Step 3: Unify `build.sh` around `xcodebuild` (or SwiftPM + bundle assembly) and default local builds to host arch**
  - Change default `GAZE_ARCHS` from `arm64 x86_64` to `$(uname -m)` for local builds; retain `DIST=1 GAZE_ARCHS=arm64` or `x86_64`.
  - Build `Gaze.app` cleanly via `xcodebuild` (with `CONFIGURATION=Release`, `ARCHS`, `SDKROOT`, `CODE_SIGNING_ALLOWED=NO` into `$STAGE_ROOT`, then copy/stage and apply `gaze_codesign` with `$IDENTITY` and existing reference-requirement checks) so there is ONE build graph shared between Xcode and CLI!
  - Support un-notarized `DIST=1` builds (`1B`) using Apple Development or ad-hoc `-` when `GAZE_REQUIRE_DEVELOPER_ID` is not `1`, while enforcing Developer ID + `--timestamp` whenever `GAZE_REQUIRE_DEVELOPER_ID=1`.
  - Delete `Tools/Scripts/MainAppSources.sh` and update `Tools/Scripts/source-archive.sh` and `Tests/ProductBoundary/run.sh` accordingly.

- [ ] **Step 4: Verify both `xcodebuild` and `./build.sh` produce complete signed bundles**
  Run:
  ```bash
  xcodebuild -project Gaze.xcodeproj -scheme Gaze -configuration Release -arch arm64 CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/gaze-xcode-check build
  ./build.sh
  test -f build/Gaze.app/Contents/Resources/default.metallib
  test -f build/Gaze.app/Contents/Resources/pam_gaze.so
  test -f build/Gaze.app/Contents/Resources/TourKit-LICENSE.txt
  test -d build/Gaze.app/Contents/PlugIns/GazeFinder.appex
  test -d build/Gaze.app/Contents/Resources/FaceEmbedding.mlmodelc
  test -d build/Gaze.app/Contents/Resources/Spoof.mlmodelc
  test -d build/Gaze.app/Contents/Resources/Metadata.appintents
  codesign --verify --deep --strict build/Gaze.app
  ```
  Expected: All build commands and artifact assertions succeed.

- [ ] **Step 5: Commit**
  ```bash
  git add -A
  git commit -m "build: unify Gaze.xcodeproj and build.sh on root Swift package with Swift 6"
  ```

---

### Task 5: GitHub Releases Updater (`GazeUpdates`), Un-Notarized Release Packaging (`1B`) & Python Dependency Upgrades

**Files:**
- Modify: `Sources/GazeUpdates/ReleaseURLPolicy.swift`, `Sources/GazeUpdates/ReleaseUpdateChecker.swift`, `Sources/GazeUpdates/UpdateInstaller.swift`, `Sources/GazeApp/Settings/SettingsUpdatesSection.swift`, `Tools/Release/Signing.sh`, `Tools/Release/verify.sh`, `Tools/Release/DMG/package.py`, `Tools/Release/Homebrew/gaze.rb`, `Tools/Release/DMG/requirements.txt`
- Create: `Tests/GazeUpdatesTests/ReleaseUpdatesTests.swift` (registered in `Package.swift`)

**Interfaces:**
- Consumes: `AppIdentity` (`GazeCore`), unified `Package.swift`.
- Produces:
  - `ReleaseURLPolicy.feed == URL(string: "https://api.github.com/repos/pearleseed/Gaze/releases/latest")!`
  - `ReleaseURLPolicy.releases == URL(string: "https://github.com/pearleseed/Gaze/releases")!`
  - `ReleaseURLPolicy.isTrustedFeed(_ url: URL) -> Bool`
  - `ReleaseURLPolicy.isTrustedDownload(_ url: URL) -> Bool`
  - `ReleaseURLPolicy.isTrustedDownloadHop(_ url: URL) -> Bool`
  - `ReleaseUpdateChecker` decoding GitHub Releases JSON (`tag_name`, `name`, `body`, `prerelease`, `draft`, `assets`) with arch-matched DMG selection (`hostArchitecture: String` injectable for testing) and SHA-256 extraction from `asset.digest` (`"sha256:<hex>"`) or `<dmg>.sha256` sidecar asset (max 4 KiB).
  - `UpdateInstaller.verify(app:expectedVersion:runningCodeRequirementPolicy:)` enforcing Team-matched `SecCodeCopyDesignatedRequirement` when running app has a Team ID, or strict nested signature validity + `com.pearleseed.Gaze` + version match for ad-hoc signed releases.
  - `Tools/Release/DMG/requirements.txt`: `dmgbuild==2.0.0`, `Pillow==13.0.0`.

- [ ] **Step 1: Add `GazeUpdatesTests` target to `Package.swift` and write failing Swift Testing tests**
  In `Tests/GazeUpdatesTests/ReleaseUpdatesTests.swift`, write `@Test` cases covering:
  - `ReleaseURLPolicy` accepts `api.github.com/repos/pearleseed/Gaze/releases/latest`, `github.com/pearleseed/Gaze/releases/download/v1.0.0/Gaze-1.0.0-1-arm64.dmg`, `release-assets.githubusercontent.com/...`, `objects.githubusercontent.com/...`; rejects `gazeunlock.com`, `github.com/OwenCope/Gaze/...`, `/blob/`, HTTP, credentials, ports, fragments.
  - GitHub Release JSON with `arm64` + `x86_64` DMG assets picks matching arch and extracts `digest: "sha256:<64hex>"`.
  - GitHub Release JSON without `digest` fetches matching `.sha256` sidecar asset (<= 4 KiB) and parses `<64hex>  <filename>`.
  - GitHub Release JSON without `digest` and without `.sha256` yields `downloadSHA256 == nil` (browser download only; `UpdateInstaller` refuses install).
  - HTTP 404 from `api.github.com` transitions to `.upToDate` (never `.failed`).
  - `draft: true` and `prerelease: true` transition to `.upToDate`.
  - Stopping schedule mid-flight restores previous state without false offline error.
  - `UpdateInstaller` verifies valid Team-signed vs ad-hoc signed policy and rejects mismatched bundle ID, mismatched version, or bad SHA-256.

- [ ] **Step 2: Run `swift test --filter GazeUpdatesTests` to verify failing state**
  Run: `swift test --filter GazeUpdatesTests`
  Expected: FAIL (compile error / assertion failures against old `gazeunlock.com` policy).

- [ ] **Step 3: Implement GitHub Releases updater & `UpdateInstaller` verification policy**
  - Rewrite `ReleaseURLPolicy.swift` for `pearleseed/Gaze` GitHub API + GitHub Release asset download trust.
  - Rewrite `ReleaseUpdateChecker.swift` feed decoding, headers (`Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`, `User-Agent`), HTTP 404 → `.upToDate`, arch selection, `digest`/`.sha256` extraction, and `"GitHub"` user-facing messages.
  - Update `UpdateInstaller.swift` (`verify`, `writeSwapScript` removing `com.pearleseed.Gaze.agent`, download redirect policy using `isTrustedDownloadHop`).
  - Update `SettingsUpdatesSection.swift` (`"Check GitHub for a new build."`, `"Checking GitHub…"`).

- [ ] **Step 4: Update release scripts, Homebrew cask & Python requirements (`1B`)**
  - Update `Tools/Release/Signing.sh` to permit Apple Development or `-` (ad-hoc) for un-notarized release mode when `GAZE_REQUIRE_DEVELOPER_ID` != `1`, while retaining strict Developer ID enforcement when `GAZE_REQUIRE_DEVELOPER_ID=1`.
  - Update `Tools/Release/verify.sh` for `com.pearleseed.Gaze`, making Developer ID/timestamp/stapler/spctl checks conditional on `GAZE_REQUIRE_DEVELOPER_ID=1` while always verifying bundle structure, arch, Info.plist, required models, entitlements safety, and strict `codesign --verify --deep --strict`.
  - Update `Tools/Release/DMG/package.py` to make `--notary-profile` optional (running notarization/stapling/spctl when provided, emitting signed or ad-hoc verified DMG + `.sha256` + `.json` receipt when omitted) and validate `CFBundleIdentifier == "com.pearleseed.Gaze"`.
  - Update `Tools/Release/Homebrew/gaze.rb` with `on_arm`/`on_intel` URLs under `https://github.com/pearleseed/Gaze/releases/download/v#{version}/...`, `homepage "https://github.com/pearleseed/Gaze"`, `postflight_steps` quarantine removal, and `com.pearleseed.Gaze` uninstall/zap entries.
  - Upgrade `Tools/Release/DMG/requirements.txt` to `dmgbuild==2.0.0` and `Pillow==13.0.0`.

- [ ] **Step 5: Run `GazeUpdatesTests` and Python/Release checks**
  Run:
  ```bash
  swift test --filter GazeUpdatesTests
  python3 -m py_compile Tools/Release/DMG/package.py Tools/Release/DMG/artwork.py
  ```
  Expected: All `GazeUpdatesTests` pass; Python scripts compile cleanly.

- [ ] **Step 6: Commit**
  ```bash
  git add -A
  git commit -m "feat: switch updater and DMG release pipeline to pearleseed/Gaze GitHub Releases"
  ```

---

### Task 6: Monolith Decomposition (`LockWatcher`, `NotchCapsule`, `LivenessChallenge`)

**Files:**
- Split `Sources/GazeSecurity/LockWatcher.swift` → `Sources/GazeSecurity/LockWatcher/{LockWatcher,LockUnlockAttemptRunner,LockWatcherRetryMonitor,LockWatcherTelemetry}.swift`
- Split `Sources/GazeLockScreen/NotchCapsule.swift` → `Sources/GazeLockScreen/Notch/{NotchCapsule,NotchIslandView,NotchEarFlankView,NotchDynamicIslandView}.swift`
- Split `Sources/GazeRecognition/LivenessChallenge.swift` → `Sources/GazeRecognition/Liveness/{LivenessChallenge,LivenessPoseEvaluator,LivenessLookEvaluator,LivenessLandmarkMath}.swift`

**Interfaces:**
- Consumes: Existing public/`package` APIs of `LockWatcher`, `NotchCapsule`, and `LivenessChallenge`.
- Produces: Identical external API signatures with pure structural decomposition (no file over ~500 lines in these three subsystems).

- [ ] **Step 1: Split `LivenessChallenge.swift` into 4 cohesive files**
  Separate core state machine & enums (`LivenessChallenge.swift`), yaw/pitch/blink/mouth evaluation (`LivenessPoseEvaluator.swift`), Follow-the-light gaze evaluation & pass scoring (`LivenessLookEvaluator.swift`), and landmark geometry math (`LivenessLandmarkMath.swift`).

- [ ] **Step 2: Split `NotchCapsule.swift` into 4 cohesive files**
  Separate root router (`NotchCapsule.swift`), attached/floating island view (`NotchIslandView.swift`), ear-flank view & metrics (`NotchEarFlankView.swift`), and Dynamic Island morph/metrics/body (`NotchDynamicIslandView.swift`).

- [ ] **Step 3: Split `LockWatcher.swift` into 4 cohesive files**
  Separate lifecycle/event notifications (`LockWatcher.swift`), single unlock attempt runner (`LockUnlockAttemptRunner.swift`), Space/pointer retry & watchdog (`LockWatcherRetryMonitor.swift`), and attempt timing/telemetry/recording (`LockWatcherTelemetry.swift`).

- [ ] **Step 4: Build & verify zero warnings and file-size bounds**
  Run:
  ```bash
  swift build -Xswiftc -warnings-as-errors
  swift test
  wc -l Sources/GazeSecurity/LockWatcher/*.swift Sources/GazeLockScreen/Notch/*.swift Sources/GazeRecognition/Liveness/*.swift
  ```
  Expected: `Build complete!` with 0 warnings; all tests pass; every split file is cleanly scoped and well under ~550 lines.

- [ ] **Step 5: Commit**
  ```bash
  git add -A
  git commit -m "refactor: decompose LockWatcher, NotchCapsule, and LivenessChallenge monoliths"
  ```

---

### Task 7: Camera Performance — Walk-Away `rectanglesOnly` Mode & Bounded 1-Slot Backpressure

**Files:**
- Modify: `Sources/GazeCamera/CameraController.swift`, `Sources/GazeSecurity/PresenceWatcher.swift`
- Create: `Tests/GazeCameraTests/CameraBackpressureTests.swift` (registered in `Package.swift`)

**Interfaces:**
- Produces in `GazeCamera`:
  - `package enum CameraAnalysisMode: Sendable, Equatable { case full, presenceOnly }`
  - `package struct PresenceObservation: Sendable, Equatable { package enum Verdict: Sendable, Equatable { case facePresent, noFace, indeterminate }; package let verdict: Verdict; package let frameID: UInt64; package let capturedAt: ContinuousClock.Instant }`
  - `CameraController.init(accessScope:allowsBystanders:analysisMode:)` (defaulting `analysisMode: .full`) and `package var onPresenceObserved: (@MainActor (PresenceObservation) -> Void)?`.
  - `package struct LatestFrameMailbox<Element: Sendable>` (internal/package `Mutex`-guarded 1-slot buffer with `enqueue(_:) -> Bool` and `take() -> (element: Element, droppedBefore: Int)?`, testable directly in `GazeCameraTests`).

- [ ] **Step 1: Add `GazeCameraTests` target to `Package.swift` and write failing Swift Testing tests**
  In `Tests/GazeCameraTests/CameraBackpressureTests.swift`, write `@Test` cases:
  - `LatestFrameMailbox` stores at most 1 pending item: pushing 5 frames before draining retains only the latest and reports `droppedBefore == 4`.
  - When `droppedBefore > 0`, `CameraEvidenceContinuity` records a break (invalidating uninterrupted proof) before accepting the newer frame.
  - `SampleProxy.presenceVerdict(detectedCount:detectionSucceeded:)` returns `.facePresent` for 1 or >1 faces, `.noFace` for 0 faces, `.indeterminate` on detection error, and invokes **0** landmark/quality requests in `.presenceOnly` mode.

- [ ] **Step 2: Run `swift test --filter GazeCameraTests` to verify failing state**
  Run: `swift test --filter GazeCameraTests`
  Expected: FAIL (types not yet implemented).

- [ ] **Step 3: Implement `CameraAnalysisMode.presenceOnly`, `LatestFrameMailbox`, and `PresenceWatcher` integration**
  - In `Sources/GazeCamera/CameraController.swift`:
    - Add `CameraAnalysisMode`, `PresenceObservation`, and `LatestFrameMailbox` (using `Synchronization.Mutex`).
    - In `SampleProxy.captureOutput`, when `analysisMode == .presenceOnly`, run ONLY `rectanglesRequest` (skip `landmarksRequest`, `qualityRequest`, and `FaceSample`/`CVPixelBuffer` capture), emit `PresenceObservation.Verdict` via lightweight callback.
    - In `CameraController.start`, deliver frames through `LatestFrameMailbox` with a single scheduled `MainActor` drain task at a time (at most 1 pending buffer in memory); when `droppedBefore > 0`, call `evidenceContinuity.invalidate()` (or record unusable break) before publishing the newest frame!
  - In `Sources/GazeSecurity/PresenceWatcher.swift`:
    - Construct `CameraController(accessScope: .foreground, allowsBystanders: true, analysisMode: .presenceOnly)`.
    - Wire `onPresenceObserved` to update `PresenceAbsenceGate` and immediately resume/cancel sleep (via an `AsyncStream`/signal or immediate task wake) when `.facePresent` arrives so the camera shuts down without waiting out the 800 ms sleep interval, while preserving 4 s sustained absence, 500 ms max frame age, and 1 s gap validation.

- [ ] **Step 4: Run `GazeCameraTests` and `swift build`**
  Run: `swift test --filter GazeCameraTests && swift build -Xswiftc -warnings-as-errors`
  Expected: All tests pass, zero warnings.

- [ ] **Step 5: Commit**
  ```bash
  git add -A
  git commit -m "perf(camera): add rectangles-only presence mode and 1-slot camera backpressure"
  ```

---

### Task 8: Recognition & Core ML Performance — Deduplicated Warm-Up, Accelerate Vectorization, Direct Tensor Pointer & Shared Spoof Crop

**Files:**
- Modify: `Sources/GazeRecognition/ModelResidency.swift`, `Sources/GazeRecognition/FaceEmbedder.swift`, `Sources/GazeRecognition/SpoofDetector.swift`, `Sources/GazeRecognition/AntiSpoofGate.swift`, `Sources/GazeRecognition/UnlockFrameEvaluator.swift`, `Sources/GazeRecognition/FaceEnrollment.swift`, `Sources/GazeApp/Enrollment/RecognitionTestView.swift`
- Create: `Tests/GazeRecognitionTests/RecognitionPerformanceTests.swift` (registered in `Package.swift`)

**Interfaces:**
- Produces in `GazeRecognition`:
  - `ModelSlot.warmUpOnce(_ body: (Model) -> Bool)` — runs `body` at most once per residency load cycle; concurrent callers coalesce onto the same load/warm-up; failed runs (`false`) remain retryable; `unloadIfIdle` resets warm-up state.
  - `SpoofDetector.spoofConfidence(preRenderedCrop: CVPixelBuffer) -> Float?` (reusing a pre-rendered 224×224 BGRA context crop when `!isDetector`, keeping existing `spoofConfidence(_ sample:)` delegating to it).
  - `AntiSpoofGate.evaluate(_ sample: FaceSample, contextCrop: CVPixelBuffer?) -> (decision: Decision, confidence: Float?)`.
  - `UnlockFrameEvaluator.Result` gains `package var spoofConfidence: Float? = nil` and `package var didRunSpoofClassifier: Bool = false`.

- [ ] **Step 1: Add `GazeRecognitionTests` target to `Package.swift` and write failing Swift Testing tests**
  In `Tests/GazeRecognitionTests/RecognitionPerformanceTests.swift`, write `@Test` cases:
  - `ModelSlot.warmUpOnce`: 10 concurrent callers execute warm-up body exactly **1** time; after `unloadIfIdle(for: 0)`, next call executes warm-up again (total 2); a returning-`false` failure allows the next caller to retry.
  - `Faceprint.similarity(to:)` (Accelerate `vDSP`) matches naive scalar cosine formula within `1e-5` across normal, zero, non-finite, mismatched-source, and mismatched-length vectors.
  - Direct `MLMultiArray` extraction helper produces identical `[Float]` values to subscript indexing for contiguous `.float32` and `.float16` arrays and falls back safely for non-contiguous strides.
  - Shared context crop in `UnlockFrameEvaluator`: matching frame invokes the context-crop builder **1** time (shared by classifier + bezel + glare) and populates `result.didRunSpoofClassifier` and `result.spoofConfidence`.

- [ ] **Step 2: Run `swift test --filter GazeRecognitionTests` to verify failing state**
  Run: `swift test --filter GazeRecognitionTests`
  Expected: FAIL (missing `warmUpOnce`, shared crop API, etc.).

- [ ] **Step 3: Implement warm-up dedup, async-safe initial model loading, Accelerate cosine, direct tensor read, and shared spoof crop**
  - In `ModelResidency.swift`: add `warmUpOnce(_ work: (Model) -> Bool)` guarded by `loadLock` + `warmed` flag reset in `unloadIfIdle`. Update `CoreMLEmbedder.warmUp()`, `SpoofDetector.warmUp()`, and `IrisLocator.warmUp()` to use `warmUpOnce`.
  - In `FaceEmbedder.swift`:
    - Defer eager `MLModel(contentsOf:)` out of synchronous `CoreMLEmbedder.init()` by checking bundle URL presence synchronously and reading validated metadata/loading lazily off `MainActor` (or validating once on first off-main load with deterministic readiness wait on scan/enrollment) while preserving `Embedders.best().identifier` for `UnlockGuard` & `FaceEnrollmentStore.usable(_:)` (using cached model spec `side = 112` validated against model description on load, failing closed if schema mismatches!).
    - Vectorize `Faceprint.similarity(to:)` using `vDSP_dotpr` and `vDSP_svesq`.
    - Add `CoreMLEmbedder.extractFloats(from: MLMultiArray) -> [Float]` reading contiguous `.float32` / `.float16` `dataPointer` directly with safe fallback for strided layouts.
  - In `SpoofDetector.swift`, `AntiSpoofGate.swift`, `UnlockFrameEvaluator.swift`, and `RecognitionTestView.swift`:
    - Render `FaceAligner.contextCrop(sample, side: 224)` once inside `UnlockFrameEvaluator.denyChecked(_:)` (when classifier side == 224 and `!isDetector`) and pass the shared crop to `AntiSpoofGate` / `SpoofDetector`, `DeviceBezelGate`, and `GlareCue`.
    - Populate `spoofConfidence` & `didRunSpoofClassifier` on `UnlockFrameEvaluator.Result`; in `RecognitionTestWorker.evaluate(_:)`, reuse `results[chosen].spoofConfidence` when `results[chosen].didRunSpoofClassifier` is `true`, only calling `spoof?.spoofConfidence` directly when the evaluator did not run it (e.g., non-matched face).

- [ ] **Step 4: Run `GazeRecognitionTests` and `swift build`**
  Run: `swift test --filter GazeRecognitionTests && swift build -Xswiftc -warnings-as-errors`
  Expected: All tests pass, zero warnings.

- [ ] **Step 5: Commit**
  ```bash
  git add -A
  git commit -m "perf(recognition): deduplicate model warmup, vectorize similarity, and share spoof crops"
  ```

---

### Task 9: Idle Efficiency & UI Readiness — Zero-Wakeup Timers & Coalesced Readiness

**Files:**
- Modify: `Sources/GazeSecurity/AdminPromptApproval.swift`, `Sources/GazeCore/Preferences.swift`, `Sources/GazeApp/DesktopWallpaper.swift`, `Sources/GazeApp/MenuBarContent.swift`, `Sources/GazeApp/Settings/SettingsView.swift`, `Sources/GazeApp/Settings/NotchSettings.swift`
- Create: `Tests/GazeCoreTests/IdleEfficiencyTests.swift` (registered in `Package.swift`)

**Interfaces:**
- Produces:
  - `AdminPromptApproval.isPollingActive: Bool` (package-visible for testing) and `syncTimerState()` triggered automatically whenever `Preferences.shared.approveAdminPrompts` or `isPaused` changes.
  - `DesktopWallpaper.WallpaperVisibilityToken` (RAII token; `DesktopWallpaper.shared.acquirePollingToken()` starts the 2 s fallback poll while count > 0 and stops it immediately when count reaches 0, refreshing immediately on acquire).
  - `MenuBarStatusModel.evaluate(...) -> MenuBarStatusSnapshot` returning `(title: String, opensSettings: Bool)` in a single `backend.readiness()` call.

- [ ] **Step 1: Add `GazeCoreTests` target to `Package.swift` and write failing Swift Testing tests**
  In `Tests/GazeCoreTests/IdleEfficiencyTests.swift`, write `@Test` cases:
  - `MenuBarStatusModel.evaluate` calls the injected readiness closure **exactly once** to produce both `title` and `opensSettings` across ready, needsSetup, unavailable, paused, lockedOut, and unenrolled states.
  - `DesktopWallpaper` poll token counter: 0 tokens → `isFallbackPollingActive == false`; acquire token → `true`; release token → `false`; nested 2 tokens → stays `true` until both released.
  - `AdminPromptApproval`: `isPollingActive == false` when `approveAdminPrompts == false` or `isPaused == true`; flips to `true` immediately when enabled and unpaused.

- [ ] **Step 2: Run `swift test --filter GazeCoreTests` to verify failing state**
  Run: `swift test --filter GazeCoreTests`
  Expected: FAIL (new APIs not yet implemented).

- [ ] **Step 3: Implement zero-wakeup timer lifecycles and coalesced readiness**
  - In `AdminPromptApproval.swift`: only create/run the 0.5 s `Timer` while `enabled == true`; observe preference changes (notification or callback from `Preferences.approveAdminPrompts` / `pausedUntil` `didSet`) to call `syncTimerState()` immediately.
  - In `DesktopWallpaper.swift`: move the 2 s polling `Task` behind an active-token counter (`acquirePollingToken() -> AnyObject`); attach tokens in wallpaper-consuming preview views via `.onAppear`/`.onDisappear` (or `.task`), keeping `FSEventStream` + `activeSpaceDidChange` + `didBecomeActive` event-driven.
  - In `MenuBarContent.swift`: compute `MenuBarStatusSnapshot` once per body render instead of invoking `backend.readiness()` in both `menuStatus` and `menuStatusOpensSettings`.
  - In `SettingsView.swift`: guard `refreshExternalState()` with a tiny debounce/timestamp coalesce (e.g., skip duplicate refresh within 150 ms of an identical trigger) so `onAppear` immediately followed by `didBecomeActive` doesn't query Keychain/AX twice back-to-back.

- [ ] **Step 4: Run `GazeCoreTests` and `swift build`**
  Run: `swift test --filter GazeCoreTests && swift build -Xswiftc -warnings-as-errors`
  Expected: All tests pass, zero warnings.

- [ ] **Step 5: Commit**
  ```bash
  git add -A
  git commit -m "perf(idle): eliminate idle polling wakeups and coalesce UI readiness checks"
  ```

---

### Task 10: I/O, Memory & Graphics Efficiency — Serialized `UnlockAttemptLog`, Shared `CIContext`, Glow Cache & Metal Redraws

**Files:**
- Modify: `Sources/GazeSecurity/UnlockAttemptLog.swift`, `Sources/GazeApp/Settings/UnlockAttemptsSection.swift`, `Sources/GazeLockScreen/LockScreenLight.swift`, `Sources/GazeDesign/GazeCompanionRenderer.swift`
- Create: `Tests/GazeSecurityTests/UnlockAttemptLogTests.swift`, `Tests/GazeUITests/RenderCacheTests.swift` (registered in `Package.swift`)

**Interfaces:**
- Produces:
  - `UnlockAttemptLog` backed by serial `UnlockAttemptStorageActor` with monotonic `generation: UInt64` and injectable `directoryURL` for isolated unit testing, plus `func flushForTesting() async` and async off-MainActor thumbnail loading (`func loadPhotoIfNeeded(for:)`).
  - `LockScreenLight.GlowCacheKey: Hashable` (`width`, `height`, `scale`, `notchRect`) with reusable static `CIContext` and bounded cache lookup.
  - `GazeCompanionRenderer.PausedRenderState: Equatable` (`revision`, `angle`, `material`, `opacity`) preventing redundant paused `view.draw()` calls.

- [ ] **Step 1: Add `GazeSecurityTests` and `GazeUITests` targets to `Package.swift` and write failing Swift Testing tests**
  - In `Tests/GazeSecurityTests/UnlockAttemptLogTests.swift`:
    - Recording 5 attempts followed immediately by `deleteAll()` (while photo encodes are pending) leaves `attempts.json` as `[]` and zero `.jpg` files on disk after `flushForTesting()`.
    - When `photoPolicy == .off` (or `.whenNotGaze` + `.unlocked`), `record(..., photo: buffer)` sets `photoFile == nil` and does not retain/encode the buffer.
  - In `Tests/GazeUITests/RenderCacheTests.swift`:
    - `LockScreenLight.GlowCacheKey` hits cache on identical `(size, scale, notch)` and invalidates when any of size, backing scale, or notch rect changes.
    - `GazeCompanionRenderer.PausedRenderState` detects unchanged inputs vs changed angle/material/opacity/revision.

- [ ] **Step 2: Run tests to verify failing state**
  Run: `swift test --filter "UnlockAttemptLogTests|RenderCacheTests"`
  Expected: FAIL.

- [ ] **Step 3: Implement serialized `UnlockAttemptLog`, async thumbnail decoding, `LockScreenLight` glow cache & `GazeCompanionRenderer` optimizations**
  - In `UnlockAttemptLog.swift`:
    - Add serial `UnlockAttemptStorageActor` with `generation: UInt64`; `deleteAll()` bumps `generation` so any queued or finishing older `record` write checks `generation == currentGeneration` before writing the JPEG or `attempts.json`, and deletes any superseded file cleanly.
    - Only wrap `photo` in `RetainedFrame` when `keepsPhoto == true` (zero pixel-buffer retain when off).
    - Reuse one static `CIContext(options: [.cacheIntermediates: false])` for JPEG encoding.
    - Load attempt thumbnails via an async background decode (`Task.detached(priority: .utility)`) updating `photoCache` + `photoRevision` on `MainActor` instead of calling `NSImage(contentsOf:)` synchronously inside SwiftUI `body` (`UnlockAttemptsSection.swift`).
  - In `LockScreenLight.swift`:
    - Reuse one static `CIContext(options: [.cacheIntermediates: false])`.
    - Cache the rendered `CGImage` keyed by `GlowCacheKey(size:scale:notch:)` (1-2 entry cache for primary/external display).
  - In `GazeCompanionRenderer.swift`:
    - In `updateNSView`, when `!running`, only set `needsDisplay = true` / draw when `PausedRenderState` changed or view has not drawn yet.
    - In `TransparentFaceView.updateRenderingState()`, pause continuous rendering when `window == nil || !window!.isVisible || window!.isMiniaturized`, while keeping `didChangeOcclusionState`, `didChangeScreen`, and `screensDidWake` observers calling `restartRendering()` so lock-screen wake never blanks.

- [ ] **Step 4: Run tests and `swift build`**
  Run: `swift test --filter "UnlockAttemptLogTests|RenderCacheTests" && swift build -Xswiftc -warnings-as-errors`
  Expected: All tests pass, zero warnings.

- [ ] **Step 5: Commit**
  ```bash
  git add -A
  git commit -m "perf(io,render): serialize attempt log I/O, reuse CIContext, and skip redundant draws"
  ```

---

### Task 11: Port All Headless Test Suites to Swift Testing (`swift test`)

**Files:**
- Modify: `Package.swift` (ensure all 6 test targets include all ported test files)
- Create/Port into:
  - `Tests/GazeCoreTests/`: `AppIdentityTests.swift`, `StatusBroadcastTests.swift`, `AppReadinessTests.swift`, `EnrollmentStorageTests.swift`, `SettingsSearchTests.swift`, `MovementSettingsTests.swift`
  - `Tests/GazeCameraTests/`: `HeadPoseTests.swift`, `ContinuityTests.swift`, `FrameGateTests.swift`
  - `Tests/GazeRecognitionTests/`: `RecognitionTests.swift`, `RecognitionMathTests.swift`, `EnrollmentModelTests.swift`, `UnlockFlowTests.swift`, `CueDenyTests.swift`, `ChallengePoseIntegrationTests.swift`, `ConsumedContinuityIntegrationTests.swift`, `PoseSourceTests.swift`, `UnlockChallengeGateCountTests.swift`
  - `Tests/GazeSecurityTests/`: `PresenceTests.swift`, `PresenceLifecycleTests.swift`, `AppLockTests.swift`, `AdminPromptTests.swift`, `LockScreenSecurityTests.swift`, `HardeningTests.swift`, `SudoInstallScriptTests.swift`, `LockScanDiagnosticsTests.swift`
  - `Tests/GazeUpdatesTests/`: complete coverage of `Tests/UpdateLifecycle/Tests.swift` adapted to GitHub Releases (`pearleseed/Gaze`)
  - `Tests/GazeUITests/`: `NotchLogicTests.swift`, `OnboardingLogicTests.swift`, `SetupBackTests.swift`, `ToolbarLogicTests.swift`, `SettingsUXInvariantTests.swift`

**Interfaces:**
- Consumes: All 9 library targets in `Package.swift` and all legacy assertions from `Tests/*/*.swift`.
- Produces: Complete headless Swift Testing coverage runnable in seconds via `swift test` (zero lost assertions compared to the legacy headless bash/`swiftc` suites).

- [ ] **Step 1: Port `GazeCoreTests` and `GazeCameraTests` suites using `import Testing` (`@Suite`, `@Test`, `#expect`)**
  Preserve every behavioral assertion from `StatusBroadcast`, `AppReadiness`, `EnrollmentStorage`, `SettingsSearch`, `MovementSettings`, `HeadPose`, and `UnlockFlow/{Continuity,FrameGate}Tests`. Run `swift test --filter "GazeCoreTests|GazeCameraTests"` to confirm green.

- [ ] **Step 2: Port `GazeRecognitionTests` suites**
  Preserve every assertion from `Recognition`, `RecognitionMath`, `Enrollment`, and `UnlockFlow/{Tests,CueDenyTests,ChallengePoseIntegrationTests,ConsumedContinuityIntegrationTests,PoseSourceTests,UnlockChallengeGateCountTests}` (using injectable pupil/iris stubs cleanly without compile-time file shadowing). Run `swift test --filter GazeRecognitionTests` to confirm green.

- [ ] **Step 3: Port `GazeSecurityTests` suites**
  Preserve every assertion from `Presence`, `PresenceLifecycle`, `AppLock`, `AdminPrompt`, `LockScreenSecurity`, `Hardening`, `SudoInstall`, and `UnlockFlow/DiagnosticsTests`. Run `swift test --filter GazeSecurityTests` to confirm green.

- [ ] **Step 4: Port headless `GazeUITests` suites**
  Preserve all pure headless logic, geometry, state-machine, and source-invariant assertions from `Notch`, `Onboarding`, `SetupBack`, `Toolbar`, and `SettingsUX` (keeping live Metal cadence, PNG snapshot renders, and `--review` app for Task 12's `Tests/Scripts/AppIntegration/`). Run `swift test --filter GazeUITests` to confirm green.

- [ ] **Step 5: Run full `swift test` across all 6 test targets**
  Run: `swift test`
  Expected: 100% of `@Test` cases across all 6 targets pass in Swift 6 mode with zero warnings or skips.

- [ ] **Step 6: Commit**
  ```bash
  git add -A
  git commit -m "test: migrate all headless test suites to Swift Testing under Package.swift"
  ```

---

### Task 12: Desktop/Release Verification Scripts (`Tests/Scripts/`), Unified `Tests/run.sh` & End-to-End Verification

**Files:**
- Move/Update into `Tests/Scripts/Release/`: `run.sh`, `preflight-checks.sh`, `source-archive.sh`, `verify-artifact.sh`, `test-build-space.py` (updated for `com.pearleseed.Gaze`, `package.py`, un-notarized posture `1B`, and `Package.swift` layout)
- Move/Update into `Tests/Scripts/MultiFace/`: `run.sh`, `Tests.swift` (updated for multi-module imports)
- Move/Update into `Tests/Scripts/AppIntegration/`: desktop-session / `.app`-bundle / Metal-cadence / PNG-capture suites (`SettingsLaunch`, `SettingsInteraction`, `ProductBoundary`, `Onboarding` live Metal cadence & `--review`, `Notch` PNG renders, `Toolbar` `.app`-bundle artwork renders)
- Delete: Legacy migrated directories under `Tests/` (`AdminPrompt`, `AppLock`, `AppReadiness`, `Enrollment`, `EnrollmentStorage`, `Hardening`, `HeadPose`, `LockScreenSecurity`, `MovementSettings`, `Presence`, `PresenceLifecycle`, `Recognition`, `RecognitionMath`, `SettingsSearch`, `SettingsUX`, `SetupBack`, `StatusBroadcast`, `SudoInstall`, `UnlockFlow`, `UpdateLifecycle`) now superseded by `swift test`
- Modify: `Tests/run.sh`, `Tests/README.md`, `Tools/README.md`

**Interfaces:**
- Consumes: Working `swift test` targets (Task 11), unified `build.sh` / `Gaze.xcodeproj` (Task 4), `package.py` / `Signing.sh` / `verify.sh` (Task 5).
- Produces:
  - `Tests/run.sh`:
    - `Tests/run.sh` (default): runs `swift test` + `Tests/Scripts/Release/run.sh` + `Tests/Scripts/AppIntegration/ProductBoundary/run.sh`
    - `Tests/run.sh --unit`: runs `swift test` only (CI/headless-safe)
    - `Tests/run.sh --all`: runs `swift test` + Release + all desktop AppIntegration scripts (excluding network `MultiFace`)
    - `Tests/run.sh --list` / named script execution.

- [ ] **Step 1: Move & update `Release`, `MultiFace`, and `AppIntegration` scripts under `Tests/Scripts/`**
  Update file paths, module compilation flags (linking built SPM products or `swift build`), `com.pearleseed.Gaze` bundle IDs, and `package.py` verification rules. Verify `Tests/Scripts/Release/run.sh` and `Tests/Scripts/AppIntegration/ProductBoundary/run.sh` pass.

- [ ] **Step 2: Remove migrated legacy bash/`swiftc` test folders and update `Tests/run.sh`, `Tests/README.md`, and `Tools/README.md`**
  Delete only directories whose assertions are 100% ported to `Tests/Gaze*Tests/`. Update `Tests/run.sh` and documentation accurately.

- [ ] **Step 3: Full end-to-end verification across build, tests, identity, and packaging**
  Run:
  ```bash
  swift test
  Tests/run.sh
  ./build.sh
  xcodebuild -project Gaze.xcodeproj -scheme Gaze -configuration Release -arch arm64 CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/gaze-final-xcode build
  python3 -m unittest discover -s Tools/Release/ModelClearance
  python3 Tests/Scripts/Release/test-build-space.py
  ! grep -rn -i "com\.gazeunlock\|owencope\|gazeunlock\.com\|discord\.gg/BFgKT5YJH" Sources/ Resources/ Xcode/ Tools/ Integrations/ README.md build.sh Package.swift
  ```
  Expected: Every command exits 0; `swift test` 100% green; `Tests/run.sh` 100% green; `./build.sh` and `xcodebuild` both produce valid `com.pearleseed.Gaze` bundles; zero stray upstream references.

- [ ] **Step 4: Commit**
  ```bash
  git add -A
  git commit -m "chore: consolidate verification scripts under Tests/Scripts and update test runner"
  ```

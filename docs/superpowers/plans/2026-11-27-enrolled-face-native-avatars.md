# Enrolled Face Native macOS Avatars Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Native macOS Emoji & Monogram preset avatars with stateful metadata persistence and a macOS popover picker to Gaze's Enrolled Faces tiles.

**Architecture:** Store lightweight `FaceAvatarPreset` metadata as `<UUID>.avatar.json` alongside existing `<UUID>.png` portraits inside `Application Support/Gaze/Portraits/` so the encrypted Secure Enclave vault stays untouched. `FaceEnrollmentStore` manages a unified `FaceAvatar` cache with strict mutual exclusivity between custom photos and presets, while `FaceTile` renders presets natively in SwiftUI (auto-syncing Monogram initials when renamed) and presents a compact `.popover` picker.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Swift Testing (`Testing`), SwiftPM (`macOS 26.0`).

**Spec:** `docs/superpowers/specs/2026-11-27-enrolled-face-native-avatars-design.md`

## Global Constraints

- Swift 6 language mode (`Sendable`, `@MainActor`, `package` access control across targets).
- 0 KB bundled third-party assets, 100% offline, no `ModelClearance/clearance.json` or `NOTICE.md` third-party dependencies.
- Never modify `FaceEnrollment` Secure Enclave vault encoding/decoding.
- Exclude neon green (`Theme.faceID`) from avatar background swatches; green stays reserved for recognition state.
- Preserve every assertion in `Tests/GazeUITests/SettingsUXInvariantTests.swift` verbatim (`hovering || isEditing || portraitFocused || removeFocused`, `accessibilityLabel("Choose a photo for \(face.name)")`, `accessibilityAction(named: Text("Remove \(face.name)"), remove)`, no `if hovering {`, no `if controlsVisible {`).

## Review Focus

1. Multi-scalar ZWJ and variation-selector emojis (e.g., `🧑‍💻`, `👩‍🎨`, `⭐️`, `☕️`) must remain whole single grapheme clusters when normalized — never sliced by UTF-16 code units or scalars.
2. Simultaneous `.png` and `.avatar.json` on disk (e.g., external edit or interrupted write) must resolve deterministically, and writing either must delete the other.
3. Corrupt/truncated `.avatar.json` or unknown enum cases must gracefully fall back to `.png` (if present) or `.none` without crashing.
4. Monograms with `customText == nil` must update dynamically when `face.name` changes (including Unicode/Vietnamese initials like `"Đăng Khoa"` → `"ĐK"`), while explicit `customText` stays preserved.
5. `remove(_:)` and `removeAll()` must delete both `.png` and `.avatar.json` so no orphaned metadata files remain on disk.

---

### Task 1: Avatar Model & Normalization Helpers

**Files:**
- Create: `Sources/GazeRecognition/FaceAvatar.swift`
- Test: `Tests/GazeRecognitionTests/FaceAvatarTests.swift`

**Interfaces:**
- Consumes: Foundation, AppKit (`NSImage`).
- Produces:
  - `package enum FaceAvatarColor: String, Codable, Sendable, CaseIterable, Identifiable` (`slate`, `blue`, `indigo`, `purple`, `pink`, `coral`, `amber`, `teal`)
  - `package enum FaceAvatarPreset: Codable, Equatable, Sendable` (`.emoji(symbol: String, color: FaceAvatarColor)`, `.monogram(customText: String?, color: FaceAvatarColor)`)
  - `package enum FaceAvatar` (`.photo(NSImage)`, `.preset(FaceAvatarPreset)`, `.none`; `package var isCustomized: Bool`; `package var preset: FaceAvatarPreset?`; `package var photo: NSImage?`)
  - `package enum FaceAvatarText`:
    - `package static let curatedEmojis: [String]` (24 curated Apple Color Emojis)
    - `package static func initials(for name: String) -> String`
    - `package static func sanitizedMonogram(_ raw: String) -> String?`
    - `package static func normalizedEmoji(_ raw: String) -> String?`

- [x] **Step 1: Write failing unit tests in `Tests/GazeRecognitionTests/FaceAvatarTests.swift`**
  - Test `FaceAvatarColor.allCases.count == 8` and none named `"green"`.
  - Test `FaceAvatarPreset` JSON encode/decode round-trip for `.emoji(symbol: "🧑‍💻", color: .indigo)`, `.monogram(customText: nil, color: .blue)`, and `.monogram(customText: "VN", color: .coral)`.
  - Test `FaceAvatarText.initials(for:)`: `"Nam"` → `"N"`, `"Đăng Khoa"` → `"ĐK"`, `"  Alice   Bob  Carol "` → `"AB"`, `"   "` → `"?"`.
  - Test `FaceAvatarText.sanitizedMonogram(_:)`: `"  vn "` → `"VN"`, `"abc"` → `"AB"`, `"  đăng "` → `"ĐĂ"`, `"   "` → `nil`.
  - Test `FaceAvatarText.normalizedEmoji(_:)`: `" 🧑‍💻 "` → `"🧑‍💻"`, `"⭐️🚀"` → `"⭐️"`, `"🦊abc"` → `"🦊"`, `"   "` → `nil`, `"abc"` → `nil` (rejects plain ASCII letters/digits that have no emoji presentation).

- [x] **Step 2: Run test to verify RED**
  - Run: `swift test --filter FaceAvatarTests`
  - Expected: FAIL (missing `FaceAvatarColor`, `FaceAvatarPreset`, `FaceAvatarText`).

- [x] **Step 3: Implement `Sources/GazeRecognition/FaceAvatar.swift`**
  - Implement all types and helpers cleanly in Swift 6 (`Sendable`, `package`).
  - Use Swift `Character` grapheme clusters (not `UTF16View`) for both `sanitizedMonogram` (`prefix(2)`) and `normalizedEmoji` (first `Character` whose `unicodeScalars` contain an emoji presentation or emoji + variation selector/ZWJ, excluding bare ASCII `#`/`*`/`0-9`).

- [x] **Step 4: Run test to verify GREEN**
  - Run: `swift test --filter FaceAvatarTests`
  - Expected: PASS (all tests in `FaceAvatarTests` succeed).

---

### Task 2: Store Persistence & Mutual Exclusivity

**Files:**
- Modify: `Sources/GazeRecognition/FaceEnrollment.swift`
- Test: `Tests/GazeRecognitionTests/FaceAvatarStoreTests.swift`

**Interfaces:**
- Consumes: `FaceAvatarColor`, `FaceAvatarPreset`, `FaceAvatar` from `FaceAvatar.swift`.
- Produces on `FaceEnrollmentStore`:
  - `init(..., portraitsDirectory: URL? = nil)` (injectable directory for tests; `nil` resolves `Self.portraitsDirectory()`).
  - `package func avatar(for id: UUID) -> FaceAvatar`
  - `package func setAvatarPreset(_ preset: FaceAvatarPreset?, for id: UUID)`
  - Existing `package func portrait(for id: UUID) -> NSImage?` (returns `avatar(for: id).photo`)
  - Existing `package func setPortrait(_ image: NSImage?, for id: UUID)` (mutually exclusive with preset)
  - Existing `remove(_:)` and `removeAll()` delete both `.png` and `.avatar.json`.

- [x] **Step 1: Write failing unit tests in `Tests/GazeRecognitionTests/FaceAvatarStoreTests.swift`**
  - Use an isolated temporary directory per test (cleaned via `defer`).
  - Test setting emoji preset persists `<id>.avatar.json`, bumps `portraitRevision`, reloads cleanly on a fresh `FaceEnrollmentStore` instance, and `portrait(for:)` returns `nil`.
  - Test mutual exclusivity: setting a photo after a preset writes `<id>.png` and removes `<id>.avatar.json`; setting a preset after a photo writes `<id>.avatar.json` and removes `<id>.png`.
  - Test clearing with `setAvatarPreset(nil, for:)` or `setPortrait(nil, for:)` removes both files, caches `.none`, and bumps `portraitRevision`.
  - Test corrupt `<id>.avatar.json` (invalid JSON / unknown color) falls back to `.png` if present, or `.none` if not.
  - Test simultaneous `.png` and `.avatar.json` on disk resolves deterministically to `.preset` (or `.photo` — pick `.preset` when valid JSON exists, `.photo` fallback) and next write cleans the conflicting file.
  - Test `remove(_:)` and `removeAll()` delete both `.png` and `.avatar.json`.

- [x] **Step 2: Run test to verify RED**
  - Run: `swift test --filter FaceAvatarStoreTests`
  - Expected: FAIL (missing `portraitsDirectory:` parameter, `avatar(for:)`, `setAvatarPreset(_:for:)`).

- [x] **Step 3: Implement unified avatar persistence in `Sources/GazeRecognition/FaceEnrollment.swift`**
  - Add `private let portraitsDirectoryURL: URL?` injected via `init(..., portraitsDirectory: URL? = nil)`.
  - Replace `portraitCache: [UUID: NSImage?]` with `@ObservationIgnored private var avatarCache: [UUID: FaceAvatar] = [:]`.
  - Add `avatarURL(for id: UUID) -> URL?` (`<id>.avatar.json`) and instance-scoped `portraitURL(for:)` / `avatarURL(for:)` helpers using `portraitsDirectoryURL ?? Self.portraitsDirectory()`.
  - Implement `avatar(for:)`, `setAvatarPreset(_:for:)`, updated `portrait(for:)`, `setPortrait(_:for:)`, `remove(_:)`, and `removeAll()`.

- [x] **Step 4: Run test to verify GREEN**
  - Run: `swift test --filter "FaceAvatarTests|FaceAvatarStoreTests|EnrollmentModelTests"`
  - Expected: PASS (0 failures).

---

### Task 3: Native Popover Picker & Enrolled Face Tile Integration

**Files:**
- Create: `Sources/GazeApp/Settings/FaceAvatarPicker.swift`
- Modify: `Sources/GazeApp/Settings/EnrolledFaceTiles.swift`
- Modify: `Sources/GazeApp/Settings/SettingsUnlockPane.swift`
- Modify: `Sources/GazeApp/Settings/SettingsSearch.swift`
- Modify: `Tests/GazeUITests/SettingsUXInvariantTests.swift`

**Interfaces:**
- Consumes: `FaceAvatar`, `FaceAvatarPreset`, `FaceAvatarColor`, `FaceAvatarText`, `FaceEnrollmentStore.avatar(for:)`, `FaceEnrollmentStore.setAvatarPreset(_:for:)`, `FaceEnrollmentStore.setPortrait(_:for:)`.
- Produces:
  - `FaceAvatarPalette` (SwiftUI light/dark-friendly pastel gradients for Emoji and vibrant macOS gradients for Monogram per `FaceAvatarColor`).
  - `FaceAvatarView` (renders `.photo`, `.preset(.emoji)`, `.preset(.monogram)` live-synced to `faceName`, and `.none` neutral initials inside a circle of given diameter).
  - `FaceAvatarPicker` (SwiftUI popover view with Emoji & Monogram tabs, curated 24-emoji grid, custom emoji field + macOS Character Palette button, 2-char Monogram input synced with `faceName`, 8 color swatches, `Choose Photo…`, and conditional `Reset`).
  - Updated `FaceTile` presenting `FaceAvatarPicker` in `.popover(isPresented: $showingAvatarPicker, arrowEdge: .bottom)` while preserving all `SettingsUXInvariantTests` invariants.

- [x] **Step 1: Add UI invariant assertions in `Tests/GazeUITests/SettingsUXInvariantTests.swift`**
  - Add test asserting `EnrolledFaceTiles` / `FaceAvatarPicker` exposes popover presentation, Emoji & Monogram picker tabs, `NSApp.orderFrontCharacterPalette`, `Choose Photo…`, and preserves all existing `enrolledFaceActionsKeyboardFocusAndAccessibilityLabels` assertions.

- [x] **Step 2: Run test to verify RED**
  - Run: `swift test --filter SettingsUXInvariantTests`
  - Expected: FAIL on the new avatar picker invariant test.

- [x] **Step 3: Implement `Sources/GazeApp/Settings/FaceAvatarPicker.swift` and update `EnrolledFaceTiles.swift`, `SettingsUnlockPane.swift`, and `SettingsSearch.swift`**
  - Create `FaceAvatarPicker.swift` with `FaceAvatarPalette`, `FaceAvatarView`, and `FaceAvatarPicker`.
  - Update `FaceTile` in `EnrolledFaceTiles.swift` to take `avatar: FaceAvatar`, `setPortrait: (NSImage?) -> Void`, `setAvatarPreset: (FaceAvatarPreset?) -> Void`, render `FaceAvatarView`, present `.popover(isPresented: $showingAvatarPicker, arrowEdge: .bottom)`, keep `camera.fill` button with `.accessibilityLabel("Choose a photo for \(face.name)")`, keep `controlsVisible` (`hovering || isEditing || portraitFocused || removeFocused` — plus `|| showingAvatarPicker` only if keeping exact substring intact? Note: `SettingsUXInvariantTests` checks `settings.contains("hovering || isEditing || portraitFocused || removeFocused")`, which STILL matches `hovering || isEditing || portraitFocused || removeFocused || showingAvatarPicker`!).
  - Update `SettingsUnlockPane.swift` to wire `avatar: store.avatar(for: face.id)` and `setAvatarPreset: { store.setAvatarPreset($0, for: face.id) }`.
  - Update `SettingsSearch.swift` to include `"avatar"`, `"emoji"`, `"monogram"` keywords on `"Enrolled faces"`.

- [x] **Step 4: Run full test suite & build verification**
  - Run: `swift test`
  - Expected: PASS (all test suites green, 0 errors, 0 warnings introduced).

# Enrolled Face Native macOS Avatars (Emoji & Monogram) — Design Spec

Date: 2026-11-27
Scope: Small-to-medium feature in `GazeRecognition` and `GazeApp`

## 1. Intent & Why

Currently, each enrolled face tile in Settings (`Enrolled faces`) falls back to neutral grey initials unless the user picks an image file from Finder via `NSOpenPanel`. Most users do not have a cropped square photo ready on disk, leaving multiple enrolled faces visually uniform and harder to scan at a glance.

Adding **Native macOS preset avatars (Emoji & Monogram)** gives users instant, zero-friction personalization that:
- Matches macOS *Users & Groups* / *Contacts* conventions and Gaze's neutral, native macOS 26 aesthetic.
- Adds **0 KB** of bundled artwork, stays **100% offline**, and introduces **zero third-party licensing or `ModelClearance` obligations**.
- Keeps Monogram avatars automatically in sync when a face is renamed, and remembers the user's current selection when reopening the picker.

## 2. Goals, Non-Goals, and Constraints

### Goals
- Allow selecting a native **Emoji** avatar (curated grid + optional custom emoji via macOS Character Palette `⌃⌘Space`, on a soft pastel circular gradient) or **Monogram** avatar (auto-synced to `face.name` initials or optional 1–2 character override, on a rich macOS circular gradient).
- Preserve full custom photo upload (`Choose Photo…` via `NSOpenPanel`) and reset back to default neutral initials (`Remove` / `Use Initials`).
- Persist preset metadata alongside existing portraits so reopening the popover restores the active tab, symbol/text, and color, and renaming a face updates auto-initials Monograms live.
- Preserve all existing keyboard focus, VoiceOver, and structural UX invariants in `Tests/GazeUITests/SettingsUXInvariantTests.swift`.

### Non-Goals
- No bundled third-party illustrations or bitmap asset packs.
- No network fetches.
- No changes to the encrypted `FaceEnrollment` Secure Enclave vault schema or migration.
- No neon-green background swatches (green `Theme.faceID` remains reserved strictly for face-recognition state).

### Constraints
- Swift 6 language mode (`Sendable`, `@MainActor`, `package` access control across `GazeRecognition` / `GazeApp`).
- Portraits remain outside the encrypted Keychain/Secure Enclave vault in `~/Library/Application Support/Gaze/Portraits/`.
- All `SettingsUXInvariantTests` assertions must continue to pass verbatim (including `hovering || isEditing || portraitFocused || removeFocused` and `accessibilityLabel("Choose a photo for \(face.name)")`).

## 3. Approaches Considered

1. **Approach 1 — Render presets to PNG through existing `setPortrait(_:for:)`**
   - *Trade-off:* Zero new storage formats, smallest diff, but loses structured state: renaming a face leaves stale Monogram text, and reopening the picker cannot highlight the previously selected emoji/color.
2. **Approach 2 — Persist lightweight avatar preset metadata beside portrait PNGs (Selected)**
   - *Trade-off:* Adds a small `<UUID>.avatar.json` file alongside `<UUID>.png` in `Portraits/` and coordinates mutual exclusivity + cleanup on face removal, in exchange for native SwiftUI Retina rendering, live auto-updating Monograms on rename, and stateful picker restoration.
   - *Why chosen:* Selected by the user for cleaner macOS-native UX and live rename synchronization without touching the Secure Enclave vault.

## 4. Architecture & Design

### 4.1 Model (`Sources/GazeRecognition/FaceAvatar.swift`)
- `FaceAvatarColor: String, Codable, Sendable, CaseIterable, Identifiable`
  - 8 macOS-tuned tones: `slate`, `blue`, `indigo`, `purple`, `pink`, `coral`, `amber`, `teal` (explicitly excluding recognition green).
- `FaceAvatarPreset: Codable, Equatable, Sendable`
  - `.emoji(symbol: String, color: FaceAvatarColor)`
  - `.monogram(customText: String?, color: FaceAvatarColor)` — `nil` dynamically derives initials from `face.name`; non-nil stores trimmed 1–2 grapheme clusters.
- `FaceAvatar` (resolved display state for a tile):
  - `.photo(NSImage)`
  - `.preset(FaceAvatarPreset)`
  - `.initials` (default neutral `Theme.surface` circle with initials; named `.initials` instead of `.none` to avoid `Optional.none` ambiguity in Swift caches)
- Helper `FaceAvatarText.initials(for name: String) -> String` and normalization helpers for single-emoji extraction and 2-character monogram sanitization (shared between model, tile, and picker, easily unit-tested).

### 4.2 Persistence & Store (`Sources/GazeRecognition/FaceEnrollment.swift`)
- Inject an optional `portraitsDirectory: URL?` (defaulting to `~/Library/Application Support/Gaze/Portraits`) on `FaceEnrollmentStore.init` so unit tests can test persistence, mutual exclusivity, corruption fallback, and cleanup in an isolated temp directory.
- Disk paths per face `id`:
  - Custom photo: `<id>.png`
  - Preset metadata: `<id>.avatar.json`
- Single in-memory cache (`avatarCache: [UUID: FaceAvatar]`, `@ObservationIgnored`) replacing or unifying `portraitCache`, invalidated and bumped via existing `portraitRevision`:
  - `avatar(for id: UUID) -> FaceAvatar`: loads `.avatar.json` (if valid) or `.png` (if present), else `.none`. Corrupt JSON safely falls back to `.png` or `.none` without throwing.
  - `portrait(for id: UUID) -> NSImage?`: kept as convenience returning the image when `avatar(for:)` is `.photo`.
  - `setPortrait(_ image: NSImage?, for id: UUID)`:
    - If `image != nil`: writes 256×256 `.png`, removes `.avatar.json`, caches `.photo`, bumps `portraitRevision`.
    - If `image == nil`: removes both `.png` and `.avatar.json`, caches `.none`, bumps `portraitRevision`.
  - `setAvatarPreset(_ preset: FaceAvatarPreset?, for id: UUID)`:
    - If `preset != nil`: encodes and atomically writes `.avatar.json`, removes `.png`, caches `.preset`, bumps `portraitRevision`.
    - If `preset == nil`: removes both `.png` and `.avatar.json`, caches `.none`, bumps `portraitRevision`.
  - `remove(_ id: UUID)` and `removeAll()`: remove both `.png` and `.avatar.json` and clear cache entries.

### 4.3 UI & Interaction (`Sources/GazeApp/Settings/FaceAvatarPicker.swift`, `EnrolledFaceTiles.swift`, `SettingsUnlockPane.swift`)
- **Tile rendering (`FaceTile`):**
  - Renders `FaceAvatar` inside the existing 52×52pt `.circle`:
    - `.photo(image)`: existing aspect-fill `Image(nsImage:)`.
    - `.preset(.emoji(symbol, color))`: soft pastel linear gradient for `color` + centered Apple Color Emoji (`28pt`).
    - `.preset(.monogram(customText, color))`: rich macOS linear gradient for `color` + white SF Pro Rounded semibold initials (`customText ?? initials`, `21pt`).
    - `.none`: existing `Theme.surface` fill + `Theme.secondaryLabel` initials.
- **Triggering the picker:**
  - Clicking the hover/focus `camera.fill` button (or clicking the avatar circle itself) presents a SwiftUI `.popover(isPresented: $showingAvatarPicker, arrowEdge: .bottom)`.
  - Preserves exact `.accessibilityLabel("Choose a photo for \(face.name)")`, `.focused($portraitFocused)`, and `controlsVisible` expression (`hovering || isEditing || portraitFocused || removeFocused`) so all `SettingsUXInvariantTests` pass untouched.
  - Context menu offers `Choose Avatar…` (opens popover), `Choose Photo…` (direct `NSOpenPanel` shortcut), and when `avatar != .none`, `Remove Avatar` (destructive, resets to `.none`).
- **Popover layout (`FaceAvatarPicker`, width `272pt`):**
  - Segmented tab control: **Emoji** | **Monogram** (auto-initialized from the face's current `FaceAvatarPreset` if any).
  - **Emoji tab:**
    - Curated 6×4 grid (24 crisp native emojis: animals, expressions, personas, icons).
    - Compact custom emoji row with a single-character input + button triggering `NSApp.orderFrontCharacterPalette(nil)` so users can pick any macOS emoji.
    - 8 circular pastel background swatches (`FaceAvatarColor.allCases`).
  - **Monogram tab:**
    - Live 56pt circular preview + compact text field (placeholder = auto-initials from `face.name`, capped at 2 characters, helper caption: `"Leave blank to follow name"`).
    - 8 circular gradient swatches (`FaceAvatarColor.allCases`).
  - **Footer bar (below divider):**
    - Leading: `Choose Photo…` (dismisses popover and opens `NSOpenPanel`).
    - Trailing (only when `avatar != .none`): `Reset` (destructive role, clears back to default initials).
  - Selecting any emoji, color, or monogram edit updates the tile immediately (live preview) without needing a separate Save button.

## 5. Verification Plan
- Unit tests covering:
  - `FaceAvatarPreset` Codable round-trip, initials extraction, monogram sanitization (max 2 chars, whitespace -> `nil`), and emoji normalization.
  - `FaceEnrollmentStore` avatar persistence in temp directory: saving preset writes `.avatar.json` and deletes `.png`; saving photo writes `.png` and deletes `.avatar.json`; clearing removes both; corrupt JSON falls back gracefully; `remove` / `removeAll` cleans up `.avatar.json` and `.png`; `portraitRevision` bumps on every change.
- Existing test suites (`swift test`), including `SettingsUXInvariantTests` and `GazeRecognitionTests`.
- Release/local Swift build check.

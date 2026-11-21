# Vendored SwiftTerm

This is [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) at tag **v1.20.0** (MIT, see `LICENSE`), vendored to keep the app small and the build simple.

## What was removed

- Docs, tests, benchmarks and the example and tool targets.
- The `SwiftTermBuildInfoPlugin` build plugin, which needs Xcode's plugin trust prompt. `SwiftTermBuildInfo.swift` is a static stand-in with the same API.
- The opt-in Metal renderer (`Apple/Metal/` and its `canImport(MetalKit)` paths in the views), which pounce never enabled, so terminals draw with CoreText as before and MetalKit isn't linked.
- The macOS views in `Mac/` (except `MacAccessibilityService.swift`, which iOS uses), so the package builds for iOS only.
- `TerminalAccessory`, `KeyboardView` and `DoubleButton`, since pounce brings its own key bar; `inputAccessoryView` now starts as nil.
- Search (`Search*.swift`, `TerminalViewSearch.swift`), which pounce never calls.
- The `swift-argument-parser` and `swift-docc-plugin` dependencies, which only served the removed targets.

## What was patched

`Sources/SwiftTerm/iOS/iOSTerminalView.swift` gains four small public members, marked `pounce patch`, so the app's own selection gestures (`pounce/Views/TerminalGestures.swift`) can map touches to cells and show the edit menu: `cellSize`, `bufferPosition(at:)`, `showSelectionMenu()` and `refreshSelection()`.

For pounce's own caret (`pounce/Views/TerminalCaret.swift`), `iOSTerminalView.swift` adds `CaretState`, `drawsCaret` and `caretObserver`, called when the caret moves, changes style or the view's focus changes; `iOSCaretView.swift` draws nothing and doesn't blink while `drawsCaret` is false; and `Apple/AppleTerminalView.swift`'s `updateCursorPosition()` reports each move. Nothing else changes.

`Package.swift` passes `-suppress-warnings`, so upstream's deprecation warnings don't show up in the app build.

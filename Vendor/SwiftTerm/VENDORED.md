# Vendored SwiftTerm

This is [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) at tag **v1.20.0** (MIT, see `LICENSE`), vendored to keep the app small and the build simple.

## What was removed

- Docs, tests, benchmarks and the example and tool targets.
- The `SwiftTermBuildInfoPlugin` build plugin, which needs Xcode's plugin trust prompt. `SwiftTermBuildInfo.swift` is a static stand-in with the same API.
- `Apple/Metal/Shaders.metal`, so no resource bundle is built. The Metal renderer is opt-in (`setUseMetal(_:)`) and pounce never enables it, so terminals draw with CoreText.
- The `swift-argument-parser` and `swift-docc-plugin` dependencies, which only served the removed targets.

## What was patched

`Sources/SwiftTerm/iOS/iOSTerminalView.swift` gains four small public members, marked `pounce patch`, so the app's own selection gestures (`pounce/Views/TerminalGestures.swift`) can map touches to cells and show the edit menu: `cellSize`, `bufferPosition(at:)`, `showSelectionMenu()` and `refreshSelection()`.

For pounce's own caret (`pounce/Views/TerminalCaret.swift`), `iOSTerminalView.swift` adds `CaretState`, `drawsCaret` and `caretObserver`, called when the caret moves, changes style or the view's focus changes; `iOSCaretView.swift` draws nothing and doesn't blink while `drawsCaret` is false; and `Apple/AppleTerminalView.swift`'s `updateCursorPosition()` reports each move. Nothing else changes.

`Package.swift` passes `-suppress-warnings`, so upstream's deprecation warnings don't show up in the app build.

# Testing Argus

Argus uses Apple's Swift Testing framework through the `ArgusTests` Xcode unit-test target. Run the complete app and CLI test suite with:

```sh
./scripts/test.sh
```

The complete suite checks formatting with [swift-format](https://github.com/swiftlang/swift-format) and then runs
SwiftLint before building. Swift 6 toolchains include swift-format; install SwiftLint with Homebrew:

```sh
brew install swiftlint
```

Run linting by itself with:

```sh
./scripts/lint.sh
```

Format all Swift sources with:

```sh
./scripts/format.sh
```

Set `SWIFT_FORMAT_BIN` or `SWIFTLINT_BIN` to use executables outside the active Swift toolchain and standard Homebrew
paths.

Tests are grouped by product domain rather than implementation chronology:

- `WorkspaceTests` covers window, sidebar, tab, and panel behavior.
- `WorktreeTests` covers projects, repositories, branches, and worktrees.
- `SessionTests` covers persistence and restore behavior.
- `GitStatusTests` covers status parsing, operations, previews, and presentation state.
- `TestSupport` contains shared native test helpers.

Prefer behavioral tests against `@testable import Argus`. Source contracts are reserved for SwiftUI and AppKit wiring that cannot be observed through a stable public behavior without launching a full UI test.

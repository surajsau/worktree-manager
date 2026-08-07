# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
make macos                        # build the .app bundle and relaunch it
make test                         # 61 tests, ~1s, no repo/gh/network needed
make test FILTER=PanelRenderTests # one suite — matches type/function names, not @Test display names
make render                       # render the panel (light + dark) and settings, then open them

cd macos && swift build           # debug build only
cd macos && swift test --filter stackTitle   # a single test, by function name
```

A menu bar dropdown can't be screenshotted without accessibility access, so the binary renders itself:

```bash
./macos/.build/release/WorktreeManager --stacks           # the tree as the menu groups it
./macos/.build/release/WorktreeManager --stacks-selftest   # ...on a synthetic branching stack
./macos/.build/release/WorktreeManager --render out.png [--dark|--demo|--forks|--expand-first]
./macos/.build/release/WorktreeManager --render-settings out.png
./macos/.build/release/WorktreeManager --list
```

Hooks that read git see no settings when run outside the `.app` (different UserDefaults domain), so pass the repo in: `WORKTREE_MANAGER_REPO=~/code/repo ./macos/.build/release/WorktreeManager --stacks`. The same variables let the shell scripts run standalone: `WORKTREE_MANAGER_REPO=… ./create-worktree.sh my-feature [base]`.

## Architecture

Two halves. The SwiftUI app in `macos/` is the only frontend; the shell scripts at the repo root (`create-worktree.sh`, `add-existing-worktree.sh`, `agent-artifacts.sh`) are the single source of truth for creating and adding worktrees — the app shells out to them, and `build-app.sh` copies them into the bundle's `Resources/`.

**Configuration is never compiled in.** `Config` (`Models.swift`) resolves the repository path, worktree folder, main branch and branch prefix from environment variables first, then UserDefaults (written by `SettingsView`). `Config.shellEnvironment` passes them to the scripts; `Config.writeShellConfig()` mirrors them to `~/.config/worktree-manager/config`, which `config.sh` sources for terminal runs. Adding a repo-specific value means: a `SettingsKeys` entry, a `Config` accessor, a control in `SettingsView`, and — if a script needs it — a line in `config.sh` and `shellEnvironment`.

**Data flow.** `GitService` (worktree list + per-branch status, all `Process` calls with arg arrays, never a shell) and `GitHubService` (one `gh api graphql` query for every open PR, cached to `~/Library/Caches/WorktreeManager`) feed `Store`, a `@MainActor ObservableObject`. `Store` runs `StackBuilder.build` to turn flat worktrees + PRs into `Stack` trees, and the views read only that.

**How the tree is built** (`Stack.swift`): a PR's `baseRefName` wins whenever a PR exists — it survives rebases that break commit ancestry — and branches with no PR get a parent inferred from the commit graph (nearest branch whose tip they contain). PRs with no local worktree stay in the tree as dimmed *ghost* nodes, or chains break in two wherever a middle worktree was removed. A branch with no commits above `Config.trunkRef` is *merged* and moves to the prunable section; that measurement is only as honest as the last fetch, which is why refresh fetches the trunk first.

**How it's laid out** (`StackLayout`, `StackView.swift`): the mainline renders flat however deep it goes; a branch that forks off gets exactly one indent under a `↳ off <parent>` label; a fork inside a fork becomes a drill-in button. Deep indentation is deliberately rejected — the panel is 420pt wide.

**The seam** (`Repositories.swift`): everything below `Store` that touches git, GitHub, the disk or another app goes through a protocol — `WorktreeRepository`, `PullRequestRepository`, `PRSnapshotStore`, `AvatarLoading`. The app injects live implementations; tests inject `Fakes.swift`, which record calls and mutate their own state so the refresh after a delete sees the branch gone. Whether cmux is installed rides in the SwiftUI environment for the same reason: a render test gets the same row on any machine. `SampleData.swift` lives in the *app* target, not the test target, because `--render --demo` and `--stacks-selftest` use it too.

**Row vocabulary lives in `RowStatus.swift`**, not in the view that draws it — which is what makes "does this row show a Resolve chip" testable without a screenshot.

## Rules

- **Read `DESIGN.md` before changing any UI.** Its rules (one container level, colour marks the exceptional, one line per row) are assertions in `PanelRenderTests.swift` — change a rule, change its test. Sizes, colours and type live in `DesignSystem.swift`; a raw hex or font size in a view is a bug.
- **Look at a render before calling a UI change done**, in both appearances. `ImageRenderer` draws AppKit-backed controls blank, which is why the settings window has its own offscreen-window render path.
- **Nothing repo-specific gets hardcoded** — no repo path, branch name, prefix or app name in source.
- The render tests are not golden images; they render a view and ask the questions the design cares about, so they hold on any machine.
- `swift-testing` is a pinned package dependency (`0.12.0`) rather than the toolchain's: Command Line Tools ship `Testing.framework` without the module it's built from, and no XCTest. Test target only. See the note in `macos/Package.swift`.

## Agent skills

### Issue tracker

Issues live as markdown files under `.scratch/<feature>/` in this repo. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, used verbatim as `Status:` values. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

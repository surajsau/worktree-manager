# worktree-manager

A native macOS menu bar app (`macos/`, SwiftUI) over a few shell scripts, showing git worktrees for **abema-androidtv** as the GitHub PR stacks they form. The app is the only frontend — the Node web app that used to live here was removed; `git log -- server.js` if you need it.

## Working here

```bash
make macos    # rebuild the .app bundle and relaunch it
make test     # 61 tests, ~1s, no repo/gh/network needed
make render   # render the panel from fake data, light + dark, and open them
```

- **Before changing any UI, read `DESIGN.md`.** It holds the panel's visual rules and every size, inset and colour the views draw from (`DesignSystem.swift`). Its rules are also assertions in `macos/Tests/WorktreeManagerTests/PanelRenderTests.swift` — if you change a rule, change its test.
- **Look at a render before calling a UI change done.** A menu bar dropdown can't be screenshotted without accessibility access, so the app renders itself (`--render out.png [--dark|--demo|--forks|--expand-first]`). Check both appearances.
- **Anything touching git, GitHub, the disk or another app goes through a repository protocol** (`Repositories.swift`), so the panel stays renderable and testable from `SampleData.swift`.
- **Row logic belongs in `RowStatus.swift`**, not in the view that draws it.

## Agent skills

### Issue tracker

Issues live as markdown files under `.scratch/<feature>/` in this repo. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, used verbatim as `Status:` values. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

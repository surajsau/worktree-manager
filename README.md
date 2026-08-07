# Worktree Manager
A tiny local tool to create, delete, and open git worktrees for **any** repo — without touching the main checkout (which stays on its trunk).

A native SwiftUI menu bar app (`macos/`) over a few shell scripts, showing your worktrees as the GitHub PR **stacks** they actually form. (There was a zero-dependency Node web app here too; it never grew stack support and is gone as of this version — `git log -- server.js` if you need it back.)

## Menu bar app (macOS)
```bash
macos/build-app.sh
open macos/WorktreeManager.app
```

Builds with Xcode Command Line Tools only (Swift 6 / macOS 14+, no Xcode needed). A ⎇ branch icon appears in the status bar; clicking it opens the **stack view**.

### First run

Nothing is baked into the binary, so the first thing the panel asks for is a repository. Open **Settings** and fill in:

| | |
|---|---|
| **Repository** | the git checkout to manage worktrees for |
| **Worktree folder** | where new worktrees are created — defaults to a `worktrees` folder beside the repo |
| **Main branch** | the trunk your stacks sit on: `main`, `master`, `develop`, … |
| **Branch prefix** | optional, put in front of every branch the create flow makes (`alex/` → `alex/fix-crash`) |

The same four values are mirrored to `~/.config/worktree-manager/config`, which is what the shell scripts read when you run them yourself.

### Stack view

The dropdown is organised by PR stack, not by folder. Each section is one chain of branches sitting on a trunk (your main branch, a release branch, …), named after the branch at the bottom — the one that merges first. One line per branch; see [DESIGN.md](DESIGN.md) for the rules the panel follows.

```
⌄ episode-list  load-previous-page                     ↓90  6 → main
  ● load-previous-page                        (avatar) 3  #18531
  ● page-cursor                                           #18567
  ● overlay-pagination-wiring                      Draft  #18568
  ● anchored-group                                 Draft  #18572
  ● anchored-series                                Draft  #18577
  ● linear                                         Draft  #18532   ← red dot: CI failing
```

**How the tree is built.** A PR's base branch wins whenever a PR exists — that is what GitHub will actually merge into, and it survives rebases that break commit ancestry. Branches with no PR get a parent inferred from the commit graph (the nearest branch whose tip they already contain). PRs whose branch isn't checked out locally still appear, dimmed and marked `No worktree`: without them a chain like `#18579 → #18580 → #18581` would break in two the moment the middle worktree is removed.

**Forks.** The mainline renders flat however deep it goes — an 8-PR stack indented 8 times leaves no room for a branch name. A branch that forks off the chain gets one level of indent under a `↳ off <parent>` label, which names the fork point instead of making you infer it. A fork inside a fork becomes a **N more branches below** button that opens that subtree on its own.

**What the colours mean** (also listed under Legend in Settings). Colour is spent only on things that aren't fine — everything routine is grey:

| | |
|---|---|
| Dot | **CI only** — green passing, yellow running, red failing, hollow = no PR |
| Branch name | local working tree — normal clean, amber uncommitted changes, red merge conflict in progress |
| `3●` `↑1` | uncommitted changes / commits not pushed anywhere |
| ⚠ | the PR conflicts with its base branch |
| `⑄ Resolve` | click to hand the conflict to an agent in cmux — shown for either conflict signal above |
| avatars + orange count | unresolved review threads, by author — round avatar is a person, square is a bot |
| 💬 | a comment from a human other than you, with nothing unresolved |
| ✓ / ✗ seal | approved / changes requested |
| `#18581` | click to open the PR in your browser |

The comment indicator is deliberately quiet: on a repo where several bots comment on every PR, avatars are spent only on **unresolved review threads** (whoever opened them), and a plain human comment gets a grey bubble. A bare comment count lit up every row and said nothing.

**Rows.** Hovering swaps the PR status glyphs for copy-path, open-in-terminal, open-in-editor (whichever editor Settings names), and a **⋯** that opens the PR title, diff size, **Pull &lt;main branch&gt;** (disabled when already up to date), **Stack on** (new worktree branched off this one), and **Delete**. The PR number keeps its own column and stays clickable either way. A `No worktree` row instead offers **+** to check that branch out. A row with an unresolved merge conflict also carries a red **Resolve** chip that stays visible without hovering — see below.

**Resolve conflicts.** A red **Resolve** chip appears next to the branch name — always visible, since a conflict blocks everything stacked above it and the way out shouldn't be behind a hover. It fires on **either** conflict signal: GitHub reporting the PR as `CONFLICTING` against its base (the common one — nothing has happened locally yet), or a local merge left half-done. `/resolve-conflicts` handles both: it detects the base branch, starts the merge itself, and skips straight to reporting if one is already in progress. When the PR conflicts and the worktree is *dirty*, the chip still shows but its tooltip warns that the merge refuses to start on a dirty tree.

Clicking it opens a **new cmux workspace** at that worktree named `resolve: <folder>`, running `opus /resolve-conflicts`. A fresh workspace rather than the focus-or-reuse of the terminal button: a tab already sitting at that folder may be mid-task, and typing into it would land in whatever is running. cmux is started first if it isn't up. The command comes from `Config.resolveConflictsCommand`; cmux runs it through an interactive login shell, so a shell alias like `opus` resolves. Hidden when cmux.app isn't installed, and toggleable in Settings.

**Merged.** Branches with no commits outside the trunk (`origin/<main branch>`) are collected into a **Merged** section with a one-click **Prune** that removes the worktrees and branches, skipping any with uncommitted or unpushed work.

### Refresh

Git state is local and re-read every time the dropdown opens (~0.5s). PR data needs one `gh api graphql` query covering every open PR (~3s), so it is cached to disk and refreshed on a 30-minute poll; the header shows its age. The refresh button also fetches the main branch, which is what keeps merged-branch detection honest — a stale trunk ref under-reports merges. Turn the poll off in Settings to fetch only on demand.

Needs `gh` installed and logged in (`brew install gh && gh auth login`). Without it the view degrades to a plain git tree and says why in a footer bar.

### Other

- **New Worktree** / **Add Existing…** in the footer open the create and add-existing flows (the branch prefix from Settings is applied on create; both delegate to the shell scripts below).
- **Delete** shows a confirmation with uncommitted/unpushed warnings first.
- Theme follows the system automatically. Settings has a **Start at Login** toggle and Quit.

The panel's visual rules — one container level, colour reserved for what isn't fine, three type sizes — and the design tokens every view draws from are in [DESIGN.md](DESIGN.md). Read it before adding UI.

Everything repo-specific is a setting (see [Config](#config)); the constants that aren't — poll interval, the conflict-resolution command, `gh` lookup paths — live in `macos/Sources/WorktreeManager/Models.swift` and need a rebuild.

### Tests

```bash
make test                            # 61 tests, ~1s
make test FILTER=PanelRenderTests    # one suite
cd macos && swift test               # the same thing
```

Standard SwiftPM: `macos/Tests/WorktreeManagerTests/`, written with [swift-testing](https://github.com/swiftlang/swift-testing) (`@Suite` / `@Test` / `#expect`). Swift Testing ships in the Swift 6 toolchain, but not usably without Xcode — Command Line Tools include `Testing.framework` without the `_TestingInternals` module it is built from, and no XCTest at all — so it comes in as a pinned package dependency instead (see the note in `macos/Package.swift`). Test target only; the app links nothing extra. SwiftPM resolves it for any build, so the first build after a fresh clone needs network; `macos/Package.resolved` pins the version. Once Xcode is installed, delete the dependency — no source change needed.

No repo, no `gh`, no network: everything runs off fake data in `macos/Sources/WorktreeManager/SampleData.swift` (which also feeds `--render --demo`).

**The seam.** Everything below `Store` that touches git, GitHub, the disk or another app goes through a protocol in `Repositories.swift` — `WorktreeRepository`, `PullRequestRepository`, `PRSnapshotStore`, `AvatarLoading`. The app injects the live implementations (which forward to `GitService` / `GitHubService`); tests inject the fakes in `Tests/WorktreeManagerTests/Fakes.swift`, which record what was asked of them and mutate their own state, so the refresh that follows a delete sees the branch gone. Whether cmux is installed rides in the SwiftUI environment for the same reason: a render test gets the same row on any machine.

**The suites.**

| | |
|---|---|
| Row vocabulary | which glyph a row shows and — mostly — which it doesn't. The decision lives in `RowStatus.swift`, apart from the view that draws it |
| Stack tree | branches → stacks → rows: PR bases beating the commit graph, ghosts holding a chain together, merged detection, forks and drill-in |
| Store | what the buttons do, asserted on the calls the fake repository recorded |
| Panel render | the [DESIGN.md](DESIGN.md) rules against real pixels — is a branch one line tall, is there any warm colour on a healthy stack, did the PR number keep its column |

The render tests are not golden images. Reference PNGs go stale on every OS font change and only ever tell you "something moved"; these render a view with `ImageRenderer` and ask the questions the design actually cares about, so they say the same thing on any machine.

### Verifying without the GUI

A menu bar dropdown can't be screenshotted without accessibility access, so the binary has debug hooks:

```bash
.build/release/WorktreeManager --stacks            # print the tree as the menu groups it
.build/release/WorktreeManager --stacks-selftest   # same, on a synthetic branching stack
.build/release/WorktreeManager --render out.png    # render the whole panel to a PNG
.build/release/WorktreeManager --render out.png --dark    # ...in dark appearance
.build/release/WorktreeManager --render out.png --demo    # ...from fake data (no repo or gh needed)
.build/release/WorktreeManager --render out.png --forks   # ...with a forked stack
.build/release/WorktreeManager --render out.png --expand-first  # ...with a row opened
.build/release/WorktreeManager --render-settings out.png  # render the settings window
.build/release/WorktreeManager --list             # flat worktree list
.build/release/WorktreeManager --open-cmux <path>            # focus-or-open a cmux tab there
.build/release/WorktreeManager --resolve-conflicts <path> ['cmd']
                                                  # fire the resolve command in a cmux tab
                                                  # (optional 2nd arg overrides the command,
                                                  #  handy for testing with `echo hi`)
```
## What the operations do
These are the same whether they are run from the menu bar app or from the shell scripts below.

Below, `<prefix>` is the branch prefix from Settings (empty unless you set one), `<main>` the main branch, and `<worktrees>` the worktree folder.

- **Create** — you type the part after the prefix. Runs `git fetch origin` then creates a new branch off the latest `origin/<main>`, in `<worktrees>/<prefix>+<name>` (slashes in the name become `+`). **Stack on** does the same but bases the new worktree on **that row's branch** instead of the trunk (no fetch — it branches off the local tip).

- **Add existing** — paste an existing branch name (local, or `origin/<name>` — the `origin/` prefix is optional). Runs `git fetch origin` then adds a worktree checking out that branch, creating a local tracking branch if it's only on origin, in `<worktrees>/<branch-with-slashes-as-+>`.

- **Open** — launches the worktree in the editor Settings names (`open -a "<editor>"`), or in whichever terminal it names.

- **Delete** — removes the worktree folder **and** deletes the branch. Warns first if the branch has uncommitted changes or unpushed commits, and if a ship run folder (`~/tmp/ship/<slug>`) exists for the branch — that folder is left behind to prune manually; tracker tickets are never touched.

- **Pull `<main>`** — fetches the main branch then merges `origin/<main>` into the worktree's branch. If the merge conflicts it is left in progress, so you can resolve it in your editor (or `git merge --abort`), and the row turns red with a **Resolve** chip until it is.

## Create from a script / Claude skill
The create logic lives in a standalone shell script — the app just shells out to it — so you can invoke it directly:

```bash
./create-worktree.sh my-feature          # off the latest origin/<main>
./create-worktree.sh my-fix other-branch # off an existing branch
```

This creates branch `<prefix>my-feature` off the latest `origin/<main>` in `<worktrees>/<prefix>+my-feature` and copies the files listed in `copy-on-create.txt`. An optional second argument sets the base ref (`git fetch` runs only when it's an `origin/...` ref). It exits `0` on success and non-zero on failure (with an error on stderr), so it's easy to call from a Claude skill or any automation.

Run from a terminal, the scripts read the settings from `~/.config/worktree-manager/config` (written by the Settings window); exported `WORKTREE_MANAGER_*` variables override it. See `config.sh`, which they all source.

Both scripts end by running `agent-artifacts.sh <branch>`, which prints the agent-system artifacts tied to the branch when they exist — `tracker:` (+ `spec:`) for a matching feature on the local-markdown issue tracker under `~/tmp/<repo>-agents/scratch/`, and `ship-run:` for a ship skill run directory. Branch segments are matched last-first (`alex/fixed-focus/tab-frame` checks `tab-frame`, then `fixed-focus`). A Claude session creating a worktree from these scripts sees the ticket path in the output and can pick the spec up directly.

To add a worktree for a branch that **already exists** instead, use its sibling:

```bash
./add-existing-worktree.sh feature/my-branch
```

Same fetch + copy behavior, but it checks out the existing branch (local, or on origin) rather than creating a new one.
## Files copied into each new worktree
`copy-on-create.txt` is a gitignore-style list (one path per line, relative to the repository root, `#` comments allowed) of gitignored local files that a fresh checkout won't include but a build needs — an SDK path, a local env file, editor settings. Edits take effect on the next create — no restart.

## Config
Everything about *which* repo is managed lives in the app's **Settings** window, not in source:

| Setting | Shell variable | Default |
|---|---|---|
| Repository | `WORKTREE_MANAGER_REPO` | — (required) |
| Worktree folder | `WORKTREE_MANAGER_WORKTREE_DIR` | a `worktrees` folder beside the repo |
| Main branch | `WORKTREE_MANAGER_MAIN_BRANCH` | `main` |
| Branch prefix | `WORKTREE_MANAGER_BRANCH_PREFIX` | none |
| Terminal / Editor | — | the first installed one it knows |

Settings writes them to `~/.config/worktree-manager/config` for the shell scripts, and passes them as environment variables when it runs one itself — so an app that has just been reconfigured and a terminal always agree. The binary reads those same variables ahead of its stored settings, which is what makes the debug hooks work outside the `.app` bundle:

```bash
WORKTREE_MANAGER_REPO=~/code/my-repo .build/release/WorktreeManager --stacks
```

The rest are constants in `macos/Sources/WorktreeManager/Models.swift` — `Config.prPollInterval`, `Config.resolveConflictsCommand`, `Config.shipRunsDir`, the `gh` lookup paths — and need a rebuild.

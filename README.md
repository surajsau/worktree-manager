# Worktree Manager
A tiny local tool to create, delete, and open git worktrees for **abema-androidtv** — without touching the main checkout (which stays on `main`).

Two frontends over the same git logic and shell scripts:

- **macOS menu bar app** (`macos/`) — native SwiftUI dropdown with a GitHub PR **stack view**. The recommended way to use it.
  
- **Web app** (`server.js` + `index.html`) — the original zero-dependency Node server. Still the flat folder view; it has no PR/stack support.
  
## Menu bar app (macOS)
```bash
macos/build-app.sh
open macos/WorktreeManager.app
```

Builds with Xcode Command Line Tools only (Swift 6 / macOS 14+, no Xcode needed). A ⎇ branch icon appears in the status bar; clicking it opens the **stack view**.

### Stack view

The dropdown is organised by PR stack, not by folder. Each card is one chain of branches sitting on a trunk (`main`, `minor`, …), named after the branch at the bottom — the one that merges first.

```
▾ ▤ load-previous-mugen  episode-list          ↓90  6 → main  ❗
  ● load-previous-mugen        #18531 ↗  💬 (avatar) 3
  ● page-cursor                #18567 ↗
  ● overlay-pagination-wiring  #18568 ↗  draft
  ● anchored-episode-group     #18572 ↗  draft
  ● anchored-series            #18577 ↗  draft
  ● linear                     #18532 ↗  draft          ← red dot: CI failing
```

**How the tree is built.** A PR's base branch wins whenever a PR exists — that is what GitHub will actually merge into, and it survives rebases that break commit ancestry. Branches with no PR get a parent inferred from the commit graph (the nearest branch whose tip they already contain). PRs whose branch isn't checked out locally still appear, dimmed and marked `no worktree`: without them a chain like `#18579 → #18580 → #18581` would break in two the moment the middle worktree is removed.

**Forks.** The mainline renders flat however deep it goes — an 8-PR stack indented 8 times leaves no room for a branch name. A branch that forks off the chain gets one level of indent under a `↳ branched off <parent>` label, which names the fork point instead of making you infer it. A fork inside a fork becomes a **N more branches below** button that opens that subtree on its own.

**What the colours mean** (also listed under Legend in Settings):

| | |
|---|---|
| Dot | **CI only** — green passing, yellow running, red failing, hollow = no PR |
| Branch name | local working tree — normal clean, amber uncommitted changes, red merge conflict in progress |
| ⚠ `conflicts` | the PR conflicts with its base branch |
| 💬 + avatars | unresolved review threads, by author — round avatar is a person, square is a bot |
| ✓ / ✗ seal | approved / changes requested |
| `#18581 ↗` | click to open the PR in your browser |

The comment indicator is deliberately quiet: four bots comment on every PR here, so it only appears for **unresolved review threads** (whoever opened them) or comments from a human other than you. A bare comment count lit up all 22 rows and said nothing.

**Rows.** Hovering reveals copy-path, open-in-terminal, open-in-Android-Studio, and a **⋯** that opens the PR title, diff size, **Pull main** (disabled when already up to date), **Stack on** (new worktree branched off this one), and **Delete**. A `no worktree` row instead offers **+** to check that branch out.

**Merged.** Branches with no commits outside `origin/main` are collected into a **Merged** section with a one-click **Prune** that removes the worktrees and branches, skipping any with uncommitted or unpushed work.

### Refresh

Git state is local and re-read every time the dropdown opens (~0.5s). PR data needs one `gh api graphql` query covering every open PR (~3s), so it is cached to disk and refreshed on a 30-minute poll; the header shows its age. The refresh button also runs `git fetch origin main`, which is what keeps merged-branch detection honest — a stale `origin/main` under-reports merges. Turn the poll off in Settings to fetch only on demand.

Needs `gh` installed and logged in (`brew install gh && gh auth login`). Without it the view degrades to a plain git tree and says why in a footer bar.

### Other

- **New** / **Add Existing…** buttons in the footer open the create and add-existing flows (fixed `suraj/` prefix on create; both delegate to the shell scripts below).
- **Delete** shows a confirmation with uncommitted/unpushed warnings first.
- Theme follows the system automatically. Settings has a **Start at Login** toggle and Quit.

Config constants (repo path, branch prefix, trunk ref, poll interval, script locations) live in `macos/Sources/WorktreeManager/Models.swift`; rebuild after changing them.

### Verifying without the GUI

A menu bar dropdown can't be screenshotted without accessibility access, so the binary has debug hooks:

```bash
.build/release/WorktreeManager --stacks            # print the tree as the menu groups it
.build/release/WorktreeManager --stacks-selftest   # same, on a synthetic branching stack
.build/release/WorktreeManager --render out.png    # render the stack list to a PNG
.build/release/WorktreeManager --render out.png --forks   # ...with a forked stack
.build/release/WorktreeManager --list             # flat worktree list
```
## Web app
```bash
node server.js
```

Then open [**http://localhost:4180**](http://localhost:4180). Stop it with `Ctrl+C`.

Zero dependencies — just Node's built-in modules. Nothing to `npm install`. Idle CPU is ~0%; the page never auto-polls, so use the **Refresh** button to re-read state.
## What it does
- **Create** — modal with a fixed `suraj/` prefix; you type the rest. Runs `git fetch origin` then creates a new branch off the latest `origin/main`, in `~/Documents/Github/worktrees/suraj+<name>` (slashes in the name become `+`). Each row also has a branch button that opens the same modal but bases the new worktree on **that row's branch** instead of `origin/main` (no fetch — it branches off the local tip).
  
- **Add existing** — modal where you paste an existing branch name (local, or `origin/<name>` — the `origin/` prefix is optional). Runs `git fetch origin` then adds a worktree checking out that branch (creating a local tracking branch if it's only on origin), in `~/Documents/Github/worktrees/<branch-with-slashes-as-+>`.
  
- **Open** — launches the worktree in Android Studio (`open -a "Android Studio"`).
  
- **Delete** — removes the worktree folder **and** deletes the branch. Warns first if the branch has uncommitted changes or unpushed commits, and if a ship run folder (`~/tmp/ship/<slug>`) exists for the branch — that folder is left behind to prune manually; tracker tickets are never touched.
  
- **Pull latest** — rows that are behind `origin/main` get a pull button: it runs `git fetch origin main` then merges `origin/main` into the worktree's branch. If the merge conflicts, it's left in progress so you can resolve it in Android Studio (or `git merge --abort`), and the row shows a ⚠️ **merge conflict** pill until it's resolved.
  
- **Rows** show a clean/dirty dot plus ahead/behind vs `origin/main`, and a ⚠️ warning if a merge conflict is unresolved. A 🎫 **ticket** pill appears when the branch matches a feature on the local-markdown issue tracker (`~/tmp/abema-androidtv-agents/scratch/<feature>/`); hover it for the path. (Web app only — the menu bar app's row anatomy is described under [Stack view](#stack-view).)
  
- **Theme** — dark by default; toggle in the header, choice remembered.
  
## Create from a script / Claude skill
The create logic lives in a standalone shell script — the web server just shells out to it — so you can invoke it directly:

```bash
./create-worktree.sh my-feature            # off the latest origin/main
./create-worktree.sh my-fix suraj/other    # off an existing branch
```

This creates branch `suraj/my-feature` off the latest `origin/main` in `~/Documents/Github/worktrees/suraj+my-feature` and copies the files listed in `copy-on-create.txt`. An optional second argument sets the base ref (`git fetch` runs only when it's an `origin/...` ref). It exits `0` on success and non-zero on failure (with an error on stderr), so it's easy to call from a Claude skill or any automation.

Both scripts end by running `agent-artifacts.sh <branch>`, which prints the agent-system artifacts tied to the branch when they exist — `tracker:` (+ `spec:`) for a matching feature on the local-markdown issue tracker, and `ship-run:` for a ship skill run directory. Branch segments are matched last-first (`suraj/fixed-focus/tab-frame` checks `tab-frame`, then `fixed-focus`). A Claude session creating a worktree from these scripts sees the ticket path in the output and can pick the spec up directly.

To add a worktree for a branch that **already exists** instead, use its sibling:

```bash
./add-existing-worktree.sh suraj/my-feature
```

Same fetch + copy behavior, but it checks out the existing branch (local, or on origin) rather than creating a new one.
## Files copied into each new worktree
`copy-on-create.txt` is a gitignore-style list (one path per line, relative to the main repo, `#` comments allowed) of local files that a fresh checkout won't include. Edits take effect on the next create — no restart. Defaults:

```
local.properties
.claude/settings.local.json
```
## Config
Edit the constants at the top of `server.js` (server/port) and `create-worktree.sh` (create behavior):

- `MAIN_REPO` — path to the abema-androidtv checkout.
  
- `PORT` — server port, defaults to `4180` (`server.js`).
  
- `BRANCH_PREFIX` — defaults to `suraj/` (`create-worktree.sh`).

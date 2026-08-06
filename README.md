# Worktree Manager
A tiny local tool to create, delete, and open git worktrees for **abema-androidtv** — without touching the main checkout (which stays on `main`).

Two frontends over the same git logic and shell scripts:

- **macOS menu bar app** (`macos/`) — native SwiftUI dropdown, the recommended way to use it.
  
- **Web app** (`server.js` + `index.html`) — the original zero-dependency Node server.
  
## Menu bar app (macOS)
```bash
macos/build-app.sh
open macos/WorktreeManager.app
```

Builds with Xcode Command Line Tools only (Swift 6 / macOS 14+, no Xcode needed). A ⎇ branch icon appears in the status bar; clicking it opens the worktree list. Everything the web UI does is in the dropdown:

- Rows show the clean/dirty dot, ahead/behind vs `origin/main`, unpushed count, and a merge-conflict warning. Hovering a row reveals its actions: **pull latest** (only when behind), **new worktree off this branch**, **open in Android Studio**, and **delete**.
  
- **New** / **Add Existing…** buttons in the footer open the same create and add-existing flows (fixed `suraj/` prefix on create; both delegate to the shell scripts below).
  
- **Delete** shows a confirmation with uncommitted/unpushed warnings first.
  
- The list refreshes each time the dropdown opens, plus a manual refresh button — no background polling, so the always-on app stays idle.
  
- Theme follows the system automatically. The gear menu has a **Start at Login** toggle and Quit.
  

Config constants (repo path, branch prefix, script locations) live in `macos/Sources/WorktreeManager/Models.swift`; rebuild after changing them.
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
  
- **Rows** show a clean/dirty dot plus ahead/behind vs `origin/main`, and a ⚠️ warning if a merge conflict is unresolved. A 🎫 **ticket** pill appears when the branch matches a feature on the local-markdown issue tracker (`~/tmp/abema-androidtv-agents/scratch/<feature>/`); hover it for the path.
  
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

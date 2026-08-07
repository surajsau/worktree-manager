# Design

How the macOS menu bar app looks and why. This is the reference for anyone —
human or agent — adding UI to `macos/Sources/WorktreeManager/`. The tokens it
describes live in `DesignSystem.swift`; if you find yourself typing a raw font
size or a hex colour into a view, the answer is in there instead.

## What this thing is

A menu bar dropdown, 420pt wide, that answers one question at a glance: **is
anything in my stacks broken, and what do I do about it?** It is opened for a
few seconds at a time, dozens of times a day. It is not an IDE panel and not a
dashboard — density is worth having, but never at the cost of the glance.

The panel is a floating system surface. macOS already gave it a material
background, a shadow and rounded corners. Everything drawn inside it should
behave like it knows that.

## The five rules

### 1. One container level, not three

The panel is a container. Inside it, a stack's rows get **one** soft fill and
**no border**. The stack's title sits *outside* that fill, on the panel — the
same relationship System Settings has between a section heading and its group.

A bordered, filled card *inside* a floating panel reads as a box inside a box,
and eight of them stacked read as a wall. Borders are the first thing to cut.

### 2. Colour marks the exceptional

Anything routine is `primary` or `secondary` text on a neutral fill. Colour is
spent only where something is not fine, or where a colour *is* the datum (the
CI dot). Concretely, these earn colour and nothing else does:

| Signal | Colour |
|---|---|
| CI failing / running / passing (the dot) | red / yellow / green |
| Branch with uncommitted changes | amber name, amber `3●` `↑1` marks |
| Branch with a merge conflict in progress | red name |
| PR conflicts with its base | red ⚠ and the red **Resolve** chip |
| Unresolved review threads | orange count + the authors' avatars |
| Approved / changes requested | green / orange seal |
| Attention count, top left | orange, soft-filled |
| The primary action (**New Worktree**) | accent |

Everything else — PR numbers, `Draft`, `No PR`, branch counts, `→ main`,
timestamps — is grey. The old panel coloured the PR number accent-blue on every
row; twenty blue links is a page of links, not a signal.

One accent-coloured control per panel. It is the **New Worktree** button.

### 3. One line per row

A branch is one 24pt line: dot, name, local marks, status, PR number. The
metadata that used to sit on a second line under the name fits on the right of
the same line and halves the height of the list — the whole list now fits where
five stacks used to.

The right edge is a fixed 50pt column holding the PR number, so the numbers form
a column and the click target never moves. Hovering swaps the *status* glyphs
for the row's action buttons; the number stays put, because a link that vanishes
under the pointer is a link you can't click.

Depth beyond that is on demand: `⋯` opens the PR title, diff size and the
destructive actions inline.

### 4. Three type sizes

`Typo.sectionTitle` (12 semibold) · `Typo.row` (12) · `Typo.meta` (11).

That is the whole ramp. A fourth size is a request for a hierarchy this panel
does not have. Numbers that sit in a column get `.monospacedDigit()` rather than
a monospaced face — a monospaced *font* is a fifth typeface in a panel that
should read as one voice.

### 5. Never say it twice

Every stack header used to carry an orange ❗ that meant "something below is
broken" — while the rows below it were already saying so in colour. It is now
shown only when the stack is *collapsed*, where the rows can't speak for
themselves (as a strip of CI dots, one per hidden branch).

Same reasoning: the `↗` on every PR link (the tooltip says it opens a browser),
capsule chips around `draft` and `no worktree` (grey text is already quiet), and
avatars on PRs with nothing unresolved (four bots comment on every PR here — an
avatar row that appears on all 22 rows tells you nothing). Avatars are the
loudest thing a row can carry, so they are spent only on threads waiting for a
human reply.

## Tokens

All in `DesignSystem.swift`.

```
Metrics.gutter      12    panel inset — title, section titles and groups line up on it
Metrics.rowHeight   24    one branch
Metrics.rail        16    the stack graph gutter (line + dot)
Metrics.dot          7
Metrics.prColumn    50    right-aligned PR number column
Metrics.groupRadius  8    the row group
Metrics.rowRadius    6    hover highlight, icon buttons
Metrics.sectionGap  10    between stacks
Metrics.maxListHeight 520 past this the list scrolls
```

```
StackStyle.rail       primary 15%   graph lines
StackStyle.groupFill  primary  4%   the one container fill
StackStyle.rowHover   primary  7%   hover / expanded row
StackStyle.dirty      amber         uncommitted + unpushed
StackStyle.ciPending  yellow        CI running
StackStyle.attention  orange        needs a human
```

Fills are opacity-on-`primary`, so the same numbers work in both appearances.
That is exactly why both have to be checked — see below.

## Anatomy

```
┌ Stacks  ⑦                              PRs 5m ago  ⌸  ↻ ┐   PanelHeader
├─────────────────────────────────────────────────────────┤
│  ⌄ preview  enable-device-flag           ↓117  4 → main │   SectionHeader (on the panel)
│ ┌─────────────────────────────────────────────────────┐ │
│ │ ● enable-device-flag                    🅐 1  #18565 │ │   NodeRow, one line
│ │ ● spot-card-presenter               ✓  🅑 2  #18566 │ │   ← group fill, no border
│ │ ● memory-mamangement                    Draft #18576│ │
│ │ ○ coordinator-rewrite                          No PR│ │
│ └─────────────────────────────────────────────────────┘ │
│  ⌄ shared-player  screen-restart-tests        3 → main  │
│ …                                                       │
├─────────────────────────────────────────────────────────┤
│ [+ New Worktree]  Add Existing…                       ⚙ │   PanelFooter
└─────────────────────────────────────────────────────────┘
```

**Row, left to right:** CI dot (colour = CI, nothing else) · branch name
(colour = local working tree) · `3●` `↑1` local marks · **Resolve** chip when
conflicted — never hover-gated, because a conflict blocks everything stacked
above it · then, on the right, either the PR status glyphs or (on hover) the
row actions · then the PR number column.

**Forks.** The mainline renders flat however deep it goes; a fork gets one
indent under an `↳ off <parent>` label, and a fork inside a fork becomes a
drill-in. Eight levels of indent leave no room for a branch name at 420pt.

## Verifying a change

Two things: look at it, and run the tests.

The dropdown can't be screenshotted without accessibility access, so the app
renders itself. **Look at the render before calling a UI change done.**

```bash
make render                                                       # both appearances, fake data
.build/release/WorktreeManager --render /tmp/panel.png            # light, real data
.build/release/WorktreeManager --render /tmp/dark.png  --dark     # dark
.build/release/WorktreeManager --render /tmp/demo.png  --demo     # fake data — no repo or gh needed
.build/release/WorktreeManager --render /tmp/open.png  --expand-first
.build/release/WorktreeManager --render /tmp/forks.png --forks    # synthetic branching stack
```

`--expand-first` doubles as the hover check: an expanded row shows the same
action buttons hovering does.

Both appearances, every time. The fills are opacity-based and a fill that reads
as a gentle grey on white can read as a light-leak on near-black.

```bash
make test                          # the whole suite
make test FILTER=PanelRenderTests  # one suite
```

The rules on this page are also assertions. `Tests/WorktreeManagerTests/PanelRenderTests.swift`
renders views from fake data and asks the pixels: is a branch one line tall, is
there any warm colour on a healthy stack, did the PR number keep its column
under a 60-character branch name. `RowStatusTests.swift` covers the row
vocabulary — which glyph appears, and which one stays away. See
[README § Tests](README.md#tests) for the setup.

**If you change a rule here, change its test.** A render test that reads the
same token the layout reads will follow the layout anywhere, including
backwards — the row-height test measures two renders and subtracts, rather than
asking `Metrics.rowHeight` what it thinks.

## Adding UI

- Take the size, inset and colour from `DesignSystem.swift`. If the token you
  want isn't there, add it there — not in the view.
- Ask what the new element is *competing with*. A panel where everything is
  emphasised has nothing emphasised.
- Anything that gets a colour also gets a line in the Legend
  (`StackLegend` in `Settings.swift`) and in the table above. The legend and the
  rows drifting apart is how a vocabulary dies.
- Every glyph needs a `.help()`. A tooltip is how a dense row stays learnable
  without printing the explanation on screen forever.
- Decide in `RowStatus`, draw in the view. A row's "should this glyph appear"
  logic lives in `RowStatus.swift`, which is why it can be tested without a
  screenshot — and why the same question can't be answered two ways in two
  views.
- Anything that touches git, GitHub, the disk or another app goes through a
  repository protocol (`Repositories.swift`), so the panel can be rendered and
  tested from `SampleData.swift`. A view that reaches for `GitService` directly
  is a view that can only be checked by hand.

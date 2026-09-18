# Process: how the port's work is tracked

**Decided 2026-09-18 (Ivan).** Planning runs on GitHub: one issue per piece of
work, one board, no other tracker. This is the rulebook for humans and for AI
agents working in this repository; it is adapted from the rulebook of a larger
project of the owner's, cut down to what a one-maintainer port with an outside
collaborator needs.

## The three layers

| Layer | Lives in | Rule |
| --- | --- | --- |
| Findings and decisions of record | `docs/` (`PERF.md`, `SAFETY.md`, `APPS.md`, the README, `adaptation/*/README.md`), the release notes | Unchanged. An issue links the doc section it changes or relies on; it does not replace it. |
| Work items | **GitHub Issues** | One issue per ticket, filed **before** the work starts - including work that is done the same hour, and investigations that end in "nothing to do". The board is the record of what the port went through. |
| The cross-cutting view | **Project board "Surface Duo port"** (project 2) | Columns: Epic, Icebox, Todo, Blocked, In Progress, Done. **Done is a ledger**: a shipped card stays. Closing an issue does not move its card: set the column by hand. |

## Filing an issue

`gh issue create` makes an issue; it does **not** put it on the board. Every
issue is followed by `gh project item-add 2 --owner iverbovoy --url <url>` and
an `item-edit` that sets its column - see the commands at the end. After a
batch, reconcile `gh issue list --state all` against `gh project item-list 2`:
five issues went missing from the board this way on the first day.

### Title

What is wrong or what will be different, in one line a stranger can read on
the board. Start with the module when it helps (`Dock:`, `phoc:`, `Kernel:`),
then the behaviour, not the mechanism: *"Dock: cross to the other panel in a
straight slide, not a dip and rise"*, *"The CPUs sit on powersave with the
screen on"*. Not *"fix crossing"*, not *"cpufreq watchdog"*.

### Labels - all five dimensions where known

- `kind:` dev, bug, config, docs, question, upstream.
- `module:` kernel, dock, shell, keyboard, package, apps, audio, display,
  modem, docs, input, power, release, safety. Two modules when the work
  genuinely spans two.
- `prio:` P1 (the first thing a user meets, or a wrong result), P2 (should
  ship in the next release), P3 (when there is time).
- `complexity:` 1 (one file, no interaction with the rest), 2 (a few files or
  a patched binary rebuilt), 3 (a compositor or kernel patch, a new window
  architecture, anything that needs the device by eye more than once).
- `waiting:` owner, user - **only while genuinely blocked on that person, and
  removed the moment the answer lands**. It feeds the Blocked column.
- `epic` for an umbrella issue; the work is its sub-issues.

### Body

An issue is written so that the work can be done from it without the
conversation that produced it. Sections, in this order, dropping the ones that
are empty:

1. **Why** - what was seen, when, and what it should be like instead. In
   the project's own voice: no quotes of what anybody said in conversation,
   no "the owner wants" - an issue states the problem and the goal as facts
   of the port, not as a transcript. For a bug: what happens, and the
   evidence (a journal excerpt, a screenshot, numbers).
2. **Root cause** - for a bug, once known. When there are several parts, a
   table: what is seen, what reads it, why it is wrong, what it should read.
3. **Now / After** - the behaviour before and the behaviour after, as a user
   sees it. A table when more than one surface changes.
4. **Where** - the files, functions and, where it helps, the line
   neighbourhoods that change; the binaries that have to be rebuilt; the
   package steps (build.sh, postinst) that carry it.
5. **Traps** - what the change interacts with: the lock screen, the outside
   user's unpatched phosh, the governor, the version lock on patched
   binaries, a screenshot that has to be retaken. Everything the reporter
   knows that the implementer would otherwise find the hard way.
6. **Acceptance** - a checklist that can be ticked on the device. Each line
   is one observable thing: *"Launch Calculator onto the right panel: the
   halves slide left together and stand as one bar; the debug line reports
   16 ms a frame"*.
7. **Verify** - how: the command, the signal (`pkill -USR1 -x sfduo-dock`),
   the screenshot, the debug line, the journal query. And what is **not**
   covered.
8. **Docs** - which sections change (README row, `PERF.md` numbers, the
   release notes draft, `adaptation/*/README.md`).
9. **Related** - issues, upstream links, the docs that hold the finding.

A research issue (`kind:question`) has **Question**, **What is known**,
**How to find out**, **What it unblocks**.

### Assignee

Set when work starts, kept on the closed issue: the assignee is who did it.
A `waiting:*` issue stays unassigned until someone picks it up.

## While the work is on

- The card moves to **In Progress** when the work starts, not when it ends.
- What is learned on the way goes into the issue as comments, dated, in the
  form of the body's sections (a root cause found, a trap met, a number
  measured), so the closing comment can be short.
- Work found on the way gets its own issue, linked from the comment.

## Closing

The closing comment says what shipped and how it was verified: the commit,
the version it is in, the measured result if there is one, what was left out
and where that went. Then the card goes to **Done** by hand. An issue closed
as "not a bug" or "wrong premise" says what the real cause was and links the
issue that has it (#39 → #41).

Release notes are written from the Done column since the last release; an
issue whose closing comment is good enough to paste there was closed well.

## Commits

Every commit that ships an issue names it: `shell: 0.15.4 - the dock crosses
in a straight line (#43)`. The commit message carries the why and the
measurements, as the tree's commits do; the issue links back to the commit in
its closing comment. No attribution trailers.

## For AI agents specifically

- Before starting work, `gh issue list`: the board is the live backlog.
- File the issue first, with the full label set, on the board, in the column
  that is true. Do the work. Comment what was learned. Close with the
  closing comment. Move the card.
- Nothing private in an issue: no outside users' names, no serial numbers,
  no addresses. The outside collaborator is "the first outside user".
- Nothing conversational either: do not quote the maintainer or anyone else,
  do not refer to "the owner" - write what is wrong and what is wanted as
  the project's own statement. A date ("found in testing on 2026-09-18")
  is the provenance an issue needs.
- Numbers in an issue were measured with the screen on and the governor
  read first (`docs/PERF.md`, "The texture upload, measured twice").

## The commands

```
gh issue create -R iverbovoy/surfaceduo-droidian --title "..." \
    --label kind:dev --label module:dock --label prio:P2 --label complexity:2 --body-file body.md
gh project item-add 2 --owner iverbovoy --url <issue url> --format json --jq .id
gh project item-edit --project-id PVT_kwHOCKU9Dc4Bj6A_ --id <item id> \
    --field-id PVTSSF_lAHOCKU9Dc4Bj6A_zhiso68 --single-select-option-id <column>
```

Column option ids: Epic `cade199d`, Icebox `24a80b54`, Todo `f9145f08`,
Blocked `9d0bc2f8`, In Progress `53bf48d9`, Done `4f1bc826`.

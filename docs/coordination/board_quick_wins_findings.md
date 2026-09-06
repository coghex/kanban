# Board quick wins findings

Small improvements to the visual Kanban board, prioritizing correctness bugs before interaction changes and optional features.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]` deliberately not filed · `[deferred]` awaiting a concrete precondition.

## Methodology

Reviewed commit `c89bc0be7040ca8e9294f2a162154450837b580d` on September 5, 2026. Inspected card rendering, details, search, filters, settings, issue templates, tests, and governing design documents.

Compiled temporary probes against the production Haskell library and existing rendering helpers. Eight checks reproduced the behaviors described below. Probe source and output are retained locally under `/tmp/kanban-quickwins-20260905/`. No implementation changes or GitHub mutations were made.

The earlier `project_audit_findings.md` covers separate rendering-performance and coordinator findings. Existing text-selection work is also excluded. GitHub duplication checks remain for `process-report`.

Effort estimates are relative and preliminary.

## Status

- [ ] BQ-1. Card excerpts display template headings instead of descriptions
- [ ] BQ-2. Filtering hides known PR relationships from issue details
- [ ] BQ-3. Search misses canonically equivalent Unicode text
- [ ] BQ-4. Focused search reserves ordinary letters as commands
- [ ] BQ-5. Filtering unfinished children increases displayed epic completion
- [ ] BQ-6. Open the selected card in a browser
- [ ] BQ-7. Switch card density without restarting

## Small correctness bugs

### BQ-1. Card excerpts display template headings instead of descriptions

**Priority: first. Estimated effort: easy.**

Standard issue bodies can produce cards whose entire preview is `## Background`. A leading HTML comment can similarly replace useful descriptive text.

**Evidence:**

- `src/Kanban/Text.hs:17` selects the first nonempty paragraph without recognizing Markdown headings or comments.
- `src/Kanban/UI/Board.hs:956` uses that excerpt directly in card rendering.
- `.github/ISSUE_TEMPLATE/issue.md` contains a leading instructional comment and the standard Background heading.
- `docs/design.md:1450` requires the first meaningful paragraph.
- Rendering a body beginning `## Background\n\nThe board loses useful context...` displayed only `## Background`. A separate probe returned an origin comment as the excerpt.

**Handoff context:** Select useful descriptive content through common heading/comment prefixes while preserving terminal sanitization and existing line limits. Keep the full body available in details. Cover heading-first, comment-first, ordinary prose, and empty bodies. Treatment of lists and code-first bodies needs a small explicit policy; a complete Markdown renderer is unnecessary.

### BQ-2. Filtering hides known PR relationships from issue details

**Priority: second. Estimated effort: easy–medium.**

An issue’s details can claim it has no linked PRs merely because PR cards are filtered out.

**Evidence:**

- `src/Kanban/UI/Details.hs:44` supplies `appVisibleBoard` to the details renderer.
- `src/Kanban/UI/Details.hs:191` discovers reverse PR links by scanning that board.
- `docs/design.md:1504` requires linked issues or pull requests in details.
- With the standard fixture, issue #812 initially lists PR #823. Unchecking the PR kind filter changes the same details section to `none`, although the retained snapshot still contains the relationship.

**Handoff context:** Resolve known relationships from the retained dataset independently of card visibility. Preserve the visible board’s role in tracker presentation. Test relationship display with PR filters applied, and define how available completed history contributes. Existing data truncation limits still apply; this does not require fetching additional GitHub data.

### BQ-3. Search misses canonically equivalent Unicode text

**Priority: third. Estimated effort: easy.**

Visually identical accented text can fail to match because the query and displayed title use different Unicode representations.

**Evidence:**

- `src/Kanban/UI/Search.hs:108` normalizes whitespace and case, but not Unicode composition.
- `src/Kanban/Text.hs:13` normalizes displayed external text to NFC.
- Searching for precomposed `café` matched `#123 café`; searching with `cafe` followed by combining acute accent did not.

**Handoff context:** Normalize both sides consistently for canonical equivalence. Preserve existing case-insensitive substring matching and its title/number scope. This proposal does not imply accent-insensitive search: `cafe` need not match `café`. Add composed/decomposed examples in both directions.

## Interaction design changes

### BQ-4. Focused search reserves ordinary letters as commands

**Priority: after correctness fixes. Estimated effort: easy–medium.**

Typing lowercase `s` closes search, lowercase `q` reaches guarded dashboard quit, and uppercase `F` moves focus to filters. Ordinary search terms therefore require knowledge of command exceptions.

**Evidence:**

- `src/Kanban/UI/Search.hs:438` explicitly reserves those three printable characters.
- Probes confirmed those mappings and that uppercase `S`/`Q` and lowercase `f` insert text.
- `docs/issue_search_design.md:308` records explicit prior approval of `s` toggling search and `q` remaining quit.

**Handoff context:** This is a proposed revision of an intentional design, not an implementation defect. Consider allowing every printable letter while the search field owns keyboard focus, with Escape closing search and dedicated commands handling quit and filter focus. Case-swapping currently provides a workaround because matching ignores case.

Any accepted change must update the governing contract, help text, and input-routing tests together. The key policy requires a fresh design decision.

### BQ-5. Filtering unfinished children increases displayed epic completion

**Priority: after correctness fixes. Estimated effort: medium.**

Hiding an unfinished checklist child can make its epic appear fully complete.

**Evidence:**

- `src/Kanban/Filter.hs:320` intentionally treats filtered-out children like off-board children.
- `src/Kanban/Workflow.hs:182` adds hidden unfinished checklist children to `trackerCompleted`; native membership preserves GitHub’s summary instead.
- A fixture epic changed from `1/2` to `2/2` when its unfinished child received a blocked label and the Problems filter was unchecked. The child remained open in the source snapshot.

**Handoff context:** This follows current documented behavior. Consider retaining factual completion independently of visibility, optionally displaying a hidden-child count. Keep existing card filtering and grouping intact.

Separate user-hidden children from unavailable references before choosing new semantics; changing the shared pruning function indiscriminately could alter unrelated behavior. Cover checklist and native trackers, plus children distributed across columns.

## Small optional features

### BQ-6. Open the selected card in a browser

**Priority: optional quick feature. Estimated effort: easy–medium.**

The details overlay displays a GitHub URL, but there is no board action to open the selected issue or PR directly.

**Evidence:**

- `src/Kanban/UI/Keys.hs:118` declares board actions without a browser-opening action.
- `src/Kanban/UI/Details.hs` displays the item URL as text.
- `docs/design.md:4388` explicitly defers a local `gh issue view --web` / `gh pr view --web` action.

**Handoff context:** Promote this existing deferred feature into a bounded action available from the board and details. Bind it to the selected item’s repository and kind, preserve selection, and report launch failure without blocking the UI.

Decide the key binding and local-versus-remote terminal behavior. Validate arguments through a fake executable. Clipboard transport remains covered by the existing text-selection design.

### BQ-7. Switch card density without restarting

**Priority: optional quick feature. Estimated effort: easy–medium.**

A live compact view would let the user scan more cards, then restore descriptive previews when useful.

**Evidence:**

- `config.toml.example:65` already exposes `excerpt_lines = 3`.
- `src/Kanban/UI/Board.hs:949` derives excerpt height from resolved configuration.
- `src/Kanban/Settings.hs:31` stores chat verbosity; the settings overlay and board actions provide no card-density control.

**Handoff context:** Add a runtime choice between hidden excerpts and the configured excerpt height. Preserve titles, labels, metadata, status, and full details content. Retain selected-item identity and keep it visible when card heights change.

Keeping the preference for the current process would bound the initial scope; persistence is a separate decision. This improves information density but does not resolve the earlier audit’s offscreen-rendering performance finding.

# Rejected: removing publication from process-report

An unattributed working-tree rewrite of
`claude-plugin/plugins/kanban/commands/process-report.md` proposed that the
workflow stop publishing entirely — no publication helper, no per-document
lock, no tracker transaction. Section 6 became "Leave the mutation in the docs
worktree": create the tracker item, edit the report under `$DOCS_WT`, leave it
uncommitted for the owner to batch through `/push-docs`.

It was reverted unlanded on 2026-08-23. This note preserves the argument,
because the argument is sound even though the change could not land.

## Why it was reverted

**It reddened the suite.** The same four contract modules report zero failures
on a clean checkout and 99 with the rewrite applied:

| count | assertion |
|---|---|
| 35 | `test_removing_a_transaction_clause_from_an_asset_is_reported` |
| 23 | `test_removing_a_publication_clause_from_an_asset_is_reported` |
| 15 | `test_removing_an_ownership_clause_from_an_asset_is_reported` |
| 6 | `test_every_processing_asset_invokes_the_transaction_module` |

The "removing a clause is reported" families are deliberate tripwires: they
exist so that deleting this machinery cannot pass quietly. The rewrite trips 73
of them. That is the tripwires working, not a test-maintenance chore.

**It was half a change.** Only the Claude asset was edited. The Codex twin
still published, so the two brands would have processed the same report
differently. `note-problem` and `process-design-doc` — both brands — still
drive the same two helpers, and both bundles still ship them, so the bundles
would have asserted two designs at once. The asset is also `pr-atomic` and
version-gated, so it needed a bundle bump and a pull request regardless.

**The mechanism had just proved itself.** On the run that produced this note, a
publication push lost a ref-lock race to an unrelated merge. The tracker
transaction is what proved the issue had been created exactly once and what
bounded the recovery. The rewrite's replacement — create the item, read it
back, then edit the document — keeps no durable record, so a run interrupted in
that same window leaves a tracker item nothing can match to a report.

## Why the argument is still worth keeping

Publishing once per disposition is what caused the race in the first place, and
the root instructions do say the maintainer batches documentation with
`/push-docs` and that an agent never pushes `docs-wip` unasked. The tension is
real. What resolves it today is that §7 `coordination` documents are a carved
-out exception to that rule, which is why these reports may publish directly at
all.

One detail the rewrite stated incorrectly: the root instructions say to leave a
standalone Markdown change **committed** in the docs worktree and unpushed. The
rewrite said to leave it uncommitted.

## What landing it would actually take

Not a working-tree edit. An epic: both brand assets changed together, the
tripwire assertions rewritten to encode the new contract, a decision on whether
the two helper scripts stay in the bundles for `note-problem` and
`process-design-doc`, and `docs/agent-workflow-contract.md` §7 updated to say
how a coordination cursor reaches its branch when no workflow publishes it.

## The reverted diff

```diff
diff --git a/claude-plugin/plugins/kanban/commands/process-report.md b/claude-plugin/plugins/kanban/commands/process-report.md
index eb73f89..d9016c2 100644
--- a/claude-plugin/plugins/kanban/commands/process-report.md
+++ b/claude-plugin/plugins/kanban/commands/process-report.md
@@ -26,8 +26,8 @@ Resolve three values together, and treat every one of them as required:
 
 - `$DOC_REPO` — the owning repository as an explicit `owner/repo` slug. It
   scopes every `gh` command in this workflow.
-- `$DOC_BRANCH` — that repository's default branch, which is the publication
-  target. It is never assumed to be the current checkout's branch.
+- `$DOC_BRANCH` — that repository's default branch. It is never assumed to be
+  the current checkout's branch, and this workflow never writes to it.
 - `$DOC_ROOT` — a validated local checkout of `$DOC_REPO`, under which every
   document read and write resolves. A slug alone names no place to write.
 
@@ -76,10 +76,10 @@ Reading code, tests, or history from another repository as evidence stays
 allowed and is never an ownership signal: where you read something does not
 make that repository the owner.
 
-Repository routing and the publication lane are separate decisions. `$DOC_REPO`
-says where this document and its tracker items belong; whether the document
-then publishes as `coordination` or `pr-atomic` is a later question §7 answers
-about an already-resolved owner, never a substitute for resolving one.
+`$DOC_REPO` says where this document and its tracker items belong. How that
+repository's documentation eventually lands on its default branch is its own
+business and never this workflow's: nothing here publishes, so `$DOC_BRANCH` is
+used only to name the owner's branch when reporting.
 
 ## Where files go
 
@@ -334,203 +334,33 @@ the `/design-epic` command; its slices are filed later through
 
 ## 5. Apply the approved disposition
 
-**Resolve this bundle's own mechanism first.** Both helpers ship with this
-plugin rather than with the repository being worked, so they are resolved
-against this plugin's install location and never against `$DOC_ROOT`:
-
-```bash
-PUBLISH_DOC="${CLAUDE_PLUGIN_ROOT}/scripts/publish_coordination_doc.py"
-TRACKER_TX="${CLAUDE_PLUGIN_ROOT}/scripts/tracker_transaction.py"
-[ -f "$PUBLISH_DOC" ] && [ -f "$TRACKER_TX" ]
-```
-
-Claude Code substitutes `${CLAUDE_PLUGIN_ROOT}` to this plugin's own install
-location regardless of the invoking working directory, which is what lets this
-workflow run in a repository that tracks neither file. The two resolve as one
-unit — each loads the other from beside itself — so a bundle carrying one
-without the other carries neither, and an unresolvable helper stops the run
-here rather than after the first mutation. The lookup rule this follows is
-stated in full with the publication step below.
-
-**First, before any tracker mutation, check for an outstanding publication or
-tracker transaction.**
-
-```bash
-PREFLIGHT="$(python3 "$PUBLISH_DOC" \
-  --repo "$DOC_REPO" --branch "$DOC_BRANCH" --root "$DOCS_WT" \
-  --path "$DOC_RELATIVE_PATH" --check-pending)"
-PREFLIGHT_TIP="$(PREFLIGHT="$PREFLIGHT" python3 -c \
-  'import json, os; print(json.loads(os.environ["PREFLIGHT"])["publication_tip"])')"
-[ -n "$PREFLIGHT_TIP" ]
-```
-
-`$PREFLIGHT_TIP` must be extracted, not assumed: publication refuses to run
-without it, and an empty one is a failure rather than a publication with the
-check quietly switched off.
-
-Keep the `publication_tip` it reports. The document you are about to read and
-re-render is that tip's, and the content you produce is a whole-file image of
-it, so publication must be refused if *this document* changed on the branch
-since — a second run doing the same thing would otherwise drop this one's
-disposition while changing exactly the one path a correct publication changes.
-An advance that left this document alone drops nothing and still publishes, so
-do not pre-empt the check by re-rendering against a fresher tip because the
-branch moved; the helper compares the document's own blob at the two tips and
-names the document when it refuses.
-
-A `"pending"` result means an earlier approved mutation of this document is
-outstanding — its publication, its tracker mutations, or both, and
-`pending_kinds` says which. **Stop here.** Do not create or link a tracker item
-and do not apply this disposition: the helper will refuse to publish a different
-mutation while a publication record stands, and by then the new issue would
-already exist for a disposition the document never receives. Report what the
-record names and the resolution the helper suggests, and let the user decide.
-This check is read-only and takes no lock — it is asked here, before the first
-irreversible step, precisely because asking afterwards is too late.
-
-When `pending_kinds` names `tracker-transaction`, the preflight's
-`tracker_transaction` block is the whole report: the document, the selected
-key, the disposition, the transaction state, the completed steps, the ambiguous
-step if there is one, and the steps that remain. Resume that recorded
-disposition rather than selecting new work. Its confirmed steps are verified
-and never repeated; a `mutation-confirmed` or `publication-pending` record
-offers only the completion of that disposition's document mutation and
-publication; and a missing, mismatched, or conflicting recorded artifact stops
-the run rather than adopting a similarly titled one. Re-present each remaining
-step's exact recorded target and payload and stop for explicit approval before
-executing it — a resuming invocation has no conversation history and no
-in-session approval, and the recorded payload fingerprint bounds what may be
-approved rather than standing in for the approval. Use `prepared_publication_tip`
-only to report how far the branch has moved: the binding this run publishes with
-is the `publication_tip` this preflight just reported, never the recorded one.
-
-An `ambiguous_step` is a mutation that began and was never confirmed. It may
-have landed. Never retry it, adopt a candidate for it, advance past it,
-publish, or clear the record. Verify read-only whether its exact recorded
-postcondition holds, present what you found, and let the user bind it to one
-exact artifact or authorize a retry — one whose repository, target, immutable
-identity or URL, approved payload, and observable postcondition all match what
-was recorded. Absent, mismatched, conflicting, or more than one plausible
-candidate leaves the record unresolved and stops the run. A similarly titled
-artifact is never sufficient evidence.
-
-### Acquire the tracker transaction before the first mutation
-
-Only after explicit approval, and a `"clear"` preflight, acquire the record that
-makes this disposition's tracker mutations recoverable. It is acquired **before
-the first one runs**, because a run that dies afterwards leaves an unchanged
-report, a clear preflight, and issues that already exist:
-
-```bash
-python3 "$TRACKER_TX" \
-  --repo "$DOC_REPO" --root "$DOCS_WT" --path "$DOC_RELATIVE_PATH" \
-  --acquire --approved --publication-tip "$PREFLIGHT_TIP" --plan - <<'PLAN'
-{"entry_key": "<the selected finding key>",
- "disposition": "<the approved disposition kind>",
- "steps": [{"kind": "issue-create",
-            "target": "<the exact approved target>",
-            "payload_fingerprint": "<digest of the approved body>",
-            "postcondition": "<what is observably true once it lands>",
-            "provides_marker": true}]}
-PLAN
-```
-
-Acquisition is create-only and atomic, so two runs that both saw a clear
-preflight cannot both proceed; the loser stops rather than mutating GitHub
-beside the winner. The record is shared across every linked worktree of this
-repository, so a later invocation resolving a different `$DOCS_WT` still sees
-it. `tools/tracker_transaction.py` is the whole mechanism — acquisition, every
-transition, and the resolution check — and it is resolved from this plugin's
-own bundle exactly as the publication helper is. Do not reimplement any part of
-it, and never edit a transaction reference by hand. If
-it cannot be resolved, created, read, or updated, stop before the first
-irreversible action and report that; an unreadable transaction is never read as
-no transaction.
-
-**A disposition that mutates no tracker acquires nothing.** `[no-issue]`,
-`[deferred]`, an **Existing issue with no approved comment**, and `Epic` make no
-tracker mutation here. Linking an issue that already exists is a document
-change, not a tracker one: without an approved comment there is nothing to
-checkpoint, so no transaction is acquired at all rather than an empty one, which
-this module refuses. For `Epic` the arc goes to
-`/design-epic`, and its epic is created later inside `/process-design-doc`'s own
-transaction for the design document — so they plan no steps and leave no
-transaction outstanding. Acquiring one for them would block every later finding
-in this report behind a record nothing could ever clear, and an `Epic`
-disposition's would stay open across a separate human-led drafting workflow.
-
-### Walk the ordered steps
-
-Every approved tracker mutation is its own ordered step. Begin a step before its
-external mutation runs and confirm it with the exact identity that mutation
-returned before the next step starts; that gap is the only window in which a
-mutation can be unaccounted for, and closing it is what this record is for.
-
-```bash
-python3 "$TRACKER_TX" \
-  --repo "$DOC_REPO" --root "$DOCS_WT" --path "$DOC_RELATIVE_PATH" \
-  --begin-step 0 --approved
-# ... run exactly that one approved mutation ...
-python3 "$TRACKER_TX" \
-  --repo "$DOC_REPO" --root "$DOCS_WT" --path "$DOC_RELATIVE_PATH" \
-  --confirm-step 0 --begin-token "$BEGIN_TOKEN" --identity - <<'IDENTITY'
-{"kind": "issue-create", "id": "<number>", "url": "<url>",
- "document_token": "[#<number>]", "postcondition_verified": true}
-IDENTITY
-```
-
-`$BEGIN_TOKEN` is the `begin_token` the `--begin-step` result returned. Keep it
-for exactly this confirmation and pass it back. Only the run that began a step
-may confirm it, and that token is the only evidence of having been it: it is
-returned once and is not readable from the record, so a fresh session cannot
-produce one and must reconcile instead. That is what stops an interrupted
-mutation being adopted through the ordinary confirmation path, which asks for no
-approval and matches no artifact. Losing the token costs a reconciliation, which
-is the safe direction to fail.
-
-An identity is the one its own kind of mutation actually has, and it must agree
-with itself: a created issue or epic records its number, a URL naming that
-number in `$DOC_REPO`, and the `[#N]` token the entry will carry; a label
-records its name and the metadata it was created with, both of which must be the
-exact approved values the plan carries as `approved_name` and
-`approved_metadata`; a comment records its
-comment ID and a URL naming that comment on the approved target in `$DOC_REPO`;
-an edit to an existing artifact records that artifact's identity and the
-verified post-edit fingerprint. Every one of those is bound to what was
-approved rather than merely well-shaped: the URL is parsed as a canonical GitHub
-URL in `$DOC_REPO`, an edit names its approved target, and a literal marker
-names the artifact the disposition links, which the plan states as
-`marker_target`: a linked child issue often has no approved comment, so its one
-tracker mutation is the umbrella epic's checklist edit and there is no step from
-which the link could be inferred. The document carries only `[#N]`, so
-an identity free to name another repository's issue, another epic, or another
-number would let a transaction clear against an artifact this run never
-touched. Nothing but a created issue or epic contributes a token
-the document must name.
-
-Not every step returns an issue number and a URL, and the record does not
-pretend otherwise: an issue records its number and URL, a comment its comment ID
-and URL, and an edit to an existing issue that issue's identity plus the
-verified post-edit fingerprint.
-
-Then, only after explicit approval and a `"clear"` preflight:
-
-- **Child issue creation.** Writing the approved body to a temporary file and
-  creating it with `gh issue create -R "$DOC_REPO" --body-file`, applying only
-  approved existing labels, is a checkpointed step: begin it before that call
-  and confirm it with the number and URL it returned.
+**This workflow never publishes and never lands documentation.** It creates the
+approved tracker item, then applies the report edit in the docs worktree and
+leaves it there, uncommitted, for the owner to land in their own batch. That is
+the repository's own rule: an agent never pushes `docs-wip` and never runs
+`tools/docs_land.sh` unasked. Documentation accumulating uncommitted in that
+worktree is the intended steady state, not a loose end to tidy up.
+
+For the same reason this workflow acquires no publication lock and no tracker
+transaction. Both exist to make a *published* cursor recoverable, and a
+disposition that never publishes can never resolve one — acquiring either would
+strand a record that blocks every later run of this report. Recoverability here
+comes from doing the tracker mutation last-but-one and verifying it immediately:
+create the item, read it back, and only then touch the document.
+
+Then, only after explicit approval:
+
+- **Child issue creation.** Write the approved body to a temporary file and
+  create it with `gh issue create -R "$DOC_REPO" --body-file`, applying only
+  approved existing labels. Immediately read the new issue back and verify its
+  number, title, state, labels, URL and body before touching the document.
 - **Child issue linking.** Linking an issue that already exists mutates nothing
-  by itself. With an approved comment, that comment is the transaction's one
-  step and `marker_target` names the issue being linked; with none, there is no
-  tracker mutation and no transaction. Either way, confirm the target issue
-  still exists.
-- **Approved comment.** Posting an explicitly approved comment on that issue is
-  a checkpointed step: begin it before the comment is posted and confirm it with
-  the comment ID and URL.
-- **Epic:** hand the approved arc to `/design-epic` for capture
-  in a design document, then process its `EPIC` entry through
-  `/process-design-doc` and record the created tracker number. No tracker
-  mutation happens here, so no transaction is acquired.
+  by itself; confirm the target issue still exists.
+- **Approved comment.** Post an explicitly approved comment on that issue, then
+  read it back and verify its comment ID and URL.
+- **Epic:** hand the approved arc to `/design-epic` for capture in a design
+  document, then process its `EPIC` entry through `/process-design-doc` and
+  record the created tracker number.
 - **No issue:** make no external mutation.
 - **Deferred:** make no external mutation.
 
@@ -548,12 +378,11 @@ Then edit only the selected report finding:
   precondition. A run that marks a heading and leaves the checklist stale has
   produced two contradictory answers to the same question.
 - Preserve the finding body and all unrelated changes.
-- Compose the complete updated report as text; do not write it to the file and
-  do not stage it. The publication step below hands that text to the helper,
-  which is the only writer of the document.
+- Write the complete updated report to its path under `$DOCS_WT`. Do NOT stage
+  it, commit it, push it, or land it.
 - Never mark the finding when issue creation or lookup failed.
-- Beyond the publication step below, do not commit, push, or open a PR unless
-  separately requested.
+- Do not commit, push, open a PR, or run `tools/docs_land.sh` — not for this
+  edit and not for anything else already sitting in the worktree.
 
 Verify heading and checklist agree, and that the run changed exactly one finding:
 
@@ -564,186 +393,56 @@ git diff --stat -- "$ARGUMENTS"
 
 For a created or linked issue, also verify its title, state, labels, and URL.
 
-If a tracker mutation succeeds but a later step or the document mutation fails,
-do not create anything else. The durable transaction record is where that state
-lives — never the report, which this workflow does not write and the publication
-helper alone owns. Report the tracker states beside the three document states
-section 6 requires: whether acquisition succeeded, the transaction state, each
-planned step and whether it is planned, ambiguous, or confirmed, every confirmed
-tracker identity, and the one recovery action that is permitted next. Reconcile
-it before the next finding.
+If the tracker mutation succeeds but the document edit fails, do not create
+anything else. Report exactly what exists: the tracker item's number and URL,
+that the report was not updated, and which single edit a later run must apply to
+reconcile them. A tracker item without its report marker is the one state this
+workflow can leave behind, and naming it precisely is what makes it cheap to
+fix.
 
-## 6. Publish the approved mutation
+## 6. Leave the mutation in the docs worktree
 
-Publish the approved mutation in this same run. The document is a durable
-cursor, and a cursor that only ever exists in one checkout is resumable only
-from that checkout. Publication is one more step of the disposition that was
-already approved; it carries no second one, and it is never batched or deferred
-merely to reduce commit or push frequency.
+**Do not publish. Do not commit. Do not push. Do not land.** The edit stays
+uncommitted in `$DOCS_WT` for the owner to batch through `/push-docs` when they
+choose. This is the end of the run, not a step that is merely deferred to later
+in the same session.
 
-When a tracker transaction is open, record that it is being handed to
-publication before you hand it over, so an interruption inside publication is
-distinguishable from one before it:
+That is the repository's own contract, and it exists for two reasons worth
+keeping in view. Landing a doc per disposition floods master CI and makes the PR
+drainer re-check every open PR. And the docs worktree is deliberately the place
+uncommitted documentation accumulates — a pile of modified files there is the
+system working, never a mess to clear.
 
-```bash
-python3 "$TRACKER_TX" \
-  --repo "$DOC_REPO" --root "$DOCS_WT" --path "$DOC_RELATIVE_PATH" \
-  --publication-pending
-```
+So this workflow ships no publication helper, takes no per-document lock, and
+writes through no intermediary. The agent writes the file in `$DOCS_WT` directly,
+and that is the whole mechanism.
 
-**Render the complete approved document and hand it over — do not write it
-yourself.** `tools/publish_coordination_doc.py` is the only writer of the
-document, and that is what keeps an edit somebody else makes beside this run out
-of the published commit: the published bytes come from what you pass, never from
-the working tree. Ask the helper for a scratch path, write the rendered
-document there, and hand it back:
+Two consequences follow, and both are deliberate:
 
-```bash
-APPROVED="$(python3 "$PUBLISH_DOC" \
-  --repo "$DOC_REPO" --root "$DOCS_WT" --path "$DOC_RELATIVE_PATH" \
-  --new-content-file)"
-python3 "$PUBLISH_DOC" \
-  --repo "$DOC_REPO" --branch "$DOC_BRANCH" --root "$DOCS_WT" \
-  --path "$DOC_RELATIVE_PATH" --content "$APPROVED" \
-  --expected-tip "$PREFLIGHT_TIP"
-```
+- **The cursor is local.** A fresh session resumes from the worktree copy, not
+  from the branch. That is fine: `$DOCS_WT` is resolved by branch name at the
+  start of every run, so every run finds the same copy.
+- **The branch may be behind.** `git diff` in the worktree can therefore show
+  far more than this run's two lines, because the worktree's HEAD lags whatever
+  the owner last landed. Verify this run's own change by its content — the
+  finding's heading marker and its checklist line — never by the diff's size.
 
-`$PREFLIGHT_TIP` is the `publication_tip` the preflight reported. Always pass
-it: it is what binds this content to the document state it was rendered from,
-and a `tip-moved` result means re-reading the document and rendering the
-disposition again rather than publishing what you have.
-
-**Never choose that path yourself.** A fixed name collides between any two
-runs, and a name derived from the document collides between two runs of the
-same one; either way a run reads the other's approved content and publishes it
-under its own document's name. The helper mints a path unique to this
-invocation, which is the property no naming convention here can promise.
-
-Resolve the helper from this plugin's own bundle — the versioned copy installed
-beside these instructions — and never from the session's own checkout,
-a personal path, or an inline fallback. `$DOC_ROOT` stays exactly what it was:
-the validated local checkout of the owning repository, which is where the helper
-writes and never where the helper itself is found. These plugins install into
-repositories that track no copy of it, so resolving the helper from the owning
-repository fails closed in every repository but Kanban's own — which is the
-defect that older wording mandated. A helper that cannot be resolved in the
-bundle still fails closed: report that publication was not attempted and why,
-and never publish by hand instead.
-
-The helper owns the entire mechanism — eligibility, the per-document lock, the
-baseline, isolation, the push, verification by reachability, and the resumption
-of an unfinished earlier publication. Eligibility is the one part that is not
-the same question in every repository, and the helper answers it rather than
-you: for `coghex/kanban` it is §7 as the publication branch itself carries it,
-and for every other owner it is that repository's own
-`workflow.coordination_paths` declaration, which is empty until the repository
-sets it. Do not reimplement, precede, or compensate for any part of it. Act
-on the one structured result it returns:
-
-- **`"status": "published"`.** Say so, and quote the commit it reports together
-  with its changed-line summary. Check that summary against the disposition you
-  applied: because the whole document is handed over, an unintended rewrite of
-  the rest of it changes the same single path a correct publication does, and
-  the summary is what makes the difference visible.
-- **`"status": "not-published"`.** The document is not direct-publication
-  eligible — it is `pr-atomic`, matched no §7 row, or belongs to a repository
-  that declares no coordination path for it. The approved mutation is not
-  lost: the helper reports `approved_blob`, recoverable with
-  `git cat-file -p`, and `document_written` says whether it also applied it to
-  the document. `write_outcome` names which of the four cases the write was,
-  rather than leaving `document_written` to stand for all of them:
-  `applied-over-baseline`, `applied-over-local-predecessor`, `no-baseline`, and
-  `unrecognized-working-copy`. A working copy byte-identical to what the helper
-  last applied locally is its own unlanded write, and the approved mutation is
-  applied on top of it — so successive approved mutations to a document its
-  owner lands out of band accumulate rather than wedging on the first one. A
-  working copy the helper did not write is never overwritten, and nothing is
-  applied over it. Say which outcome it was and why publication was declined.
-  This is the ordinary outcome for a `pr-atomic` document, not a failure of
-  this run.
-
-  `applied_record` is the other half of that. The helper records what it wrote
-  in its own reference, and only `"recorded"` — with `applied_ref` naming that
-  reference — lets a later run continue over the working copy or a transaction
-  resolve from it. `"unrecorded"` means the write happened and the record did
-  not, so no later run may write over that document and no transaction may
-  resolve from it. Report that rather than an ordinary applied mutation.
-
-  **An applied mutation is not durable until the document's owner lands it on
-  the publication branch.** It exists in one write root and nowhere else, so
-  name the write root, the document path, and the preserved `approved_blob`
-  rather than describing the run as complete on the branch.
-- **Any other status.** The document was not published. Report the three states
-  the helper returns — whether the edit exists locally and in which worktree and
-  path, whether a local publication commit exists and its ID, and whether the
-  remote publication branch contains it — and say plainly which one applies.
-  Leave the document as the helper left it.
-
-### Resolve the tracker transaction
-
-A tracker transaction is cleared by the published entry itself, never by the
-fact that a commit landed. Reachability proves a commit reached the branch; it
-proves nothing about whether that commit carried this disposition:
+Verify, and report:
 
 ```bash
-python3 "$TRACKER_TX" \
-  --repo "$DOC_REPO" --root "$DOCS_WT" --path "$DOC_RELATIVE_PATH" \
-  --resolve --source branch --branch "$DOC_BRANCH"
+rg -n '<item-key>' "$DOCS_WT/$DOC_RELATIVE_PATH"
+git -C "$DOCS_WT" status --porcelain -- "$DOC_RELATIVE_PATH"
 ```
 
-The module verifies that the recorded entry key's own terminal `- [x]` entry in
-the document's at-a-glance index on `$DOC_BRANCH` carries the recorded
-disposition and every exact tracker identity that disposition requires the
-document to name, and clears the record only then. It looks in that index alone,
-because a checked task in a finding's body, in a fenced example, or nested
-beneath the real entry is not the cursor. An entry still `- [ ]`, an incidental mention in prose, and a
-terminal entry carrying `[no-issue]` or `[deferred]` beside the link are each
-refused: the first is the interrupted run's own signature, the second is not the
-cursor at all, and the third is a different disposition from the recorded one. On a `not-published`
-result whose `applied_record` is `"recorded"` — the ordinary outcome for a
-`pr-atomic`, unmatched, or not-yet-tracked document — run the same verification
-against the applied local document with `--source local --branch
-"$DOC_BRANCH"`, which is the only evidence there is and a legitimate terminal
-state for such a document.
-Whether the working tree is admissible at all is the module's decision, not
-yours. It classifies the document itself and refuses a local resolution for one
-that publishes to the branch, because clearing such a record from a locally
-edited cursor would leave the next preflight clear while the entry never landed.
-It also checks the document against the publication module's own record of what
-that module applied, since classification says only that publication *would* be
-declined — a file somebody edited by hand looks the same from there. A document
-the module never wrote, or one changed since it did, resolves nothing — and a
-write the module could not record is one it can no longer prove it wrote,
-however plainly this run watched itself make it. When `document_written`
-is false, nothing carries the disposition anywhere: the record stays
-outstanding, and this run reports it; an `applied_record` of `"unrecorded"`
-leaves it exactly as outstanding.
-
-**A stranded transaction has a bounded recovery.** Reporting it is not the end
-of the line, and hand-editing a reference is never how it ends. Recover the
-`approved_blob`, land the terminal document through the owner's ordinary
-out-of-band or pull-request lane, and then resolve the record with `--source
-branch`. Never repeat a confirmed tracker mutation and never clear a reference
-by hand while that recovery is pending: the record already carries every
-identity the recovered document must name, and a repeated mutation files a
-second artifact nobody can take back.
-
-A record this run could not resolve stops the next one, which is what it is for.
-Report it rather than clearing it, and never clear a transaction reference by
-hand. Where nothing landed at all, the user may explicitly approve abandoning an
-`intent-only` or `tracker-pending` transaction against authoritative read-only
-evidence that none of its unconfirmed mutations reached GitHub — and this run
-still names every mutation that was already confirmed, because those exist and
-the document never recorded them.
-
-**A recorded publication is resolved before any new disposition.** When the
-helper reports `pending-unresolved` or `pending-differs-from-approved`, an
-earlier approved mutation of this document has not reached the branch. Do not
-apply a second disposition over it and do not create tracker items for one:
-resolve that record first, or the run you just approved will be reported
-published while its mutation is absent from the document.
-
-Publication ends this finding. Do not select another.
+The status must show the file MODIFIED and nothing staged. If it shows the file
+unchanged, the edit did not land and the finding is not dispositioned.
+
+Never run `git add`, `git commit`, `git push`, or `tools/docs_land.sh` here — not
+for this document, and not for the other modified files already in that
+worktree. If the user wants the accumulated documentation landed, that is
+`/push-docs` and they ask for it explicitly.
+
+Applying the edit ends this finding. Do not select another.
 
 Report, in this order: the disposition and its tracker link if any; the report
 line as it now reads; and the work the report still owes as two counts — the
```

# Approved-document recovery design

This is the focused recovery contract for the paused #830 implementation in
PR #836, not a new epic. Its purpose is to replace successive recovery patches
with a state model whose interruption behavior can be reviewed as a whole.

Design state: `exploring`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [no-issue] EPIC. Existing #775 split owns this work; no new umbrella.
- [#830] REC-1. Rework the approved-document helper against this recovery contract.

This ledger links existing work; it grants no permission to resume PR #836.
The separately authorized live-publisher repair is tracked in #845 and routed
by the manager; it is not an additional delivery slice in this design.
There is one existing delivery slice and no new tracker artifact to process.

## Contract and scope

- **Goal:** after any helper-process interruption, preserve the document and
  approved bytes, determine publication only from verified evidence, and resume
  without replaying a mutation that reached the publication branch and was
  subsequently reverted, subject to D-5's explicitly accepted admin-bypass
  boundary.
- **Done when:** the state and interruption tables are implemented and tested,
  all eight review rounds have regression coverage, tracker recovery uses the
  same evidence rules, and each incomplete outcome names the retained state
  and the next safe action.
- **Users and operators:** document-workflow agents and the owner recovering a
  failed run, including consuming repositories without Kanban source files.
- **Arc label:** none proposed; existing #830 under #775.

In scope: the helper's local write protocol, records, external-tool handoff,
landing verification, legacy compatibility, and the tracker-resolution boundary.
No implementation, PR edit, issue edit, or new issue is authorized by this
document. #831 owns consumer migration and publisher deletion; #775 owns the
remaining classification retirement; #824 owns archive transactions.

## Current state and evidence

Reviewed implementation: [PR #836 at 37d9923605bad43a0a31ce7ad40d6ef6eb629a04](https://github.com/coghex/kanban/tree/37d9923605bad43a0a31ce7ad40d6ef6eb629a04).
Live-publisher baseline: master `ff1e9f9dba7a6df389ad8db10f859fdea730c186`.
The open tracker already contains #830 and #831; no matching additional recovery
arc was found in the open-issue inventory on 2026-10-23 UTC.

At the reviewed head, `tools/approved_document.py`:

- Stores a parentless version-1 pending commit under
  `refs/kanban/pending-publication/<key>`, with the approved document in its tree.
  The baseline is an object name in JSON, not a rooted baseline payload.
- Stores applied bytes as a blob ref under `refs/kanban/applied-locally/<key>`.
  Lock, pending, and applied namespaces use the same repository/document digest.
- Captures the working file with `rename_aside`, reads it, then links the
  approved scratch file exclusively at the target. Its aside location is not
  recorded in the pending record.
- Writes landing evidence before cleanup. Saved evidence checks blob and
  receipt identity, but omits the interval check that rediscovery applies.
- Searches `rendered_tip..origin/<default>` without path simplification for
  receipts and exact-blob no-op landings; saved evidence takes precedence.
- Can delete pending intent after an application error when the target does
  not hold the approved blob (`start_fresh`), even when capture recovery failed.
- Treats some unsuccessful Git/file reads as absence. Those distinctions need
  explicit handling wherever absence would license writing or cleanup.

Primary code anchors at that immutable head: `verify_and_write` (588),
`read_pending` (840), `landing` (1031), `revision_carrying` (1109),
`verified_evidence` (1154), `record_landing` (1214), `settle_landed` (1396),
`start_fresh` (1661), and `check_pending` (1902). Tracker logic is in
`recorded_publication_landed` and `local_resolution_permitted` in
`tools/tracker_transaction.py`.

### Confirmed defect in the live publisher

`tools/publish_coordination_doc.py:904–907` sets `captured_ok` only **after**
reading the renamed aside. Its cleanup at 970–979 treats false as proof that
rename never happened, then unlinks the aside. All three shipped source copies
are byte-identical (SHA-256
`558983c4334af04fe5eeff738eea45adbb508f14f3658362eda4fc6a79eae82b`).

A temporary-repository probe imported the live module, created an untracked
document containing `only untracked baseline copy\n`, and injected `OSError`
only when `read_for_write` read the aside after successful rename. It returned
`document-unwritable`; the target was absent, the aside directory contained no
file, and `git cat-file -e <baseline-blob>` failed. This is a reproduced loss,
not merely similarity to the helper. No real document or held worktree was used.

**P-3, approved as D-6:** repair the live publisher separately before #831 removes it.
Deletion later does not protect today's callers. Keep the repair narrowly
focused on preserving/restoring the captured file on every post-rename failure,
including failed reads and restoration, with the regression in all delivered
copies. #830 expressly excludes publisher changes: the owner authorized a
separate fix, filed as #845 and routed by the manager. #830/REC-1's scope stays
unchanged. This design files nothing and changes no code. The broader helper journal below should not be
backported merely to prolong a publisher being retired.

## Decisions already authorized

### D-1. Keep the external publication tool

The owner chose external `docs-push` with `--expect`/`--keep` and
`~/.config/docs-push.json`; never port or bundle its Git engine. The helper
owns approved-content application and recovery, not publication eligibility,
merge, push, or configuration. Source: owner-approved #775 split, repeated in
the assigned design brief and #830 requirements.

### D-2. Pause implementation and review one focused design

The owner's request, relayed by verified `kan-manager` in #kan-backlog,
message `4cahadqqj97dfwar952vsdsm6e`, pauses #836 after round 8. This session
lands this design with `docs-push`, requests manager signoff, and resolves the
manager-arranged opposite-brand design review. No extra worker or subagent.

### D-3. Saved evidence first; full-history fallback only when absent

Verified manager answer `c3dt63s27ktcv6yja2x3rtirpn` chose saved evidence as the
primary path. Verified owner-decision relay `ec8tcakvseqnjsxghps8pynmd6`, clarified
by `xm5n9phjsisd8wejzfc7k6qyk6`, permits complete reachable-history fallback when
no evidence was saved. Both require failure to close the gate when evidence
cannot be verified. They do not authorize ignoring invalid saved evidence.

### D-4. Retain intent and make capture recovery durable

Q-1 is resolved: the manager approved P-1's retained-intent/capture model and
state tables, including the versioned record, rooted payloads, capture locator,
preservation on application failure, and child-quiescence handling.

### D-5. Gate automatic negative-history retries on GitHub branch rules

Q-2 is resolved: the owner approved P-2's shared validator, strict publication
interval and stop rules with this boundary: an automatic negative-history retry
is permitted only when the helper first verifies through the GitHub API that
the publication branch's active rules forbid non-fast-forward pushes. If the
rules do not forbid them, or cannot be read and verified, stop for operator
reconciliation. An assumed append-only convention is insufficient.

F1 clarification from the owner: **rule present is enough**. An active,
applicable `non_fast_forward` rule permits automatic retry even when the
pushing identity can bypass it. Admin bypass is an explicitly accepted residual
risk. The gate reads the rule, not bypass permissions, and does not prove that
the pushing identity cannot force-push. Source: verified manager review reply
`b249chw3p5ydcr5937kx3zu7qa` (2026-10-23), relaying the direct owner decision.

### D-6. Repair the live publisher separately

Q-3 is resolved: the owner authorized a separate live-publisher capture-loss
fix now, before #831 deletes it. The manager filed
[#845](https://github.com/coghex/kanban/issues/845) and routes it separately;
#830/REC-1 remains unchanged in scope.

D-4–D-6 were approved in verified `kan-manager` reply
`y6mj9vvpy3r9gapeapm7zn244w` in #kan-backlog on 2026-10-23 UTC, replying to
draft-signoff question `r4d4zwr4itj3m7q4p7n8j3sm9a` at commit `6f006a1447`.
The reply identifies Q-1 as manager approval and Q-2/Q-3 as direct owner
decisions. The present user instruction also relays those choices. This
signoff approves the contract below. The opposite-brand review of `9d1e0f8680`
was relayed in `b249chw3p5ydcr5937kx3zu7qa`; its five findings are addressed
below. Review acceptance and readiness remain outstanding.

## Approved design, pending review

### P-1 (D-4). One retained intent, with capture recovery inside it

Use one pending record as the durable intent and recovery journal. Keep the
existing namespaces and digest. Avoid a second independent capture journal
whose lifetime would have to be coordinated with the pending record.

A new version-2 record binds repository, branch, normalized relative document
path, attempt ID, write-root identity, baseline blob `B`, approved blob `A`,
rendered tip `R`, optional capture descriptor, optional handoff state, and
optional landing evidence `E`. Its parentless record commit roots the approved
and baseline payloads in its tree; if captured bytes differ from `B`, root those
as well before deleting their file copy. Fixed internal tree entries for these
payloads avoid collisions with the document's user-facing path. JSON object
names alone, reflogs, and unreferenced `hash-object -w` output are not durable
retention. A record commit is local bookkeeping, never a publication commit.

Retain a predecessor's payload tree and a blob containing its raw record
metadata inside the replacement record when migration or a preserved foreign
edit requires it. Merely naming the old commit in JSON or a gitlink does not
root its objects. Do not make it a commit parent. The old publisher must
continue refusing helper records rather than
mistaking one for a commit it can push.

The capture descriptor names an exclusively reserved attempt directory beside
the target, its scratch file and aside file, and the originating worktree.
Persist and read back the descriptor **before** moving the target. After a
crash, inspect those exact locations; a Python flag that would have been set
after rename is not evidence. An empty reservation is harmless. A populated
aside is custody of a real file even if no read or hash ever succeeded.
Do not follow symlinks or accept recovery paths outside the validated root;
unexpected types, changed directories, or inconsistent ownership block recovery.

Before an initial durable record succeeds, the caller's approved-content input
and target remain untouched and owned by the caller. After it succeeds, keep
the intent on every error, even before application. Explicit operator recovery
may abandon an intent only after its content and captured edits have been
accounted for; application failure alone is never permission to delete it.

Use exclusive creation/linking to install or restore files. A restoration must
not overwrite an occupied target. On restoration failure keep the aside and
report its exact path; never fall back to an overwriting rename. A failed or
partial exclusive-copy restoration keeps the aside and reports the partial
target as divergent. Never infer “absent” from permission, stat, object-read,
or I/O failure. Missing files, empty files, and unreadable files are different
states. Preserve mode as well as bytes. A failed hash/ref write is not a
successful preservation.

For an outside edit captured during the swap, preserve that actual capture,
not merely the earlier baseline. If the target remains absent, restore the
capture without replacement; if another writer occupied it, leave the winner
and retain the capture. Stop for reconciliation. Do not delete a distinct
captured edit just because approved content or another file exists at target.

### Durable objects and invariants

| Object | Meaning and invariant |
| --- | --- |
| `P`: pending ref/record | One approved attempt; roots `A`, `B`, any preserved capture and required predecessor. Create absent-only; rewrite/delete by compare-and-swap (CAS) against the observed record. No exception cleanup discards it. |
| `L`: applied ref | Blob the protocol applied locally, never proof of remote publication. Validate type and readability before any replacement or deletion. A different valid predecessor is handled explicitly, not silently discarded. |
| `K`: lock ref | One owner for repository/path across worktrees. Acquire absent-only, release only the acquired value. Unknown/live/foreign owner blocks mutation. A dead helper alone does not prove its publication child has stopped; child identity includes PID, process start time and exact argv. |
| Approved input | Complete caller-approved bytes. Caller retains the input until `P` is verified durable. Afterward `P` is the recovery source, so resume needs no input file. |
| `W`: working file | Existing baseline, approved copy, published copy, a foreign edit, absent, or unreadable. A hash equality is checked at use, not assumed from an earlier read. Index contents are a separate guard. |
| Capture reservation/scratch | Exact attempt-owned locations recorded before rename. Scratch contains `A` and is expendable only because `P` roots `A`. A crash before descriptor publication leaves only a harmless unreferenced empty reservation/scratch. |
| `C`: captured aside | Custody begins at successful rename, before read. Retain until verified restoration or verified retention of its actual bytes plus safe target settlement. An unreadable capture is retained indefinitely, never treated as empty. |
| Index, HEAD, unrelated files | Helper changes none. Target must be unstaged before every write and every external invocation; recheck before settlement. Unrelated work and stashes survive. External-tool behavior is tested at its boundary. |
| `F`: fetched origin/default | Immutable commit OID captured after a successful fetch of the declared repository/branch. All checks in one classification use that OID, not a moving symbolic ref. A failed fetch cannot certify the cached ref as fresh. |
| GitHub branch-rule observation | Fresh API verification of an active applicable `non_fast_forward` rule for the bound repository/branch, or readable classic protection disabling force pushes; required before each automatic negative-history retry. It authorizes retry under D-5, never proves landing or lack of bypass. Missing, inactive, inapplicable or unreadable rules grant nothing. |
| `E`: saved landing evidence in `P` | A claim requiring the same validator as rediscovered evidence. Bound to `A`, repository/path/attempt, and interval rooted at `R`. Invalid `E` blocks; it is never discarded to enable fallback. |
| Tracker transaction | Independent durable GitHub intent/identities/checkpoints. Publication cleanup never deletes it. Confirmed GitHub mutations are not reissued; resolution verifies the terminal disposition and artifact identity. |
| External-tool state | `docs-push` owns its merge bases and temporary publication work. Helper neither edits nor interprets those private files as receipts; only verified remote evidence determines landing. |

### Derived states and observable outcomes

These are classifications of durable objects, not a second mutable state enum.
Landing is three-valued: **yes**, **no**, or **unknown**. “No” is allowed only
after complete successful verification under the history assumptions below.

| State | Durable condition/invariant | Preflight | Resume |
| --- | --- | --- | --- |
| S0 clear | No pending/capture obligation; tracker clear; no malformed standalone applied ref | `clear`, fresh tip and working blob; valid legacy applied predecessor reported separately | A new approval may start; `--resume` alone says no pending publication. |
| S1 prepared | `P` roots `A` and `B`; target still `B`; no captured file | `pending`, publication, landed false/unknown as evidence permits | Verify evidence first; if unlanded, install only over `B`. |
| S2 capture recovery | Descriptor exists; aside may hold original/foreign bytes; target may be absent or occupied | `pending`, capture details and file states; never `clear` because `W != A` | Restore absent target exclusively, or retain capture and occupied target; read/hash failures stop. Reconcile before proceeding. |
| S3 applied | `W=A`, target unstaged, `P` retained; `L=A` or its write needs recovery; no unresolved capture | `pending`, applied state and verified landing classification | Reconcile `L` with CAS; invoke tool only after verified no landing and tool quiescence; automatic retries also require D-5's API gate. |
| S4 handoff unresolved | Tool may have run, child may be live, remote/evidence reads failed, or retry's API gate is unsatisfied; `P` remains | `pending`, already_landed unknown unless a valid positive proof exists; exact failure | No blind retry. Establish child quiescence and evidence; require D-5 before automatic retry, otherwise operator reconciliation. |
| S5 landed, unsettled | Valid `E` or validated rediscovery; `W` or index differs, or capture/cleanup incomplete | `pending`, already_landed true, separate `A` and published `M`, divergence | Never invoke tool. Preserve both sides; operator reconciles the working copy/index, then settlement. |
| S6 cleanup | Valid persisted `E`, `W=M`, target unstaged, no unresolved capture | `pending` until record cleanup completes | Delete matching `L` first, then CAS-delete `P`, then release owned lock. Interruption repeats only cleanup. |
| S7 inconsistent/unverifiable | Malformed refs, invalid evidence, stale interval, missing objects, unexpected files, conflicting records | `pending` plus precise record fault; `already_landed=null` | No write, tool call, upgrade, overwrite, or cleanup; repair/restore evidence explicitly. |
| S8 settled | `P` and its matching `L` cleared; `W=M`; result has validated evidence | `clear` only if tracker also clear and lock is released | No pending attempt to replay. A later intentional mutation requires fresh approval. |

For S2 after an interrupted successful install, `W=A` plus a readable capture
equal to rooted `B` permits verified capture cleanup and transition to S3.
That is distinct from an occupied foreign target or a capture different from
`B`, which requires reconciliation. If rename never happened and `W=B`, an
empty owned reservation permits preparation to resume. If both target and
capture are missing, do not invent a file: report the rooted recovery payloads
and require explicit reconciliation of the unexpected deletion.

The applied-ref deletion precedes pending deletion, so a crash cannot leave an
unbounded applied-only record from a new-format attempt. A mismatching applied
ref is a conflict to resolve, not a reason to clear `P` anyway. Cleanup uses
observed ref values and validates reads after ambiguous command outcomes.
No file cleanup runs after deleting the only record that names that file.

Preflight reports both publication and tracker obligations even when one is
unreadable. Preserve `clear`/`pending`, `publication_tip`, `working_copy_blob`,
`pending_kinds`, and tracker fields; add structured capture/evidence faults.
Unknown is not false. A failed fetch/tool/module check returns a nonzero
failure envelope with known records, null unknowns, and no permission to mutate
the tracker. Preflight does not repair or write records (fetch is its permitted
Git update). Use a stable record/lock snapshot or report busy/changed; its result
is advisory and the mutating entry point revalidates under the document lock.

### P-2 (D-5). One authority rule for evidence

Let `Anc(X)` include commit `X` and all its ancestors. Require `R` to exist and
be reachable from fresh `F` before accepting any landing, including a current-tip
blob match. The publication interval is:

`I(R,F) = {R} union (Anc(F) minus Anc(R))`.

This is a reachability interval, not a timestamp interval and not “commits
whose first-parent chain descends from R.” It includes a receipt introduced
through a merge's second parent, and excludes older occurrences already in
`R`'s ancestry. Inspect all commits in the range, including merge trees, without
a path-limited log or first-parent filter. Inspect the document path in each
candidate tree afterward. A confirmed absent path is not a missing/unreadable
tree or object. Incomplete, shallow, missing, or truncated history cannot prove
a negative; obtain complete objects or stop. No time/commit-count cutoff may
silently turn “unknown” into “no.”

| Evidence | Exact acceptance rule | Invalid/unverifiable result |
| --- | --- | --- |
| Saved already-present | `E.commit` in `I(R,F)`; `E.published_blob=A`; tree at the bound path is blob `A`; no receipt field; every identity/type agrees | S7; retain record unchanged; no history fallback |
| Rediscovered already-present | No saved evidence; some commit in `I(R,F)` has exact blob `A` at the bound path | Validate with the same predicate, persist evidence by CAS before cleanup; failed save retains intent |
| Saved/rediscovered receipt | `E.commit` in `Anc(F) minus Anc(R)`; exact whole-line trailer binds repository, path, attempt and `A`; receipt OID equals evidence OID; one ordinary publication commit changes exactly that path; its tree contains blob `M=E.published_blob` | S7; no unrelated-path or other-attempt receipt, no substring/trailing-data acceptance |
| Legacy pending commit | Valid legacy record with one parent `R`, exact document-only change; pending commit reachable from `F` and in the interval | Landed at that exact commit, `M=A`; otherwise examine valid no-op evidence or retain unlanded legacy intent |
| CLI stdout, exit status, current worktree bytes | Never remote authority | Report exact tool output, but decide landing independently |

Receipt publications from the external tool are single-parent commits. A merge
can make such a receipt reachable; a merge commit itself carrying a copied
trailer is not a tool receipt. Read changed paths with NUL-delimited Git output,
so non-ASCII names, spaces and quotes compare as actual paths. Reject unsupported
names (for example newline names in a line-oriented probe) before recording an
attempt or touching files, not halfway through recovery.

Prefer valid saved evidence and do not re-search because today's document
differs. Without saved evidence, validate matching receipts before exact-blob
no-op candidates, since a receipt identifies the actual merged publication.
Unexpected multiple receipts for the same attempt are an inconsistency to
report; do not select an arbitrary “oldest” message. Multiple identical-blob
no-op candidates all prove the same fact; choose one deterministically (fixed
topological order with OID tie-break), then persist that choice. The record
records which evidence it selected, so resume does not select anew.

`M` may differ from `A`: a receipt binds the approved input to the external
tool's merged result. A raw historical occurrence of `M` without that receipt
does not prove this approval landed. Conversely, a later commit removing `A`
or `M` does not undo an established landing. Report both **historically landed**
and **current branch blob**; never claim the current tip still contains the
disposition merely because the historic publication is verified.

“Published” is allowed only after valid evidence, verified local settlement,
and successful record cleanup. A valid landing with failed cleanup is
`record-retained`; divergent local state is `landed-but-divergent`. On fetch
failure after the tool, say “publication outcome unknown,” not “nothing was
published.” Tool refusal remains `incomplete-publication` unless independent
evidence proves landing; never substitute another publisher.

### External invocation and limits of the guarantee

Persist a handoff marker before spawning `docs-push`; once spawned, persist the
child's **PID, operating-system process start time, and exact argv**, with its
host and intended invocation. Never record or check PID alone. Quiescent means
that this exact process identity no longer exists: PID reuse with a different
start time is not the old child and must neither block it as live nor authorize
killing the unrelated process. A matching PID/start time that remains live is
not quiescent; an unexpected argv for that same live identity is an inspection
ambiguity, not proof of exit. Missing/insufficient start-time precision or failed
inspection also leaves quiescence unknown.

A parent crash can leave the child running. Retain serialization until the
child is known quiescent, including any known still-running publication
descendants. If a crash occurred between spawning and recording the child
identity, automatic retry is blocked until the operator establishes quiescence;
a dead parent PID is insufficient. Do not kill an unknown child, clear a live
lock, or infer quiescence from silence.

For an automatic negative-history retry, first verify through the GitHub API
that active rules for the exact publication repository and branch forbid
non-fast-forward pushes under D-5's rule-presence policy. Use
`GET /repos/{owner}/{repo}/rules/branches/{branch}`, with the exact branch
URL-encoded. Affirmative means a returned entry whose `type` is
`non_fast_forward`. This endpoint supplies the effective active rules for that
branch, including organization rules; evaluate/disabled rules are excluded.
It needs repository metadata read access, not administration access. Read all
pages before declaring the rule absent; failed/incomplete parsing is unknown.
([GitHub rules API](https://docs.github.com/en/rest/repos/rules#get-rules-for-a-branch))

Classic branch protection is an alternative only when
`GET /repos/{owner}/{repo}/branches/{branch}/protection` is readable using the
helper's existing access and explicitly returns `allow_force_pushes.enabled=false`.
That endpoint documents Administration read permission for fine-grained tokens;
never require elevated/admin access, ask for broader credentials, or infer a
prohibition from a 403/404. A successful rules response containing
`non_fast_forward` suffices without querying classic protection or bypass actors.
([GitHub protection API](https://docs.github.com/en/rest/branches/branch-protection#get-branch-protection))

A ruleset name, an inactive or nonmatching rule, or an earlier cached response
is not verification. Neither an administrator bypass nor lack of admin
enforcement invalidates an otherwise affirmative rule under the owner's F1
decision; this is a rule-presence gate, not an identity-permission gate.
Require a fresh affirmative result before **each** such retry. A missing rule,
API error, denied access, or unreadable/ambiguous response stops for operator
reconciliation, retains P/L and captured content, and reports the exact reason;
do not fall back to the former append-only assumption or another publisher.
This gate concerns retry permission; it is not landing evidence and cannot
replace full-history verification, interval validation, or child quiescence.
Positive landing evidence can still be reconciled without invoking the tool
when the API gate is unavailable.

With that gate satisfied, fresh complete history and quiescence permit the
same-attempt retry under D-5. The next external call again receives exactly
`docs-push --expect A --keep -m <message-with-attempt-trailer> <document>`.
Refetch/revalidate before that call and require `W=A` and an unstaged target.
Process interruption between positive evidence detection and persistence is
safe because rediscovery uses the same interval and predicates.

**Guarantee boundary accepted in D-5:** an upstream force-push can erase an
unsaved landing while retaining `R`; no local algorithm can reconstruct that
erased event from the resulting history. A detectable rewrite or lost saved
evidence stops, but detecting every erased event is impossible with the present
external-tool API. The owner selected verified active GitHub rules as the
operational boundary for automatic negative-history retries, and operator
reconciliation otherwise. A current rules response does not prove uninterrupted
historical enforcement or prevent an administrator changing rules immediately
after the check; the helper must not claim it does. **Admin bypass is accepted
residual risk:** the manager's F1 review reported that Kanban's master ruleset
`19144628` contains `non_fast_forward` but grants `RepositoryRole 5` (Admin)
an `always` bypass, and agents, `docs-push` and the drainer push as admin
`coghex`. The owner's response was “rule present is enough.” This is recorded
review evidence, not a reason for the helper to query bypass actors or demand
that the pushing identity be unable to force-push. Consequently, even with the
gate passing, an admin can erase an unsaved landing; absolute no-replay under
that bypass is not guaranteed. Known evidence of an actual rewrite or an
enforcement gap other than the accepted bypass still stops recovery. This
design neither changes branch rules nor promises atomic enforcement.

The model covers helper-process termination and ordinary syscall failures on
a functioning local filesystem. It does not claim recovery after loss of the
Git directory, disk corruption, hardware/power failure beyond filesystem/Git
durability, external deletion of records/asides, or malicious evidence forgery.
It does not make unlocked editors obey serialization: a writer holding an open
file descriptor can keep modifying a captured inode. Preserve observed versions
and stop on detected changes; linearizable collaboration with arbitrary writers
would require their participation. These limits do not excuse unlinking a
capture on a failed read, accepting unreadable state as absent, or replaying a
reachable reverted landing.

### Interruption and fault matrix

Each `T-N` is a required independent fault-injection regression. “Stop” means
no external invocation, no destructive cleanup, and a structured retained-state
report; it does not mean silently treating an obligation as clear. Inject both
the operation's failure and termination immediately after its successful effect
where indicated. Every case runs preflight and a new-process resume, rather
than relying on an in-memory `finally` block.

| Test | Interruption/failure boundary | Retained state and preflight | Exact resume action |
| --- | --- | --- | --- |
| T-01 | Owner/root/path/module validation, initial fetch, ref/object read | No mutation; known records reported, unknown fields null; never clear on failed read | Retry inspection only after cause is resolved |
| T-02 | Lock creation failure; crash after successful acquisition | Original files/refs intact; busy lock reported | Verify owner and child quiescence, CAS-clear only provably abandoned lock, reacquire |
| T-03 | Approved-input read/hash, baseline read/hash, temporary-index/tree/record construction failure before `P` | Input and target intact; no accepted intent; S0 or earlier obligations | Caller retains input; retry preparation, never imply content was recorded |
| T-04 | Initial pending-ref write failure, successful write then failed read-back, crash after write | No target mutation; reread can find S1; uncertain ref write is not absence | Read exact ref/object; resume S1 only if valid, else S7 |
| T-05 | Scratch create/write/close/chmod/stat failure | S1; target remains baseline; `P` roots A/B | Discard only verified attempt scratch; repair cause and retry preparation |
| T-06 | Capture-directory reservation or descriptor CAS write/read-back failure | No rename allowed before verified descriptor; S1 with harmless scratch | Validate descriptor/ref; recreate only missing owned reservation |
| T-07 | Rename fails; or succeeds then process dies before read/flag | Failed rename leaves target; successful rename leaves recorded aside and possible absent target; S1/S2 | Inspect target/aside independently; restore capture exclusively or preserve both; never infer failure from missing flag |
| T-08 | Aside read/stat fails after rename (round 8) | S2; aside retained even without bytes/hash; P and A/B retained | Restore by exclusive hard link if safe, otherwise retain and report path; never delete unreadable capture |
| T-09 | Captured hash/object write or record-rooting fails | S2; actual aside retained; not merely an unrooted object name | Restore/retain capture; retry preservation before any deletion or tool call |
| T-10 | Captured content differs from B | S2; foreign bytes rooted or aside retained; target restored if absent | Report changed baseline; no automatic application over those bytes; explicit reconciliation |
| T-11 | Target recreated during gap; exclusive link fails with EEXIST | Winning target untouched, capture retained/rooted, P retained | Report both versions; stop for reconciliation, no overwrite |
| T-12 | Install link fails otherwise; restoration link/copy/chmod/read fails | S2; aside retained; absent or partial target reported accurately | Restore only exclusively and verify; partial/occupied target needs reconciliation |
| T-13 | Approved install succeeds then crash; scratch/aside cleanup fails | P roots A/B; W=A; descriptor still discovers capture; S2/S3 | Verify actual capture and install, complete safe local cleanup, then record L; no need to rewrite W |
| T-14 | Applied-ref write/CAS/read-back fails or crashes afterward | P remains; W=A; L absent, matching, or conflicting; pending | Recover matching L from verified P/W; conflict stops; never pretend an unrecorded application licenses local tracker resolution |
| T-15 | Evidence fetch, ancestry/tree/message/path/history read fails before tool | S3/S7; landing unknown; all records intact | Retry verification; no tool invocation from a negative inferred from read failure |
| T-16 | Tool absent, capability check fails, or executable cannot start | S3 with exact diagnostic; not handed off if that is conclusively known | Repair tool; reverify history, target and D-5 API gate before automatic same-attempt retry |
| T-17 | Handoff-marker CAS failure; crash before spawn; crash after spawn before child-ID record; PID reuse or identity-inspection failure | Marker failure prevents spawn; successful marker means may-have-run; S4; persisted child identity includes PID/start time/exact argv | Establish exact-identity quiescence, then evidence policy; reused PID is not the child, unknown identity never licenses concurrent invocation |
| T-18 | Tool conflict/refusal/nonzero/timeout; misleading success or failure output | P/L retained; remote may or may not contain landing; exact output preserved | Fresh evidence decides; if yes S5/S6, if unknown S4, if verified no apply D-5 retry gate |
| T-19 | Remote publication succeeds; crash before `--keep` or after merged copy installed | P retains A; remote receipt roots M; W=A, M, absent or foreign; S5 if proof found | Persist evidence; W≠M is landed-but-divergent, never reapply A or invoke tool |
| T-20 | No-op landing after R, crash before evidence lookup; post-tool fetch failure | S4 initially; history may contain A followed by revert | Recover intermediate occurrence within I, persist it, never republish (rounds 5–6) |
| T-21 | Evidence-record construction/write/CAS/read-back fails; crash just after CAS | Old P or new P remains; positive fact may be unsaved; pending | Revalidate saved evidence if present, otherwise rediscover; preserve old intent, never “fix” conflicting ref |
| T-22 | Saved evidence malformed, wrong blob/path/attempt/interval, unreachable, missing object | S7 with exact inconsistency, including pre-R occurrence (rounds 7–8) | No fallback, no rewrite/cleanup; explicit evidence repair required |
| T-23 | W read/stat or index read fails during settlement; W/index changes | S5; E retained; unreadable is unknown, not absent or clean | Reconcile to verified M and unstaged target, or stop; no tool |
| T-24 | Aside/scratch removal, directory removal, descriptor-clear write fails | P retained naming leftovers; content custody unchanged | Repeat only safe cleanup; do not delete P while recovery artifacts remain unresolved |
| T-25 | Applied-ref delete fails; dies after delete before pending delete | P with E remains; L unchanged or absent; S6 | CAS-delete matching L if present, then P; never publish |
| T-26 | Pending-ref delete fails, changes concurrently, or succeeds before process dies | Failed/changed ref retained; successful deletion leaves no current intent; S6/S8 | Reread; absent means no attempt to replay, changed means stop; tracker remains independent |
| T-27 | Lock-release CAS fails, dies before release, or ownership changes | Published/retained state reported separately from lock; never clear another owner | Clear only verified abandoned exact lock; no republishing |
| T-28 | Tracker checkpoint or resolve read/write/CAS fails, crashes before/after confirmed GitHub mutation | Tracker intent and confirmed identities retained; preflight pending | Existing tracker recovery verifies identities/entry; no repeated confirmed GitHub mutation |
| T-29 | Legacy validation/upgrade fails at any read/build/CAS/read-back boundary | Original legacy record or valid replacement retained; no file mutation before validation | Reclassify from actual ref, never restart as fresh or infer missing baseline |
| T-30 | Effective-rules endpoint read/pagination/parse fails or supplies no `non_fast_forward`; classic protection unavailable/nonaffirmative | P/L/content retained; pending with gate failure; negative history alone does not authorize retry | Stop for operator reconciliation; fresh affirmative rule verification plus all other guards permits retry even with admin bypass |

For every write/delete row, also inject an ambiguous command failure **after**
the side effect and a concurrent ref-value change. The continuation must inspect
actual state rather than assume the command's exit status describes its effect.
File failure cases include an untracked original so no Git baseline silently
masks data loss, and tracked/empty originals to distinguish absence from emptiness.

### Legacy and pre-upgrade records

Validate before changing either the file or any record. Migration is monotonic:
preserve the original until a verified replacement contains all required
recovery information. Version-1 helper records are included because the paused
branch's tests and possible local attempts must remain interpretable.

| Existing form | Mapping and action |
| --- | --- |
| No P, no L | S0 if tracker clear; an unknown orphan aside is reported for manual reconciliation rather than guessed to belong to a new approval |
| Valid legacy pending commit, unlanded, parent R reachable, W equals parent path blob or A | S1/S3. Validate single-parent/document-only scope, current index and history first. Upgrade by CAS before a new capture or handoff; preserve legacy object and root available baseline. If W=A, do not rewrite it |
| Valid legacy pending commit already reachable | S5/S6, M=A at that exact commit; no tool call or needless unlanded upgrade |
| Legacy pending commit not itself reachable, exact A appears within valid interval | Valid no-op evidence; S5/S6, retain evidence through migration/cleanup |
| Legacy parent stale/missing, malformed commit/tree/scope, unreadable record | S7; no document application or record replacement (round 1) |
| Legacy baseline absent from parent, W=A | May recover applied state using A and retained original record; no invented empty baseline; no later capture over a nonexistent B |
| Legacy baseline absent, W is another file or absent | No proof of an authorized replacement; S7/manual reconciliation |
| Valid L only, W=L | Preserve existing legitimate locally-applied predecessor behavior. L is not a receipt and provides no attempt interval. Before local tracker resolution, inspect complete reachable history at the path; any occurrence of L forces branch resolution, unknown forbids local resolution. A later fresh approval may use this exact predecessor but retains it until new intent is durable |
| Valid L only, W differs/absent/unreadable | Report divergence; no local tracker permission. Preserve L until explicit predecessor reconciliation; do not replace merely because it is a blob |
| Malformed L, with or without P | S7; report in preflight, refuse replacement/deletion even if a later publication would succeed (round 1) |
| Valid P with L for different content | Validate whether it is a retained legacy predecessor; root it in replacement intent before advancing. Unexpected disagreement is S7; never clear P while quietly leaving contradictory L |
| Helper v1, valid evidence present | Apply the new validator including interval before migration or cleanup. Invalid evidence is S7; do not erase it and rediscover |
| Helper v1, evidence absent, valid R/A | Same full-history fallback. Before a new local capture, migrate and root B from a verifiable blob/W. Missing B with W=A permits evidence-only reconciliation, not fabrication of B |
| Old orphan aside with no locator in P | Do not globally delete or auto-assign by filename. Report candidate exact path(s), preserve them, require manual binding/restoration; old records cannot retroactively prove capture ownership |
| Tracker transaction only or alongside any row | Retain existing confirmed identities and checkpoints. Preflight reports it independently. Branch resolution verifies today's terminal entry and identity; local resolution requires verified applied bytes and a verified unlanded classification |

Legacy applied-only history deliberately has a broader, conservative bound
than a new pending attempt: it has no `R` with which to exclude earlier bytes.
A historical match can deny local resolution unnecessarily; that is safer than
discarding a transaction whose terminal entry was reverted. Do not use this
unbounded legacy lookup to certify publication of a new interval-bound attempt.

### Tracker resolution

Use the helper's common landing validator for pending attempts, including merged
receipts and saved evidence. Do not duplicate a weaker “approved blob at tip”
heuristic in `tracker_transaction.py`. Local resolution requires verified `L`,
`W=L`, a successful complete negative landing check, and no capture, record, or
handoff uncertainty. It records “applied locally,” never “published,” and does
not remove the publication obligation. A landed mutation requires current
branch verification of both terminal disposition and artifact identity; a
historic receipt alone cannot resolve a tracker entry removed by a later edit.
Absent/failing helper modules and incomplete historical probes grant nothing.

## Verification strategy and eight-round coverage

Use temporary repositories/remotes and a controlled external `docs-push` on
PATH. Never run fault tests against the owner's real tool/configuration or
held worktrees. Preserve existing fixture patterns in
`tools/test_approved_document.py`, `tools/test_tracker_transaction.py` and
`tools/test_consuming_repository_documents.py`. For crash coverage use process
termination at explicit seams as well as raised exceptions: exceptions alone
exercise cleanup that a killed process never runs.

The deterministic crash harness runs the helper in a fixture child process.
The test runner passes a named boundary such as
`KANBAN_TEST_FAULT_POINT=T-07.after-rename`; the child harness installs an
observer/wrapper on that exact operation and calls `os._exit(86)` immediately
after the successful rename, before the next helper operation. Before exiting,
it writes the reached seam ID to a parent-observed pipe. This hook is installed
by the test harness, not a production environment-controlled kill switch.
Each T-N with crash coverage has explicit before/after seam names; unknown seam
names fail the harness rather than silently execute a success path. The parent
asserts both seam receipt and exit code 86 before starting recovery. No sleep,
wall-clock scheduling, or timed external signal selects the crash point.
Operation-failure cases use the same seams to inject their specified errors;
ambiguous-after-effect failures perform the effect before raising. Temporary
subprocesses and fake tool descendants are owned and reaped by the harness;
timeouts fail the test, never stand in for the intended crash. T-17 uses
controlled process-inspection fixtures for same PID/different start time,
same live identity, changed argv, and unreadable identity.

Run a fresh preflight and
resume, assert exact retained bytes/refs/capture paths, remote commit graph,
tool-call count, and tracker-call count. A content hash alone does not prove
the file or rooted object remains recoverable.

Each matrix row T-01–T-30 needs its own named regression or parameterized case
whose failure identifies the boundary. Existing tests can satisfy a row when
they assert the whole invariant; no need to duplicate a meaningful regression.
Add negative controls: remove the interval check, convert failed read to absent,
or reintroduce capture deletion, and the corresponding test must fail.

| Review round | Reproduced cases to retain as distinct regressions | Model coverage |
| --- | --- | --- |
| [1](https://github.com/coghex/kanban/pull/836#issuecomment-6349069518) | Staged index with approved W on resume; malformed applied-only commit ref; stale legacy parent before upgrade/application; non-ASCII and quoted receipt paths | T-14/15/23/29; staged check before every invocation; raw NUL paths |
| [2](https://github.com/coghex/kanban/pull/836#issuecomment-6349271037) | Publication, interrupted cleanup, later removal of terminal entry; local tracker resolution must not clear it | T-19/28, common landing authority |
| [3](https://github.com/coghex/kanban/pull/836#issuecomment-6349467360) | Merged M differs from A and interruption precedes keep; later terminal-entry removal; receipt reachable only via merge second parent | T-19/28; M/A separation; unsimplified full graph |
| [4](https://github.com/coghex/kanban/pull/836#issuecomment-6349660531) | Legacy applied-only landing hidden behind merge; already-present at R followed by revert before cleanup | T-20/29, conservative unbounded legacy scan; inclusive R no-op |
| [5](https://github.com/coghex/kanban/pull/836#issuecomment-6349883328) | Concurrent no-op after R then revert; older supplied preflight R with intermediate A | T-20/21; complete interval, not just endpoints |
| [6](https://github.com/coghex/kanban/pull/836#issuecomment-6350296259) | No saved evidence before lookup; failed post-tool fetch; failed evidence-record write, each followed by upstream replacement | Separate T-20 and T-21 cases, all no-repeat |
| [7](https://github.com/coghex/kanban/pull/836#issuecomment-6353729913) | Saved baseline blob mislabeled as approved landing; wrong receipt document/attempt | T-22; same identity predicate for saved/discovered evidence |
| [8](https://github.com/coghex/kanban/pull/836#issuecomment-6353976059) | Saved exact A predates R and was reverted; failed read after successful aside rename deletes sole untracked copy | Separate T-22 and T-08; repeat T-08 against live publisher fix |

Also retain integration coverage of unrelated staged/unstaged/untracked and
committed work, stashes, clean-primary fast-forward versus dirty-primary
preservation by the external tool, consecutive dispositions, novel untracked
documents with an existing working baseline, and consuming repos without
Kanban `tools/`. Test missing objects, shallow history, second-parent receipt,
merge-tree-only no-op occurrence, a stale R even when current F contains A,
ambiguous subprocess lifetime, and D-5's API-gated retry. T-30 fixtures assert
the exact `GET /repos/{owner}/{repo}/rules/branches/{branch}` request, branch
encoding and pagination. Cover an active applicable `non_fast_forward` entry
permitting retry; no such entry (including inactive/nonmatching rules excluded
by that endpoint); denied/unreadable/error responses; a rule found on a later
page; and changed responses preventing reuse of an earlier positive check.
An affirmative rule with admin bypass must still pass, without a bypass-actor
query. Readable classic protection with `allow_force_pushes.enabled=false`
may pass; true, missing/ambiguous fields, 403 or 404 grant nothing and must not
trigger a request for admin credentials. All refusal cases assert zero
additional tool calls and retained records.
Positive landing reconciliation must still avoid republishing when rule lookup
is unavailable. Use fake API responses, never production rule changes.

Bundle byte-identity, inventory/version, and workflow-contract checks still
apply to implementation. Change the executable contract with the code under
the repository's code-document rules; this standalone design lands with
`docs-push`. No new Haskell behavior is proposed.

## Open questions and signoff history

### Q-1. Approve P-1's retained-intent/capture model and associated state tables?

**Resolved by D-4**, manager approval in `y6mj9vvpy3r9gapeapm7zn244w`.
The approved model adds a versioned record rooting baseline and approved payloads,
a capture locator persisted before rename, preservation on every application
failure, and explicit child-quiescence handling. It costs schema/migration and
fault-injection work, but avoids hidden filesystem state and exceptions that
delete the only copy. A two-line `captured_ok` fix alone repairs round 8's
exception but leaves process death before that flag and undiscoverable asides
unmodeled. This affects REC-1 and its legacy tests.

### Q-2. Approve P-2's evidence rules, and choose the negative-history retry boundary?

**Resolved by D-5**, direct owner decision relayed in
`y6mj9vvpy3r9gapeapm7zn244w`. The shared validator, strict interval and
invalid-record stop rules are approved. Automatic negative-history retry
requires fresh GitHub API verification that active publication-branch rules
forbid non-fast-forward pushes; otherwise stop for operator reconciliation.
The alternative of merely assuming append-only history is rejected. This
affects REC-1's resume behavior, T-17–T-22 and T-30 acceptance signals.

### Q-3. Authorize a separate live-publisher preservation fix before #831 deletion?

**Resolved by D-6**, direct owner decision relayed in
`y6mj9vvpy3r9gapeapm7zn244w`. Yes: the manager files and routes a separate live
fix; #830/REC-1 scope is unchanged. This session neither implements nor files
it. #836 remains paused until the design-review endpoint is satisfied.

No original design-choice question remains open. F1's owner clarification is
recorded in D-5. Acceptance of the review fixes and explicit readiness signoff
remain pending; additional review findings may require further decisions.

## Delivery plan

### REC-1. Rework existing #830 against the signed recovery contract

- **Outcome:** existing #830 delivers helper recovery and tracker integration
  once the manager releases the held solver, in one PR if it fits the cap or
  the ordered conditional split below if it does not.
- **Scope:** the approved decisions above; existing #830 delivery obligations.
- **Phase:** after manager signoff and opposite-brand design review with findings resolved.
- **Depends on:** the existing #829 prerequisite; no new tracker dependency invented here.
- **Ordering:** existing #775 chain; #831 follows #830.
- **Relevant decisions:** D-1–D-6; D-6 keeps the live-publisher fix separate.
- **Acceptance signals:** state invariants, T-01–T-30, eight-round regression
  map, consuming-repository and bundled-copy checks.
- **Out of scope:** filing new tracker artifacts in this design session, consumer switch-over, classification
  retirement, external tool changes, and unapproved publisher scope changes.
- **Open questions:** Q-1–Q-3 resolved; review acceptance and readiness signoff
  remain outstanding. Conditional split activation belongs to the manager.

### Size budget and ordered fallback (F3)

The review cited 8,449 changed lines. A read-only measurement on 2026-10-23 of
the pinned PR base `ff1e9f9dba7a6df389ad8db10f859fdea730c186` to head
`37d9923605bad43a0a31ce7ad40d6ef6eb629a04` gives **9,970** numstat lines:
9,606 additions + 364 deletions across 21 paths. Both
`git diff --numstat <base>...<head>` and GitHub's additions/deletions agree.
Use this larger verified baseline for planning, not 8,449. The three helper
copies contribute 6,354 added lines and its current test suite another 2,118;
bundled duplication is therefore included in every estimate below.

Estimated extra final-diff volume for record v2/capture/legacy changes,
handoff/evidence/API/tracker changes, and the fault fixtures is **5,000–8,000**
lines after accounting for all copies, tests, contracts and manifests. This
puts a combined PR at roughly **14,970–17,970** lines, with effectively no
margin at the upper end against the **strictly below 18,000** cap. This is a
planning estimate, not measured implementation work. Existing regressions may
be extended rather than duplicated, but coverage must not be cut to fit.

The solver reports fresh `additions + deletions` against the intended base at
the first complete implementation/test pass and again before asking the manager
to push/review. If the projection reaches 18,000, or the measured final diff
does, stop the combined delivery and use this ordered fallback. The manager
files and readiness-gates the child issues before work is dispatched, relates
them to #830, and keeps #831 dependent on both. No held branch is rewritten by
this design session. Each eventual PR must itself measure below the cap.

| Conditional slice | Deliverable and green intermediate state | Dependencies / checks / estimate |
| --- | --- | --- |
| REC-1a. Record v2, capture custody and legacy adapters | Add the helper's record/capture foundation and compatibility adapters, rooting payloads and making capture recovery testable. Ship required copies/inventory/version changes and its contract alongside it. Keep production workflow assets and tracker imports on the live publisher; do not expose the unfinished helper as a usable publication CLI. No production caller creates v2 records in this intermediate release. Existing publisher/tracker behavior remains intact; new isolated foundation tests pass. | First; T-01–T-14 and T-29, new/legacy record round trips, capture custody, lock/CAS and bundled-copy checks. Approximately 7,000–11,000 changed lines including three copies and tests. |
| REC-1b. Evidence, handoff, API gate and tracker integration | Build on REC-1a to complete the helper's public preflight/apply/resume flow, bounded evidence validation, child identity/quiescence, API retry gate and tracker decoupling. The full #830 contract is usable only here. Workflow asset migration and publisher deletion still belong to #831. | Depends on merged REC-1a; T-15–T-28 and T-30 plus rerun T-01–T-14/T-29, all eight-round regressions, tracker/consuming-repository and bundle checks. Approximately 7,000–11,000 changed lines against REC-1a, including edits/deletions and repeated bundle/version changes. |

The split estimates can exceed the combined estimate in total because the
second PR edits foundation lines and repeats release metadata. Each slice runs
the relevant Python suite and all selected gates, and neither lands with a
half-switched consumer or failing existing tests. If either slice still
approaches the cap, return to the manager for a revised boundary; do not silently
split shared invariants or relax the cap. These are conditional child designs,
not additional entries in the current processing ledger: when activated, the
manager replaces REC-1 with REC-1a then REC-1b and records the filed issue IDs.
Until then the ledger continues to link the one existing #830 slice.

## Review and handoff

Initial draft: 2026-10-23 UTC, request `kan-backlog-20261022`, `kan-designer-1`.
Manager signoff on `6f006a1447` was received in verified reply
`y6mj9vvpy3r9gapeapm7zn244w`, answering `r4d4zwr4itj3m7q4p7n8j3sm9a`.
The manager relayed the opposite-brand review of `9d1e0f8680` in verified reply
`b249chw3p5ydcr5937kx3zu7qa`, answering status
`piry5ucf4xy5ejeqj29ihwb7un`. Resolution map for review acceptance:

| Finding | Document resolution |
| --- | --- |
| F1 — admin bypass (owner decision) | D-5 and the guarantee boundary explicitly accept bypass risk. Rule presence suffices; no identity/bypass permission gate. |
| F2 — verification API | External-invocation contract names the effective-rules endpoint, affirmative response, read-only access requirement and optional already-readable classic protection; T-30 tests those requests and outcomes. |
| F3 — delivery size | Verified 9,970-line baseline, combined estimate against the 18,000 cap, measurement checkpoints, and ordered REC-1a/REC-1b fallback with independently green intermediate states. |
| F4 — child quiescence | Handoff records PID, process start time and exact argv; reused PID is distinguished and unreadable identity stops. T-17 fixtures cover each classification. |
| F5 — deterministic crashes | Named test-harness fault seams invoke `os._exit(86)` in the child with a seam receipt; no timing-dependent signals; error injection and recovery assertions share the same boundaries. |

Publish this revision's commit in #kan-backlog for acceptance of the fixes.
Keep `exploring` until explicit readiness signoff and completed review; addressed
findings are not a self-issued approval. No tracker artifact is filed by this
design session; a cap-triggered split is managed as described above.

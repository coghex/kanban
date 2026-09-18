---
name: auto-project-review
description: Repeat $project-review — the senior audit of one merged pull request — a counted or open-ended number of times, one whole invocation at a time. Counts only successfully recorded completed reviews, stops on the first refusal, interruption, or exhausted queue, and ends every run with a progress report. Delegates the review, the ledger, the claim, and the cleanup entirely to that workflow and performs none of them itself; never merges and never creates or edits a tracker issue. Use only when the user invokes $auto-project-review or explicitly asks for the autonomous run.
---

# Serial project review

Repeat $project-review, one whole invocation at a time, until the count
is reached or something stops the run.

**This workflow reviews nothing itself.** Each iteration is one
$project-review invocation, and everything an iteration does belongs to
that workflow: the merged-pull-request inventory, the liveness registration,
the claim, the pinned worktree, the reading and the judgement, the report it
may allocate, the `record` checkpoint, and the every-exit cleanup its step 9
owes. This document contributes the loop, the counting rule, and the stop
conditions, and nothing else. Never take a claim, read or write the ledger,
allocate or write a report, create or edit a tracker issue, commit, push, or
remove a worktree on the delegate's behalf, and never perform a review step of
your own. Run two iterations at once and both would race for the same claim, so
an iteration begins only once the one before it has ended.

$project-review is a delegated sub-step. It was written to be invoked
directly, so it states its own terminal stop condition and its own assumptions
about who is running it. Where one of those conflicts with a step below, **this
document wins** — the one override that matters is called out in step 3.

## 1. Read the count, before anything is delegated

```bash
COUNT="<the count the user named, or empty when they named none>"
```

Codex substitutes no argument placeholder, so take the count from the prompt.

`$COUNT` is **one nonnegative decimal integer, or nothing at all**, and which
of the two it is decides the whole run:

- **An integer `N`** — run at most `N` iterations. `0` is a legitimate `N`: it
  delegates nothing, reviews nothing, and reports `0 of 0` straight away.
- **Absent** — run open-ended, repeating until the user stops the run or one of
  step 4's stops arrives.

**Every other argument is refused before the first iteration.** A negative
number, a fraction, a number written any way but as decimal digits, more than
one argument, and any other text are each a refusal: say what was given, say
that a count is one nonnegative decimal integer or nothing, and stop. Nothing
has been delegated at that point, so a refusal here costs nothing and guessing
would cost a review of a pull request the user did not ask for. Never round,
truncate, or reinterpret an argument into a count it does not spell, and never
fall back to open-ended because a count could not be read.

**Announce, then delegate:** name the count this run will honour — `N`, or
open-ended — before the first iteration begins. A wrong reading is only cheap
while nothing has been claimed under it.

## 2. Run one iteration

Invoke $project-review in its default pull-request mode, with no
argument of your own. Never ask it for direct-commit mode: that mode is a
separate explicit request of the user's, it is scheduled by no ledger, and this
loop never enters it.

Then wait for that invocation to finish and read what it reported. The next
iteration begins only after this one has ended, and never beside it.

## 3. Count the iteration, or stop on it

**Its stop condition ends that invocation, not this run.**
$project-review closes by stating that one invocation reviews exactly
one pull request and starts no other, and that repetition is this workflow's.
That closing report is the handoff back to step 2, not a final answer:
a successful single-review stop returns control to this loop, which decides
whether another iteration begins.

**An iteration counts toward `N` only when the delegate reported a
successfully recorded completed review** — its `record` reported
`"status": "recorded"`, whether the outcome was `clean` or `findings`. A
findings-bearing review is a completed review and counts exactly as a clean one
does; the findings are the report's business and $process-report's, and
they say nothing about whether this iteration happened.

**An iteration that ended any other way is not counted, and it ends the run.**
A refused inventory or a failed inventory page, a registration the adapter
refused, a claim the delegate could not take, a failed fetch, a migration that
stopped on a flagged report, a `record` or an allocation refused after a
takeover, a cleanup step that retained what it could not remove, and an
interruption are each one of those. **Never begin another iteration after one
that did not record a review.** The delegate stops for a reason, and a loop
that answered a refusal by trying again would spend the user's whole count
rediscovering it — or, worse, would start a review the single workflow had just
declined to start.

**One of those endings leaves a recorded review behind, and the report owes
it.** The delegate publishes its checkpoint in step 8 and cleans up in step 9,
so an iteration can record a review and then fail to remove what it made. That
iteration is still not counted and still ends the run — the rule above does not
bend for it — but the review it recorded is real, published, and the next
invocation's to build on. Name it in step 5's report, with the pull request,
the outcome and the verification commit the delegate gave, and name every
resource the delegate reported retaining, by the path it named. Never undo that
record and never run the iteration again to tidy up after it: the row is
complete and the checkpoint is published, so a second attempt at either would be
this workflow writing the ledger.

Retrying is never the repair, and neither is reaching around the delegate: do
not re-run an iteration, do not adjust the inventory, the ledger, or the claim
so that the next attempt might fare better, and do not take a review the
delegate refused to take.

## 4. Where the run stops

Exactly one of these ends every run, and each one reaches step 5's report:

- **The count is reached.** `N` iterations recorded a review. Stop; do not
  begin an `N`-plus-first to see whether anything is left.
- **The queue is exhausted.** The delegate reported `"status":
  "no-selectable-row"` — every merged pull request its listing named is
  excluded. That is a stop without error, not a refusal and not a failure: the
  repository has nothing left for this workflow to review. Report it as the
  ordinary end of the run.
- **The user stops the run.** An open-ended run has no other ordinary end.
  Report the progress reached so far. A forcibly terminated session cannot
  guarantee a final message at all; when that happens the delegate's own lease
  and cleanup are what recover the interrupted iteration, and neither is this
  workflow's to perform or to pre-empt.
- **An iteration did not record a review.** Step 3's rule. Name the delegate's
  own refusal, as it came.

A count of `0` reaches the first of those before any iteration begins.

## 5. Report the progress, on every stop

Every stop ends with the same report, whether the run ended on `N`, on an
exhausted queue, on a refusal, or on the user's word:

- the number of recorded reviews against the target — `k of N`, or `k of
  open-ended`;
- every pull request an iteration reviewed, in the order they were reviewed,
  each with the outcome the delegate recorded, the verification commit it
  recorded the review against, and either the report path it allocated or the
  existing-finding links a repeats-only review recorded instead;
- any review the uncounted last iteration had already recorded before it
  stopped — the cleanup failure in step 3 is the ending that produces one —
  named beside the counted reviews and told apart from them, together with
  every resource the delegate reported retaining, by the path it gave;
- the reason this run ended, in the words step 4 gives it.

Take every one of those from what the delegate reported about its own
invocation. Do not read the ledger, the reports, or the checkpoint commits to
assemble it: those are the delegate's records, and this workflow reports on the
run rather than on the repository.

A run that recorded nothing still reports: `0 of N`, or `0 of open-ended`, with
the reason. An empty report is not a shorter way of saying the same thing.

End with exactly one of:

```text
<k> of <N> project reviews recorded — the count was reached.
<k> of <target> project reviews recorded — no selectable pull request remains.
<k> of <target> project reviews recorded — stopped at your request.
<k> of <target> project reviews recorded — stopped: <the delegate's own refusal>.
```

`<target>` is `N` for a counted run and `open-ended` for one invoked without a
count. A run whose count was `0` ends on the first line, with `0 of 0`.

# Bug findings

These entries contain focused repository evidence for later disposition with `process-report`.

`[ ]` unprocessed · `[#N]` filed · `[no-issue]` closed without an issue · `[deferred]` blocked on a concrete precondition

## Status

- [ ] BUG-1. Review key starts an epic review from collapsed or empty headers

## 1. Keyboard interaction

### BUG-1. Review key starts an epic review from collapsed or empty headers

> **Captured note:** when i hit r and an epic tracker is selected, it gives an error and puts a red cross next to it, that's not right, hitting r on an empty tracker, or a tracker that is collapsed should simply do nothing

**Verification:** Verified — both a collapsed tracker selection and an empty `TrackerHeader` resolve to the epic's own `IssueItem`, so `r` starts an ordinary issue-review session; a failed session is then drawn on the tracker header as a bright-red `×` badge.

**Evidence:**

- `src/Kanban/UI/Session.hs:707-715` — `selectedReviewItem` promotes the first hidden child of a collapsed tracker and a standalone `TrackerHeader` to the tracker's issue instead of returning no review target.
- `src/Kanban/UI/Review.hs:356-397` — `startSelectedReview` passes that promoted item to `startIssueReview`, creates a review session, opens its overlay, and launches the canonical issue-review path.
- `src/Kanban/UI/Board.hs:407-415` and `src/Kanban/UI/Board.hs:503-538` — every tracker header renders its issue's review badge, and `ReviewFailed` renders as `×`; `src/Kanban/UI/Theme.hs:152-160` assigns that phase the red problem attribute.
- `test/Spec/Board/Tracker.hs:44-50` and `test/Spec/UI/Golden.hs:155-157` — focused tests establish that an empty header is keyboard-selectable and a collapsed tracker's children are hidden, but no focused test covers the `r` action for either selection.

**Handoff context:**

- **Current behavior:** Pressing `r` on a collapsed or empty epic routes the epic issue into the ordinary review workflow; a backend failure leaves a failed review session whose red cross is rendered beside the epic header.
- **Expected behavior:** Pressing `r` on an empty or collapsed epic does nothing and creates no review session, error, overlay, or failure badge.
- **Scope and constraints:** Preserve `r` for ordinary issues, visible tracker children, and pull requests. The binding is active from both the board and details scopes, while tracker headers must remain keyboard focus targets for their existing expand/collapse and details interactions.
- **Remaining uncertainty:** The exact backend error text and rejection point can vary with the installed workflow; the selection, launch, and red-failure rendering paths are deterministic in the current code.

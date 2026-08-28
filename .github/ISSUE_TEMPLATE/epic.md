---
name: Maintainer epic
about: A tracker issue whose Children checklist the board parses into a hierarchy
title: ''
labels: epic
assignees: ''
---

<!--
The ordinary issue shape plus a Children checklist. Keep the five standard
headings in order, and keep the Children section.

Keep the `epic` label this form preselects. Kanban recognizes a tracker by its
label, and reads an `Epic:` title prefix only when the issue carries no labels
at all.

The Children checklist is parsed rather than conventional: Kanban.Tracker reads
it to build the board's tracker hierarchy. Each item must be a checkbox naming a
real issue with `#N` once that child exists. Until you replace the placeholder,
the board reports the placeholder line as carrying no issue reference and the
epic as having no valid children — expected for a freshly filed epic, and gone
as soon as real children are listed.

Leave the origin marker off, for the reason the ordinary issue template gives.
-->

## Background

What arc this epic covers and why it is one epic rather than several unrelated
issues. Cite repository evidence for the premise.

## Requirements

1. What must become true across the whole arc, not within any single child.

## Children

- [ ] Replace this line with one checkbox per child issue.

<!-- Each item is a checkbox naming a real issue, and may carry an -->
<!-- implementation key immediately after the reference and its separator: -->
<!-- - [ ] #123 — A1: The first slice. -->
<!-- Keep example items on comment lines like these. A checkbox on a live line -->
<!-- naming an issue number would attach that issue to this epic as a child. -->

## Acceptance

    # the exact commands that confirm the whole arc has landed

What is true once every child is closed, beyond the sum of the children.

## Out of scope

- Work this arc deliberately does not cover, and where it lives instead.

## Related

- Design documents, prior epics, or contracts this arc depends on.

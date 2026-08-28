---
name: Maintainer issue specification
about: An agent-ready implementation contract, with cited evidence and reviewer commands
title: ''
labels: ''
assignees: ''
---

<!--
Keep the five headings below, in this order. This repository is developed by
agents, and the drafting, review, and solve workflows all read an issue in that
shape.

Leave the origin marker off. Agent-filed issues carry a marker naming the brand
that wrote them, which routes the issue to a reviewer of the opposite brand. An
issue filed through this form has no such origin, and the approval gate treats
that as legacy provenance: under the default policy it routes to both the Codex
and the Claude reviewer instead of to one of them. Do not add an issue-origin
marker by hand — there is no third value meaning "human", and a hand-written one
misroutes the review.
-->

## Background

What is true today, and why it is a problem. Cite repository evidence — file
paths, and line numbers where you have them — so a reader can verify the premise
rather than take it on trust. Describe the problem, not the solution.

## Requirements

1. Numbered statements of what must become true, each one separately checkable.
2. Keep them about behavior and outcomes, so an implementation is free to reach
   them the smallest way that works.

## Acceptance

    # the exact commands a reviewer runs to confirm this is done

Name anything a reviewer must read whole rather than as a diff, where the
property belongs to the file instead of to the change.

## Out of scope

- What this issue deliberately does not change, and where that work lives
  instead — another issue, or nowhere yet.

## Related

- Issues, contracts, or code this depends on or touches.

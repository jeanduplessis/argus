# Merged Pull Request icon design

## Goal

Make the merged Pull Request state distinct from the reviewed-and-ready-to-merge
state. The existing `arrow.triangle.merge` SF Symbol is visually ambiguous at
sidebar size. The Open state is already acceptable and remains unchanged.

## Design

Keep the existing lifecycle colors and symbols for Open, Draft, and Closed. For
Merged, render a compact GitHub-like merge-topology glyph: three circular nodes
connected by two branch paths that converge into one result. Use the existing
purple merged color. Do not use a checkmark, because the approved review signal
already uses `checkmark.circle`.

The lifecycle icon must have one rendering owner and be reused in both places
where the lifecycle is shown:

- the sidebar Pull Request status icon; and
- the Pull Request status popover header.

The existing 20 by 20 point sidebar frame, hover behavior, tooltip, accessibility
label/value, status signal precedence, and popover behavior remain unchanged.

## Implementation boundary

Add a focused `PullRequestLifecycleIcon` SwiftUI view in the existing Pull
Request status presentation file. It may use SF Symbols for the unchanged
lifecycle cases and a custom SwiftUI path for Merged. Remove the merged-state
dependency on `arrow.triangle.merge` so the lifecycle rendering decision is not
split between a model string and view-specific exceptions.

No changes are planned to Pull Request discovery, lifecycle decoding, colors,
review signals, workspace cleanup behavior, persistence, or user-facing copy.

## Verification

- Build the Argus app target and run focused Pull Request presentation tests, if
  the existing test target covers this presentation boundary.
- Confirm that Open still uses its current branch icon and that Approved still
  uses the checkmark signal.
- Inspect the actual macOS sidebar and status popover at the existing icon size;
  the merged glyph must remain legible and must not resemble a checkmark or the
  current phallic merge symbol.
- Run `git diff --check` and report any broader test or environment blocker
  separately from this focused verification.

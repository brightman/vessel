# Console three-column visual polish

**Status:** Approved by user on 2026-10-17.

## Goal

Use the existing shadcn/ui, Radix UI, Tailwind v4 and Lucide React stack to give the Console an Apple-inspired, calm visual hierarchy. Keep Karama.Cloud's brand identity and all existing data and permission flows.

## Layout

- In Notes, the global navigation and Note folders/list share one left sidebar. The editor is the center column and Note Agent is the right column. Left and right columns collapse independently.
- The global left sidebar remains present for Files, Apps and Teams. Their task-specific panels retain their current behavior in this iteration.
- Notes navigation is rendered inside the global sidebar while Notes is active. The Note editor and Agent retain their current component state and APIs. Closing the Agent hides its column without unmounting it, preserving an active conversation.
- At narrow widths, the sidebar uses the existing compact Console behavior and the Agent becomes a side panel.

## Visual language

- Use one system font stack with clear hierarchy: 28-32px page title, 15-16px body, 13-14px control labels, 11-12px metadata. Avoid heavy bold throughout.
- Use neutral white and warm gray surfaces, subtle dividers and a restrained Karama green accent for primary actions, selected items and focus.
- Normalize navigation to a 40-44px row, 18px Lucide icons, consistent icon and text alignment, 8px spacing rhythm and large enough click targets.
- Expanded navigation has visible labels without tooltips. Collapsed navigation shows tooltips to the right of each icon so they do not cover adjacent menu rows.
- Place API Docs and Sign out in a consistent footer; Sign out uses the same icon, label and row geometry as other navigation actions.

## Behavior and accessibility

- Left and right toggles have accessible names and `aria-expanded`. Keyboard focus remains visible. Collapsing the Agent does not cancel an active run.
- Keep Notes create, folder, archive, version, editing and Agent proposal workflows unchanged. Keep Vessel space role checks and API contracts unchanged.
- Do not add or run automated tests unless the user asks. Build and inspect the exact diff; report any unavailable visual verification.

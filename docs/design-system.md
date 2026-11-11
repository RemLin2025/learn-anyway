# Design system

Status: proposal built on what already exists in `DesignSystem.swift`. Items marked **new** do not exist yet; everything else is current behavior to keep. Not yet approved.

## Principles
1. Function before decoration: no new gradients, glass or animation for their own sake.
2. One shell, one header pattern, one list-pane width on every screen.
3. Native where it is good (menus, sheets, file panels, keyboard); custom only for the brand's look.
4. Every screen has loading, empty and error states with a next step.
5. Text that carries meaning is body size or larger, not caption.

## Tokens (existing)
- Color: `Theme.background / surface / elevated / border / textPrimary / textSecondary / accent / accentFill / mastery / attention / error / sidebar*`, adaptive light/dark. Rule: never raw hex in views.
- Spacing: 4-pt scale `xs 4, sm 8, md 12, lg 16, xl 24, xxl 32`.
- Radius: control 8, card 12.
- Type (rounded, Dynamic Type): page title (`.title` bold), section (`.title3` semibold), card title (`.headline`), body, callout, caption/meta.

## Layout
- **Shell (new rule):** rail (64 collapsed / 208 expanded) | optional list pane | content. List pane width: one token (**new**, proposed 320 pt, resizable 260-420).
- **Screen header (new component `ScreenHeader`):** replaces the empty top band. Leading: title (and breadcrumb for nested content). Trailing: at most three groups: filters/pickers, search, one primary action. Subtitle only when it explains something.
- **Content max width:** forms and settings 760 pt, left-aligned to the header; data views fill width.
- Cards only for grouping unrelated blocks; do not wrap every section. Use dividers inside a single card.

## Navigation
- Rail items: Home, Courses, Library, Question Bank, Skills, Insights, AI Tasks; Settings at the bottom (acceptable), collapse toggle in the View menu and the header leading edge (**new**: View > Show/Hide Sidebar, Cmd+Opt+S).
- Settings: single sidebar inside Settings (existing), same list-pane token, same header.
- Every toolbar action has a menu-bar equivalent (HIG).

## Controls
- Buttons: `.primary` (one per view), `.secondary`, borderless icon buttons for toolbars with `.help` + accessibility label. Minimum hit target 28 pt tall (existing), 44 pt only where touch-like.
- Pickers: use `SegmentedControl` for 2-4 options, and a custom `MenuPicker` (**new**) for longer lists so pop-ups match the theme instead of blue AppKit chrome.
- Inputs: `AppFieldStyle` / `SearchField`. Errors appear under the field, in `Theme.error` with an icon, never color alone.
- Badges: existing `Badge`; semantic colors only (mastery = good, attention = warning, error).

## States
- Loading: skeleton or inline `ProgressView` with text after 400 ms; never "No items" while loading.
- Empty: icon, one-line what this is, one primary action (existing `EmptyStateView`).
- Error: what failed, what to do, retry button.
- Disabled: 55% opacity minimum for text/controls the user may want to understand.

## Motion
- Existing `motion` helper (0.18 s ease-out, respects Reduce Motion). Allowed: hover, selection, expand/collapse, sheet. No parallax, looping or decorative animation. Canvas panning/zooming must not trigger SwiftUI layout of every node (see AI Workflow notes in progress doc).

## Accessibility
- Contrast 4.5:1 for body text (measure the two grey text tokens; **to do**).
- Every icon-only control: accessibility label and `.help`.
- Full keyboard path for primary tasks: Tab order, Return to submit, Esc to close sheets, Cmd+F focuses search on list screens (**new**).
- Support Dynamic Type; check at the largest size (**to do**).
- Selected state conveyed by more than color (existing `.isSelected` traits).

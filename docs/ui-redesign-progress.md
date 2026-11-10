# UI redesign progress

Branch: `ui-redesign`.

## Done
| Commit | Change | Verified (rendered, dark) |
|---|---|---|
| `4365fdb` | Settings General alignment/header/segmented control, nav width, Model Services tabs wrap, Insights empty state + date axis, Home chips, send button, assessment rows, AI Tasks copy | General, Model Services, Insights, Home |
| `ab8aa32` | Audit, research, design-system, progress docs | n/a |
| next | Window title follows the screen (HIG); shared `listPaneWidth()` for list panes; audit corrected ("dead title band" was a snapshot artifact) | Courses; title not visible in snapshots (content view only), checked in code |
| next | `FilterMenu` (themed, replaces AppKit pop-ups) in Question Bank (assessment/skill menus only shown inside a course; cleared when the course changes), Insights, Skills, Usage | Question Bank, Insights, Skills, Usage |
| this | Usage: four summary tiles (requests, tokens, estimated cost, failed %); Provider Plans and Model Services lists grouped: supported first, "Not supported yet" section | Usage, Provider Plans, Model Services |

Not rendered after the changes: light mode, Skills map, AI Workflow, Library, populated chat, minimum window size.

## Status of phases
- Phase 1 audit: done (`docs/ui-ux-audit.md`).
- Phase 2 research: partial (`docs/ui-research.md`); verified sources are HIG sidebars/toolbars, n8n shortcuts, NN/g empty states. No third-party screenshots.
- Phase 3 design system: proposal only (`docs/design-system.md`), awaiting approval.
- Phases 4-6: steps 1 (partly), 2, 3 (Question Bank only), 4, 5 of the plan below are done; 6-8 and the Skills/Library/Home items are open.

## Proposed implementation plan (awaiting approval)
1. **Shell and header** (P1 #1-3): `ScreenHeader` component, remove dead title band, one list-pane width token. Touches `RootView`, `DesignSystem`, every screen's top row.
2. **Controls** (P1 #5): themed `MenuPicker`, replace AppKit pop-ups in Insights, Skills, Question Bank, Settings, Usage.
3. **Question Bank and Skills** (#6-8): collapse filters into search + two chips + "Filters" popover; Skills detail as one card with sections; skill-map toolbar with icon buttons and tooltips.
4. **Model Services / Provider Plans** (#10): group providers by status; keep the catalog table, fix truncation with a two-line cell.
5. **Usage** (#11): summary strip with requests, tokens, estimated cost, error rate; table column priorities.
6. **AI Workflow** (#9): fit shortcut, Space-pan, Cmd+wheel zoom, minimap if cost is small; collapse inherited nodes.
7. **Library and Home** (#12-13): preview pane via Quick Look; move the "no model" warning into the composer.
8. **Accessibility pass**: contrast measurement for the two grey tokens, largest text size, keyboard path, window minimum size.

Each step: build, render with `SnapshotRunner`, compare, commit.

## Decisions needed from you
- Approve the shell/header change (it touches every screen's top area).
- Approve grouping providers by status and moving the legacy Anthropic switch (behavior unchanged, location changed).
- Whether to spend time on further web research first (needs more fetches) or start implementing now.

## Known remaining issues
See audit P2/P3 list. Unresolved: Home chip edge artifacts (cause unknown), Usage table truncation, provider list grouping.

## Manual test checklist (not yet run)
- Resize window to 900x560 on each screen; check clipping.
- Largest text size; VoiceOver rotor through the rail and Settings nav.
- Keyboard-only: reach Practice, submit an answer, open Settings, change appearance.
- Light mode on every screen (only Home, Skills map, Insights were rendered light previously).

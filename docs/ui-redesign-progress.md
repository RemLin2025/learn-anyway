# UI redesign progress

Branch: `ui-redesign`.

## Done
| Commit | Change | Verified |
|---|---|---|
| `4365fdb` | Settings > General: left-aligned, own title/subtitle, themed Appearance control, legacy Anthropic card moved last, nav width 212; Model Services capability tabs wrap; Insights empty study-time state and date axis; Home sixth suggestion chip; send button disabled opacity; assessment rows always two lines; AI Tasks helper copy | Built; re-rendered General, Model Services, Insights, Home (dark). Not re-rendered: Provider Plans, Workflow, Usage, light mode |

## Status of phases
- Phase 1 audit: done (`docs/ui-ux-audit.md`).
- Phase 2 research: partial (`docs/ui-research.md`); verified sources are HIG sidebars/toolbars, n8n shortcuts, NN/g empty states. No third-party screenshots.
- Phase 3 design system: proposal only (`docs/design-system.md`), awaiting approval.
- Phases 4-6: not started beyond the commit above.

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

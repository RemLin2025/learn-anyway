# UI/UX audit

Status: Phase 1 complete, 2026-11-10. Branch `ui-redesign`.

## Architecture (from the code)
- Native macOS 15+, SwiftUI, built with `scripts/build.sh app` (direct `swiftc`; no Xcode).
- Design tokens already exist in `Sources/BraincellApp/DesignSystem.swift`: `Theme` colors (light/dark), a 4-pt `Space` scale, `Radius`, rounded type styles, `Card`, `PageHeader`, `PrimaryButtonStyle`, `SecondaryButtonStyle`, `AppFieldStyle`, `SearchField`, `SegmentedControl`, `SidebarView`, `sidePanel()`, `controlStrip()`.
- Navigation: `SidebarItem` rail in `RootView` (Home, Courses, Library, Question Bank, Skills, Insights, AI Tasks) plus Settings. Settings is an in-app screen with its own second sidebar (General, AI Provider Plans, Model Services, AI Workflow, Usage & Analytics).
- Built-in test rig: `SnapshotRunner` writes PNGs of the real window (`BRAINCELL_SNAPSHOT_DIR`, `BRAINCELL_SETTINGS_SNAP`). All findings below come from those renders unless marked "code only".

## Screens inspected (rendered, dark; Home also light)
Home chat (empty), Courses > Assessments, Library, Question Bank, AI Tasks, Practice (choice), Skills (list and map), Insights, Settings > General, Provider Plans, Model Services, AI Workflow (model map), Usage & Analytics.

**Not inspected:** Courses > Topics and Materials tabs, a populated chat conversation, Practice types other than single choice, grading and summary screens, dialogs and sheets, window at minimum size (900x560), largest text size, VoiceOver. The a11y audit file in the snapshot dir only counts unlabeled controls (0 found); it is not a full audit.

## What already works
- One token system, light and dark, consistent primary/secondary buttons.
- Practice screen is calm; the single primary action is clear.
- Honest copy about evidence quality and "Preliminary" mastery.
- Reduce Motion is respected in the `motion` helper.

## Findings

### P1: structural, affects every screen
1. **Dead title band.** About 88 px of empty dark space above content on every screen. Content starts low, and screens without a page title (Insights, Skills, Question Bank, Library with a different header) look unanchored. HIG: the toolbar/title area should carry the view title and actions (HIG Toolbars).
2. **No shared screen frame.** Each screen builds its own header: Home has a chat title row, Courses a big title + tabs, Library a title + chips + search + button in one row, Insights a "Course" picker row, Skills a different picker row, Question Bank a 6-control filter row. Same job, six layouts.
3. **List-pane width and chrome differ per screen** (about 430 / 500 / 540 px; different divider and selection styles). Selected rows use a flat grey in lists and a blue tint in the nav.
4. **Settings has two sidebars stacked next to the main rail**, so three columns of navigation before content. Settings sub-pages mix three header styles (General had a different title, Workflow has a title without a subtitle, others have a title and subtitle). Partly fixed in `4365fdb` (General).
5. **Native controls clash with the custom look.** Pop-up menus and steppers render with macOS blue chrome beside the app's own pills and buttons (Insights, Skills, Question Bank, Settings, Usage).

### P2: per-feature usability
6. **Question Bank filter row has 6 controls plus More plus Views.** Several menus are disabled ("Any assessm…", "Any skill") with truncated labels; row is dense and does not wrap. Count "9 questions" is tiny and far right.
7. **Skills detail is a long stack of cards** (Level, Mastery, Recent evidence, Recent mistakes) with 12 px grey caption text carrying important caveats. The skill list on the left has only two chips per row and a large empty area.
8. **Skill map toolbar uses bare text buttons** ("Reset", "Collapse all") next to magnifier icons; legend text is tiny.
9. **AI Workflow model map** at 70% shows a long vertical list of near-identical nodes (name, model, provider, "Inherited"), with a connector rail at the far left. Readable, but 20+ nodes in two columns give little overview; there is no minimap, no fit-to-view shortcut visible, and "Select a task…" is an unlabeled pop-up. (Zoom control bottom-left works and is compact.)
10. **Model Services:** five providers marked "Not supported yet" sit between working ones; the list is long and has no grouping. Fixed in `4365fdb`: capability tabs no longer clip. Still open: provider list grouping, model-name truncation with identical prefixes ("Vendor 0 Model 108 Long Display N…").
11. **Usage & Analytics:** table scrolls horizontally and truncates Task and Model; only two stat tiles (requests, tokens) while cost, latency and error rate, which the table has, are not summarized.
12. **Library:** very sparse in the demo (one course row, "0 items"); list columns (size, kind, date) are far apart; no preview pane shown in the list view.
13. **Home chat:** an amber warning banner is the most prominent element on first launch, above the composer; the prompt chips and composer are good. Faint vertical lines at the chip edges (render artifact, cause not found).

### P3: polish
14. Small grey secondary text (about 11-12 pt) is used for meaning, not just decoration (Practice shortcuts "1 2 3", "Last import…", Insights captions). Contrast not measured.
15. Sidebar collapse toggle sits at the bottom of the rail; HIG says avoid critical actions at the bottom of a sidebar. Settings also sits there; acceptable but note.
16. Insights skill-trend dates repeat ("Nov 10") for same-day demo data; the real data will span days.

### Code-only observations (not seen rendered)
- `SidebarView` honors `sidebarCollapsed` from `@AppStorage`; first render in the snapshot rig used the collapsed state, so labels were not visible in the first screenshots. Labels and `.help` tooltips exist when expanded.
- Window `minWidth: 900, minHeight: 560` is set; behavior at that size has not been checked.

## Corrections to the earlier (UXKIN-style) review
- "Practice progress bar empty": wrong. It shows submitted answers, not position.
- "Icon-only nav has no labels": wrong. It was the collapsed state.
- "Library chip spacing uneven": wrong. Padding is uniform; width differences come from label text.

## Fixed so far (commit `4365fdb`)
General settings alignment, header and segmented control; Settings nav width; Model Services capability tabs wrap; Insights empty study chart and date axis; Home chip grid; send-button disabled state; assessment row heights; AI Tasks helper copy.

# UI research

Status: Phase 2, partial. Written 2026-11-10.

## Method and honest limits
- Fetched and read in full: the Apple HIG pages for Sidebars and Toolbars; the n8n keyboard-shortcuts page; the NN/g empty-state article (summarized by the fetch tool, not read in full).
- Search results only (not opened): macOS design-guideline summaries from third parties; unrelated workflow-editor docs (Flint, AirOps, Fuser, Flora, Boltic); empty-state articles from SAP Fiori, PatternFly, Workday, Canva.
- **Not accessed:** Mobbin (requires an account), screenshots of any third-party app. I have no reference screenshots. Statements below about Notion, Linear, Finder, Raycast, ChatGPT, Obsidian etc. come from general knowledge, are labelled "unverified", and should be checked before they drive a decision.
- The brief asks for at least three examples per feature. I have fewer than that, verified, for every feature. The next research step (below) is to close that gap with fetched docs.

## Verified sources and what they say

### Apple HIG, Sidebars
Source: https://developer.apple.com/design/human-interface-guidelines/sidebars (fetched)
- A sidebar navigates top-level areas or collections. Show at most two levels of hierarchy; use disclosure controls for more.
- Let people hide it; avoid hiding it by default so it stays discoverable.
- Use familiar SF Symbols; sidebar icon colors should follow the accent color unless a fixed color has a clear purpose.
- macOS: row height and text scale with a user "sidebar icon size" setting; consider auto-collapsing when the window narrows; do not put critical information or actions at the bottom (windows get moved so the bottom edge is hidden).
- Applies to us: rail is icon-only when collapsed (fine), but Settings and the collapse toggle are bottom-pinned, and Settings adds a second sidebar.

### Apple HIG, Toolbars
Source: https://developer.apple.com/design/human-interface-guidelines/toolbars (fetched)
- A toolbar holds: view title, navigation, actions. Leading edge: back, sidebar toggle, then title. Trailing edge: important actions, search, More menu, one primary action.
- Do not use the app name as a window title; keep titles under about 15 characters.
- Prefer symbols without borders; do not mix a text-labelled button next to a symbol button without spacing.
- At most about three groups; do not let items overflow by default.
- Every toolbar item should also be a menu-bar command, because toolbars can be hidden or customized.
- Applies to us: the 88 px empty band is where the title and a right-aligned action group should live. Screens currently scatter pickers, text buttons and bordered pills.

### n8n canvas controls
Source: https://docs.n8n.io/build/keyboard-shortcuts (fetched)
- Zoom: Cmd/Ctrl + wheel, +/-, 0 to reset, 1 to fit the whole workflow.
- Pan: Space + drag, middle-mouse drag, Cmd/Ctrl + left-drag, two-finger scroll.
- Select: Cmd/Ctrl+A, arrow keys select the nearest node in that direction.
- Tidy-up is reachable from the Command Bar (Cmd/Ctrl+K), not a shortcut. Canvas buttons: zoom to fit, zoom in/out, reset zoom, tidy up (from the n8n Level One course page, search snippet only).
- Applies to us: our canvas has zoom -/+/fit buttons bottom-left, which matches. Gap to check: Space-drag and Cmd+wheel behavior, fit shortcut, arrow-key node selection.

### NN/g, empty states
Source: https://www.nngroup.com/articles/empty-state-interface-design/ (fetched, summarized)
- Do not leave states blank; show accurate status and not "no records" while still loading.
- Teach what the feature does and how content gets added; give a direct next step; consider demo data.
- Applies to us: Insights charts with no data (partly fixed), Library with only a course row, AI Tasks with no tasks, Skills with no evidence.

## Patterns proposed per feature (to be validated)

| Feature | Verified reference | Unverified reference (check before relying) | Pattern to adopt |
|---|---|---|---|
| App shell | HIG Sidebars, HIG Toolbars | Notes / Mail / Linear on macOS | One shell: rail + optional list pane + content, one title/action band, one list-pane width token |
| Home / chat | NN/g empty states | ChatGPT desktop, Claude desktop, Raycast AI | Keep composer-first layout; collapse the "no model" banner into the model picker and a single inline hint |
| Courses | HIG Sidebars (2 levels max) | Notion, Obsidian vault | Course = folder-like object with tabs; start-practice is the one primary action |
| Library | HIG Toolbars (search + view toggle on trailing edge) | Finder (columns/list/gallery, Quick Look) | Keep grid/list; add preview pane via existing Quick Look; consistent trailing toolbar group |
| Model services | n/a | Xcode/VS Code settings, Raycast model picker, OpenRouter catalog | Group providers by status (Connected / Available / Not supported yet, collapsed); searchable, virtualized model table |
| AI workflow | n8n shortcuts | n8n, Figma canvas | Fit-to-view + minimap, Space-pan, Cmd-wheel zoom, arrow selection; collapse "Inherited" nodes into a summary |
| Usage | n/a | Stripe/OpenAI usage dashboards | Summary strip (requests, tokens, cost, error rate) above the table; table columns that wrap or have fixed priorities |

## Next research steps (needs your OK for the time)
1. Fetch docs for at least two more verified references per feature: Apple HIG (Split views, Search fields, Lists and tables, Menus, Accessibility), Material Design data tables, Linear/Raycast/Obsidian public docs, VS Code settings UX guidelines, OpenRouter model-list docs.
2. If you can sign in to Mobbin in the in-app browser, I can capture chat, settings and library references; otherwise I will skip Mobbin.

# Maps — `UXMAP`

Recipe: `map-locations.md`. No runtime companion in `apex-sentinel/checks/` yet. Drawn from WCAG 2.2 and Oracle's map-page policy; the example catalog has no map page, so no row cites it.

| ID | Criterion | Sev | By | Source |
|---|---|---|---|---|
| `UXMAP-TEXT-ALTERNATIVE` | every record a marker reaches is also reachable from a report or list of the same rows on the page; the map is never the only route | ADVISE | static + runtime | WCAG 1.1.1, 2.1.1; repo `recipes/map-locations.md` |
| `UXMAP-REGION-NAME` | the map region has a name that says what it shows ("Branch locations"), not "Map" | ADVISE | static + runtime | WCAG 1.3.1, 4.1.2 |
| `UXMAP-VIEWPORT-FITS` | the first view contains every marker the layers draw; nothing starts off screen (a `boundingBox` does not do this — it limits panning) | ADVISE | runtime | Oracle map-page; repo `recipes/map-locations.md` |
| `UXMAP-UNPLACED` | rows with no coordinates are accounted for: the page says how many are not on the map, and they appear in the companion list | ADVISE | static + runtime | repo `recipes/map-locations.md` |
| `UXMAP-FILTER-SCOPE` | when facets filter the map, a list beside it either shows the same set or says that it shows every row | ADVISE | runtime | repo `recipes/map-locations.md` |
| `UXMAP-LEGEND-TEXT` | what a marker's colour or shape means is in a legend with words (`UX-NO-COLOR-ONLY`) | ADVISE | static + manual | WCAG 1.4.1 |
| `UXMAP-MARKER-LABEL` | a marker's tooltip or info window names the record, enough to tell two neighbours apart | ADVISE | runtime | WCAG 2.4.4 |

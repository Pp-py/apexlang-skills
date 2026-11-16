# Recipe: map (branches, deliveries, areas)

**Use for:** rows whose meaning is *where* — branches, customers to visit, deliveries, coverage
areas. A column of addresses in a report answers "what is the address of X"; a map answers "what is
near here", which no report does.

Read-only: **no package**. The layers read a table or a `v_*` view. Data-side rules: `ui-contracts.md`.
Grammar: Oracle's `region-components/map/` family (26.1) and `apex.map-page.md` — region, layers,
backgrounds, bounding boxes. This recipe covers what they leave open: which geometry the view
projects, where a derived location lives, and what a map never replaces.

**Measured** on APEX 26.2.0 (2026-11-16, a 26.1 source compiled and imported with SQLcl 26.2.0, driven
in a browser): a longitude/latitude point layer from a view, the first viewport, facets over the
map, the companion list, a marker's link, a location written through its package, an
`SDO_GEOMETRY` point layer and a GeoJSON polygon layer, `ux-check.py` (PASS, two reflow advisories
at 320/375 px). **Not measured:** a spatial operator (distance, nearest neighbour), heat maps,
geocoding. Two of Oracle's 26.1
statements did not survive the compiler or the browser; both are named below.

**Contents:** which geometry · what a layer projects · the viewport · selection and drill-down ·
the map is never the only way in · filters · when the location is written · common mistakes.

## Which geometry the view projects

| The data is | Project | Because |
|---|---|---|
| points, already as two numeric columns | `longitudeLatitude` (two aliases) | nothing to convert; no spatial index needed for a few thousand points |
| points to search by distance, areas, routes | `sdoGeometry` (one `SDO_GEOMETRY` column, indexed) | "within 5 km", nearest neighbour and containment are spatial operators, not arithmetic on two columns |
| shapes that arrive from another system | `geojson` | store what was received; convert only if you must query it |
| only a text address | nothing yet | geocode first — once, when the address is written — and store the result |

Oracle's Sample Maps (APEX 26.2) uses `SDO_GEOMETRY` for 21 of its 27 layers; the four
longitude/latitude layers in the sample applications are all point layers over search results.
All three mappings were built here: `longitudeLatitude` (above), `sdoGeometry` with
`geometryColumn` over a view that builds the point, and `geojson` with `geojsonColumn` over a CLOB,
as a `layerType: polygons` layer — two layers of one map, each reading its own table.

**Longitude first.** Every API here is (longitude, latitude); a swapped pair draws the point in the
wrong hemisphere and nothing fails.

## What a layer projects

```sql
create or replace view v_branch_locations as
select b.branch_id, b.name, b.address_line, b.city,
       b.longitude, b.latitude,
       case b.status when 'OPEN' then 'Open' when 'CLOSED' then 'Closed' else 'Planned' end as status_label
  from branches b
 where b.longitude is not null and b.latitude is not null
```

```
region branch-map (
    type: map
    source { location: localDatabase  type: sqlQuery  sqlQuery: ```sql
        select branch_id, name, city, status_label, longitude, latitude
          from v_branch_locations``` }
    initialPositionAndZoom { type: basedOnSpatialResults }
    layer branches (
        name: Branches
        source { location: regionSource }
        columnMapping { geometryColumnDataType: longitudeLatitude
                        longitudeColumn: LONGITUDE  latitudeColumn: LATITUDE
                        primaryKeyColumn: BRANCH_ID }
        tooltip { column: NAME }
    )
)
```

- **The query belongs to the region, the layer reads `regionSource`.** A layer may carry its own
  query or table, but then nothing can filter the map: a `facetedSearch` whose `filteredRegion` is a
  map with no region source does not compile (*Conditions not met for reference*).

- One layer per kind of thing (branches, customers), not one layer per state: a state is a legend
  entry or a filter.
- The tooltip and the info window read columns the view projects as text. No HTML in the query
  (`ui-contracts.md` §2).
- Rows with no coordinates are left out by the view, and the page says how many
  (`apex-ux` `UXMAP-UNPLACED`): a branch missing from the map looks like a branch that does not exist.
- A layer's meaning is in the legend with words, not only a colour (`UX-NO-COLOR-ONLY`).

## The viewport fits the data

Oracle's rule stands: *"Multi-marker maps must use a viewport that fits the marker set."* Its
recommended means does not deliver it. *"Prefer a SQL-derived `boundingBox`"* — measured, with a box
computed from the min and max of the layer's own view plus half a degree: the map opened showing
three of six markers. `boundingBox` is the limit the user can pan within, not the first view; on a
wide map it is fitted by width and the northern and southern points start off screen.

What fits the markers is `initialPositionAndZoom { type: basedOnSpatialResults }` — measured: all
six in the first view. (Oracle's template names this mode `queryResults`; the compiler accepts
`basedOnSpatialResults`, `sqlQuery` and `staticValues`.) Add a `boundingBox` only to keep the user
from panning away from the area the application is about. Never centre on an average with a fixed
zoom — Oracle's own map page example does — and keep a fixed position for one known place.

## Selection and drill-down

A marker that opens a record carries a declarative target — Oracle: the layer *"must include a
declarative `link { target: { page, items } }`"* that passes the key in `primaryKeyColumn`. It is a
target, never a URL built in the view (`ui-contracts.md` §3). Measured: `link { type:
redirectThisApp  target: { page  items: { P21_BRANCH_ID: &BRANCH_ID. } } }` on the layer opened the
branch's drawer from its marker, and the same target on the list's `type: link` column opened it
with no map involved. A map beside a report of the same rows keeps one selection: the report's row
and the marker name the same key (`ui-contracts.md` §8).

**Refresh both.** The dialog-closed event fires on the region the dialog was opened from. Measured:
a location saved from the list refreshed the list and left the map showing the old markers until
the page was reloaded. Each region that can open the dialog refreshes every region that shows the
data.

## The map is never the only way in

Everything a marker reaches must be reachable without the map: a report or content row of the same
rows on the page — beside the map, under it, or as the other tab. A map cannot be scanned by a
screen reader, sorted, or searched by name; and a place with no coordinates is not on it at all.
Measured: the map's keyboard stops are the canvas and its zoom buttons — no marker is one.
This is the difference between a map that helps and a page that is only a map
(`apex-ux` `UXMAP-TEXT-ALTERNATIVE`).

## Filters

A `facetedSearch` filters a map as it filters a report — `filteredRegion` names the map, given the
region-level source above (`master-faceted-search.md`). Measured: a facet on the status took the map
from six markers to one.

**It filters the map and nothing else.** One `facetedSearch` has one `filteredRegion`: the companion
list on the same page kept all seven rows. So the list is one of two things, and the page says
which: the complete register (every branch, placed or not — what the text alternative needs), or a
second view that must be filtered by other means. Do not present an unfiltered list under a filtered
map as if they showed the same set.

## When the location is written

Reading a map needs no package. Changing a location does: a `geocodedAddress` item or a pin the
user drops is input like any other, and the form that holds it saves through the entity's package
(`form-page-to-package.md`). The package owns what a valid location is — inside the country, not
(0, 0), consistent with the address — and derives the `SDO_GEOMETRY` from the pair in the same
`UPDATE`, so the two can never disagree.

Measured, with `update_location(p_branch_id, p_longitude, p_latitude, p_row_version)` behind an
`invokeApi` process: a swapped pair was refused as outside the country, one coordinate without the
other was refused, each with the package's sentence in the drawer; the valid pair was stored and
the branch appeared on the map. The swapped pair is the mistake to expect — make the message say so.

## Common mistakes

| Tempting | Why wrong |
|---|---|
| Centre on `avg(latitude), avg(longitude)` at zoom 4 | An arbitrary point; outlying rows are off screen. `basedOnSpatialResults`. |
| A `boundingBox` to "fit the markers" | It limits panning; half the markers started off screen. |
| The query on the layer, then a facet over the map | Does not compile: the filtered map needs the region-level source. |
| Distance in SQL with arithmetic on two number columns | Wrong away from the equator and unindexable. `SDO_GEOMETRY` and a spatial operator. |
| Geocoding in the layer's query | A service call per row per render. Geocode on write; store the result. |
| A map and nothing else | Rows without coordinates vanish, and the page has no keyboard or screen-reader route to a record. |
| One layer per status with a hard-coded colour each | The set of states is now spread over N layers; a new state is a new layer. One layer, the state as a projected value. |

## Verify

`apex-sentinel`: the map draws, every marker of the view is inside the first viewport, a marker
opens its record, and the count on the page matches the view. No check file for this archetype
exists yet — say what you ran. A marker is a canvas pixel, not an element: read the map through
`apex.region(<id>).getMapObject()` (`queryRenderedFeatures`, `project`). `apex-ux`: `criteria/map.md`.

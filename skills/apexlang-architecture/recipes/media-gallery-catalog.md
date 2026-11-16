# Recipe: catalog with pictures (products, properties, vehicles)

**Use for:** records people recognise by sight — a product catalog, a property listing, a fleet, a
menu. If the user would say "the red one", the page needs the picture.

**REQUIRED BACKGROUND:** `ui-contracts.md` §1 (cards or content row), §2; `attachments-to-package.md`
(the image is a file: who writes it, the file rules, the read scope). Grammar: Oracle's
`region-components/cards/` family and `apex.region-media.md` (26.1).

**Measured** on APEX 26.2.0 (2026-11-16, a 26.1 source compiled and imported with SQLcl 26.2.0, driven
in a browser): cards with BLOB media and its attributes, the text alternative, a row with no image,
a facet over the cards, `ux-check.py` (PASS). **Not measured:** the upload, the read scope, URL
media, `mediaList`.

**Contents:** which component · what the query projects · the description of an image · facets and
order · upload · common mistakes.

## Which component

| The image is | Component | Because |
|---|---|---|
| a BLOB in your table | `cards`, `media { source: blobColumn }` | the one browse region with a BLOB media contract (Oracle: *"Cards BLOB display uses"* that block) |
| a URL the application manages (static files, object storage) | `cards`, `media { source: urlColumn }` | — |
| an avatar or icon beside a title and a line of text | `themeTemplateComponent/mediaList` | a list, not a gallery; URL images only — Oracle: *"do not infer BLOB contracts"* |
| one image on a record's own page | `displayImage` item | a single picture is not a gallery (`item-detail-page.md`) |
| decoration | none | an image that says nothing is noise |

`media.position: first` with `sizing: cover` gives a gallery; `background` puts text over the
picture and needs the contrast checked on every image, not on the sample one.

## What the query projects

```sql
select p.product_id, p.name, p.short_description,
       to_char(p.list_price, 'FML999G999G990') as price_label,
       p.photo,                                  -- the raw BLOB: Cards reads it, the browser never gets it from SQL
       p.photo_mime_type, p.photo_updated_on,
       p.photo_alt
  from v_products p
```

```
appearance { template: @/cards-container }
card  { primaryKeyColumn1: PRODUCT_ID }
title { column: NAME }   body { column: SHORT_DESCRIPTION }
media { advancedFormatting: false  source: blobColumn  blobColumn: PHOTO
        position: first  sizing: cover  imageDescription: &PHOTO_ALT. }
blobAttributes { mimeTypeColumn: PHOTO_MIME_TYPE  lastUpdatedColumn: PHOTO_UPDATED_ON }
```

- The primary key is required for any region that displays a BLOB, and the MIME type and
  last-updated columns travel with it. Measured: each image is served with the stored MIME type,
  `Cache-Control: must-revalidate, max-age=0` and a validator — the browser asks again on every
  visit and can be answered "not modified", which is what the last-updated column is for. It is not
  a long-lived cache: heavy images are still a request each.
- A row with no photo shows the card without media (measured: no media block, no broken image), or
  one placeholder the application ships as a static file — never a `NULL` URL.
- No `<img>` in the query and no download URL assembled in SQL (`ui-contracts.md` §2, §3): the
  region resolves the BLOB by key.
- **The scope is the view's.** Cards serves the image for whatever row the query returns; a product
  a user may not see must be absent from `v_products`, not merely hidden on the page
  (`attachments-to-package.md` §Reading).
- Store a display-sized image. A 6 MB camera original in a 24-card grid is 144 MB of page; resize on
  write (below) and keep the original separately if it is needed at all.

## The description of an image

`imageDescription` is the image's text alternative, and it comes from the row — Oracle: *"Map
accessible image text with `media.imageDescription`"*. Measured: `imageDescription: &PHOTO_ALT.`
reaches each image's `alt` with that row's text. Three cases:

- the title already names what the picture shows → the description may repeat nothing: leave it
  empty so the name is not read twice;
- the picture adds information (colour, condition, a floor plan) → a column the entity owns
  (`photo_alt`), entered with the photo;
- never the file name, never "image".

## Facets and order

A catalog is browsed by attribute: category, price range, availability. That is a `facetedSearch`
over the cards (`master-faceted-search.md`), with the closed sort list and the primary-key
tie-breaker of `ui-contracts.md` §1. An `interactiveReport` with an image column is the wrong tool:
it offers column operations nobody performs on pictures.

## Upload

The photo is a file on a record, so it is written as `attachments-to-package.md` says: an
`imageUpload` item (crop and preview in the browser) or `fileUpload`, temporary storage, and the
entity's package stores it — size, declared type and leading bytes checked on the server.

**Unit of work.** The photo, its MIME type, `photo_updated_on` and the alt text change in the same
`UPDATE` as the row version; an edit that picks no new file keeps the stored one.

If the photo is a column of the product, the product's package writes it. If a product has several
photos, they are rows of a satellite table (`product_photos`: FK, position, one flagged as cover)
owned by the same package (`package-boundaries.md` §Test 1), and the catalog's view projects the cover.

## Common mistakes

| Tempting | Why wrong |
|---|---|
| A Classic Report with an `<img src="…">` built in SQL | Markup and a URL in the query; no caching metadata; no text alternative. |
| `mediaList` over a BLOB column | Oracle's contract covers URL images only for it. Use cards. |
| The file name as `imageDescription` | "IMG_4471.jpg" is read aloud on every card. |
| Hiding unauthorised products with a server-side condition on the card | The image is served by key for any row the query returns. Filter in the view. |
| Storing camera originals and letting CSS shrink them | The page weighs what the files weigh. |

## Verify

`apex-sentinel`: the grid shows the images, a row without a photo shows no broken image, each image
answers with its stored type and a validator, and a key outside the view's scope returns no image.
`checks/browse-search.md` covers the facets. `apex-ux`: `criteria/browse-search.md` (`UXBRW-MEDIA-*`).

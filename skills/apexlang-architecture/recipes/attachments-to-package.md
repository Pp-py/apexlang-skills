# Recipe: file attachments (upload, replace, preview, download) → write-path package

**Use for:** a record that carries a file the user uploads and later previews or downloads — a receipt on an expense line, a contract scan, a profile photo. The file is a BLOB column on the entity, or on a table of its own that points at it.

**REQUIRED BACKGROUND:** `back-end-conventions.md` (single write-path, §4 unit of work, §6 retention, §7 version token); `form-page-to-package.md` (the form this plugs into); `package-boundaries.md` §Test 1.

**Contents:** status, and where Oracle stands · the contract (keep, replace, remove, cancel) · who writes · file rules · reading · temporary files · when the parent is deleted · unit of work · common mistakes · verify.

## Status, and where Oracle stands

**Not validated end to end.** Oracle's side, checked against its installed policies: the `fileUpload` item and its `storage { type: appTempFiles  fileTypes  maxFileSize }` (the file-upload template: *"Proven storage type: `appTempFiles`."*, the size in KB), and the BLOB display contract (`apex.region-media.md`: *"Any region displaying a BLOB must include primary keys for lookup."* and *"Raw LOB projection is display-only."*). Oracle's route for a stored upload is a form region with the upload item bound to the BLOB column and written by Automatic Row Processing — the part P1 closes (`form-page-to-package.md` §Why no `form` region). This recipe keeps the item and drops the binding: the same template says to omit `source {}` *"when the item is not bound to persisted data or a form region."*

Ours, and **not validated** — not compiled by SQLcl, not run on APEX: the two thin `executeCode` wrappers below (one reads `apex_application_temp_files`, one streams a BLOB). KC-4 admits wrappers for a grid save, a loader and a branch-gated flow, not these. Open: that a wrapper can read the temporary file, that `invokeApi` cannot take the item's value instead, and when APEX purges temporary files. Until a `framework/CAPABILITIES.md` row says otherwise (P6), treat both wrappers as unvalidated and validate them with `apexlang-inventory` and SQLcl before relying on them.

## The contract

| Action | What the package does |
|---|---|
| Create | The file is required: `create_row` refuses a NULL `p_content`. The item's `valueRequired` is only a hint |
| Edit, no file chosen | `p_content` NULL means **keep**: bytes, name, type and `file_updated_on` do not change |
| Edit, another file | Bytes, name and type change in the **same** `UPDATE` that bumps `row_version` (§7) |
| Remove the file | An explicit operation (`remove_file`, or `delete_row`) and only when the file is optional. An empty item never means delete |
| Cancel | Writes nothing: a chosen file exists only in the temporary area |

```plsql
PROCEDURE create_row (p_report_line_id IN NUMBER, p_caption IN VARCHAR2, p_file_name IN VARCHAR2,
                      p_mime_type IN VARCHAR2, p_content IN BLOB, p_receipt_id OUT NUMBER);
PROCEDURE update_row (p_receipt_id IN NUMBER, p_caption IN VARCHAR2, p_file_name IN VARCHAR2,
                      p_mime_type IN VARCHAR2,
                      p_content IN BLOB,                    -- NULL = keep the stored file
                      p_row_version IN OUT NUMBER);
```

## Who writes

Rules about the file itself — what may be stored, who may replace it — are rules of its own, so by `package-boundaries.md` §Test 1 clause 4 the attachment table is normally an entity with its own package, which validates the FK to the parent it receives. A table with no rules of its own is a satellite, and the parent's package writes it. Never DML in the page process. Two attachment tables share one `pkg_file_rules` function with no DML (P2).

## File rules: the server decides

The item's `fileTypes` and `maxFileSize` are early feedback; the browser sends whatever it likes. The package checks, before any DML: the size, the name length, the declared type against an allowed set **and** the leading bytes against that type. A refusal raises a friendly `-20xxx` and writes nothing, and a `CHECK` on the type column backs it up.

The allowed set, the limit and the signature table are **declared per entity** in the package header, in prose, as that entity's choice. No size, format list or signature length here is a framework value: an example that shows 10 MB, three formats or four signature bytes shows one app's declaration. The declared type is what the browser said and the bytes are what the file is, so check both.

## Reading: one scope, however many routes

Preview and download are different routes — a native image display (`displayImage`, a region's query) and a process that streams the BLOB. They share **one scope**: both resolve the record through the view (or VPD policy) the list that issued the link reads; if the rule needs PL/SQL, the view calls one predicate function of the owning package. Never by the key alone.

- A checksum on the key and a role scheme on the page are not authorization. The scope applies where the link is issued and where it is resolved.
- "Every signed-in user reads every file" is a valid scope when it is declared. The undeclared one is the defect.
- A key that does not exist and a key out of scope get the same refusal.
- The type served is the stored, validated one, never the request's; `inline` only for the types the app lists as safe to render, everything else as an attachment.

```
process stream-file (
    type: executeCode
    source { plsqlCode: ```plsql
        -- thin wrapper: streams one stored BLOB. NOT VALIDATED (Status).
        declare l_name VARCHAR2(255); l_mime VARCHAR2(255); l_blob BLOB;
        begin
          select file_name, mime_type, file_content into l_name, l_mime, l_blob
            from v_receipt_files where receipt_id = :P9_RECEIPT_ID;   -- the list's scoped view
          apex_http.download(p_blob => l_blob, p_filename => l_name, p_content_type => l_mime, p_is_inline => false);
        exception when no_data_found then raise_application_error(pkg_errors.k_file_not_found, 'File not found.');
        end;``` }
    execution { point: processing }
)
```

## Temporary files

The upload item is `type: fileUpload` with `storage { type: appTempFiles ... }` and no `source {}`. The save is a thin `executeCode` wrapper that reads that row and hands the bytes to the package, which knows nothing of APEX and so is testable from SQLcl:

```plsql
-- thin wrapper: hands the uploaded temp file's bytes to the owning package. NOT VALIDATED (Status).
declare l_name VARCHAR2(255); l_mime VARCHAR2(255); l_blob BLOB;
begin
  if :P6_FILE is not null then
    select filename, mime_type, blob_content into l_name, l_mime, l_blob
      from apex_application_temp_files where name = :P6_FILE;
  end if;
  pkg_receipts.update_row(p_receipt_id => :P6_RECEIPT_ID, p_caption => :P6_CAPTION,
      p_file_name => l_name, p_mime_type => l_mime, p_content => l_blob,   -- NULL = keep
      p_row_version => :P6_ROW_VERSION);
end;
```

Clear the file item on a normal load, so a stale choice is not submitted twice. A wizard that carries files between steps stages them in a table its package owns, never `apex_collection` (`wizard-multi-step.md`).

## When the parent is deleted

An `ON DELETE CASCADE` removes files without passing through their owning package. The retention decision for the parent (`back-end-conventions.md` §6) names the files among the dependents it removes, and says whether the package deletes them or the cascade does.

## Unit of work

Save commits the row and its file in one submit, or neither. Cancel after choosing a file writes nothing. An attachment drawer opened from a form commits on its own submit, so cancelling the form does not undo it (`back-end-conventions.md` §4).

## Common mistakes

| Tempting | Why wrong |
|---|---|
| Serve by `receipt_id` alone because the item carries a checksum | The checksum stops forged ids, not a link issued to the wrong user. Resolve through the list's scope |
| Trust `fileTypes` and `maxFileSize` on the item | The browser is not the check. The package validates from the stored bytes |
| An empty item on edit means "delete the file" | It means keep. Removal is a named operation |
| A MIME check on the declared type only | The declared type is a claim. Compare the leading bytes too |
| `ON DELETE CASCADE` with no word on the files | The cascade skips the owning package. Declare it in the retention decision |

## Verify

By hand until a check defines criteria for it; none of this has run against a real app. In the browser, then `sql -name <conn>` for the data side (`dbms_lob.getlength`, and a hash if the test schema may call `dbms_crypto`, else `dbms_lob.compare` against a reference): create without a file (refused, no row) and with one; edit without choosing a file (bytes unchanged); replace; refuse a wrong type, an oversized file, a name over the column and a right type over wrong bytes (friendly message, nothing changed); cancel after choosing a file (row identical); two sessions replacing the same row (the second gets `k_row_changed`). Reading: the file URL without a session (`sec-probe.py --anon`), with a tampered checksum (`--tamper`), and as a second test user outside the scope, by hand — no probe checks a per-record scope. The criteria are `SEC-DOWNLOAD-AUTHZ` and `SEC-UPLOAD-SERVER-RULES` (`apex-security/criteria.md`).

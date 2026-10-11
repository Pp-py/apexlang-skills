# Data entry — `UXENT`

Recipes: `form-page-to-package.md`, `modal-crud-to-package.md`, `editable-ig-to-package.md`, `master-detail-edit.md`, `wizard-multi-step.md`, `versioned-vigency-record.md`. Runtime companions: `apex-sentinel/checks/form-page.md`, `modal-crud.md`, `editable-ig.md`.

| ID | Criterion | Sev | By | Source |
|---|---|---|---|---|
| `UXENT-PRESENTATION` | a create or edit form opened from a report is a drawer at the end; a centered modal only when asked for; a full page when the form is long | ADVISE | static | Oracle form; ex: CAT 26.1.6 data-entry |
| `UXENT-REQUIRED` | a required field has `valueRequired: true` and the `@/required-floating` template, so it is marked visibly and announced | ADVISE | static | Oracle form, templates; WCAG 3.3.2. The example catalog's drawer form marks none: do not copy it |
| `UXENT-BUTTONS` | one hot primary button (Create or Save); Cancel is plain, closes a dialog through a dynamic action, and sits apart from it | ADVISE | static | Oracle buttons, form; ex: CAT 26.1.6 data-entry-simple-form |
| `UXENT-MODE-BUTTONS` | create mode shows Create only; edit mode shows Save and, if allowed, Delete — and Delete only when the key exists | ADVISE | static | Oracle form |
| `UXENT-SECTIONS` | a form with more than about a dozen fields groups them in titled sections, the fields users fill first at the top | ADVISE | static + manual | ex: CAT 26.1.6 data-entry ("Sectioned Form"), data-entry-simple-form |
| `UXENT-ERROR-AT-ITEM` | a validation or package error names the field, appears next to it and in the notification, and the entered values survive | ADVISE | runtime | Oracle logic; WCAG 3.3.1, 3.3.3 |
| `UXENT-AFTER-SAVE` | after a dialog saves, it closes, the calling region refreshes and a success message says what changed; on error it stays open | ADVISE | runtime | Oracle form, logic |
| `UXENT-GRID-FEEDBACK` | an editable grid shows which rows changed and confirms the save; a refused row shows the package's message on that row | ADVISE | runtime | repo `recipes/editable-ig-to-package.md` |
| `UXENT-WIZARD` | a wizard shows the steps and the current one, has Previous and Next, and never asks again for what an earlier step collected | ADVISE | static + runtime | WCAG 3.3.7; ex: CAT 26.1.6 data-entry ("Wizard") |
| `UXENT-BULK-SCOPE` | a bulk change states how many records it affects before it runs, and confirms | ADVISE | runtime | ex: CAT 26.1.6 data-entry ("Bulk Edit") |

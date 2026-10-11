# Workflow and decisions — `UXWF`

Recipe: `workflow-state-transitions.md`. Runtime companion: `apex-sentinel/checks/workflow-state.md`.

| ID | Criterion | Sev | By | Source |
|---|---|---|---|---|
| `UXWF-STATE-BADGE` | every row shows its state as a badge with the state's text and one of the six semantic classes from the view's closed set | ADVISE | static | repo `ui-contracts.md` §2 |
| `UXWF-ACTIONS-BY-STATE` | decision actions (approve, reject) appear only on rows in a state that allows them; finished rows carry none | ADVISE | static + runtime | ex: CAT 26.1.6 content-rows ("Decision and Action List") |
| `UXWF-DISTINCT-DECISIONS` | each decision is its own labelled button, never one button with a choice inside it; the decision that refuses or cancels is confirmed (`UX-DESTRUCTIVE-CONFIRM`) | ADVISE | static | repo `recipes/workflow-state-transitions.md` |
| `UXWF-REFUSAL-MESSAGE` | an illegal transition is refused with the package's message in plain words, and the state does not change | ADVISE | runtime | repo `recipes/workflow-state-transitions.md`; WCAG 3.3.1 |
| `UXWF-CONTEXT` | the decision is taken with its context in view — who asked, what, when, and the current state | ADVISE | manual | ex: CAT 26.1.6 cards, content-rows ("Action/Approvals", "Decision and Action List") |

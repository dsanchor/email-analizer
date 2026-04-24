# Work Routing

How to decide who handles what.

## Routing Table

| Work Type | Route To | Examples |
|-----------|----------|----------|
| Azure infrastructure | Ripley | Logic Apps, Cosmos DB, Blob Storage, AZ CLI, managed identities, ARM/Bicep |
| Cloud architecture | Dallas + Ripley | Architecture decisions, infrastructure design, security review |
| Python web app | Lambert | Flask/FastAPI app, UI, templates, containerization, Dockerfile |
| Frontend / UI / design | Lambert | Apple-inspired design, HTML/CSS, responsive layout |
| Testing | Kane | Write tests, integration tests, edge cases, verify deployments |
| Code review | Dallas | Review PRs, check quality, suggest improvements |
| Scope & priorities | Dallas | What to build next, trade-offs, decisions |
| README / docs | Dallas + Lambert | Documentation, setup guides, architecture docs |
| Session logging | Scribe | Automatic — never needs routing |

## Issue Routing

| Label | Action | Who |
|-------|--------|-----|
| `squad` | Triage: analyze issue, assign `squad:{member}` label | Lead |
| `squad:{name}` | Pick up issue and complete the work | Named member |

### How Issue Assignment Works

1. When a GitHub issue gets the `squad` label, the **Lead** triages it — analyzing content, assigning the right `squad:{member}` label, and commenting with triage notes.
2. When a `squad:{member}` label is applied, that member picks up the issue in their next session.
3. Members can reassign by removing their label and adding another member's label.
4. The `squad` label is the "inbox" — untriaged issues waiting for Lead review.

## Rules

1. **Eager by default** — spawn all agents who could usefully start work, including anticipatory downstream work.
2. **Scribe always runs** after substantial work, always as `mode: "background"`. Never blocks.
3. **Quick facts → coordinator answers directly.** Don't spawn an agent for "what port does the server run on?"
4. **When two agents could handle it**, pick the one whose domain is the primary concern.
5. **"Team, ..." → fan-out.** Spawn all relevant agents in parallel as `mode: "background"`.
6. **Anticipate downstream work.** If a feature is being built, spawn the tester to write test cases from requirements simultaneously.
7. **Issue-labeled work** — when a `squad:{member}` label is applied to an issue, route to that member. The Lead handles all `squad` (base label) triage.

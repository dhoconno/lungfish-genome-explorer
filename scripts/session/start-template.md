# START prompt, facts taken {{taken}}

This prompt is filled from `scripts/session/start-template.md` by `scripts/session/preflight.py --start` and holds nothing else.

## Facts
```
{{facts}}
```

## This session takes
The plan is `{{plan}}`. The session takes the lanes {{scope}}.

## Owner words since the plan
Rows of `docs/contracts/OWNER-DIRECTIONS.md`, by id.
{{owner}}

## Read whole, in this order
1. `AGENTS.md`
2. `docs/contracts/SCOPE-AND-DELIVERY.md`
3. `docs/contracts/RUNNING-A-PHASE-SESSION.md`
4. `{{plan}}`

## Standing go
O126 applies as `docs/contracts/SCOPE-AND-DELIVERY.md` sets it.

## Budget and records
The budget is {{budget}}. The records folder is `{{records}}`.

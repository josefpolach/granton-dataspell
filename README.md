# Granton DataSpell — Reporting Notebooks

A collection of standalone Jupyter notebooks that pull data from Granton's production systems
(PostgreSQL databases and Jira) and turn it into billing reports, KPI dashboards and Excel/PDF
exports for internal and customer use.

Each project is self-contained: one notebook, its own configuration cell, and its own outputs.
There is no shared library and no build step — open a notebook, set the config cell, run it top
to bottom.

---

## ⚠️ Rotate the credentials that were committed to this repository

Secrets are no longer hard-coded in the notebooks — each project folder now loads its own
git-ignored `.env` (see [Configuration](#configuration)). **That change stops the leak growing; it does not undo the
existing exposure.**

These values were previously hard-coded and are still present in the git history and on the
GitHub remote (`github.com/josefpolach/granton-dataspell`):

| Secret | Was in |
|---|---|
| Production PostgreSQL password — `psql-and2-prod...azure.com` | `client_statistics.ipynb` |
| Production PostgreSQL password — `psql-sys-offy-prod...azure.com` | `aquila_statistics.ipynb` |
| Atlassian API token (account: `josef.polach@granton.cz`) | `jira_sprint_carryover.ipynb` |
| Atlassian API token — a second, different one, same account | `sdesk_export.ipynb` |

Anyone with read access to this repository, or to any clone or fork of it, has them.

**Remediation, in this order:**

1. **Rotate all four secrets now.** Revoke the Jira tokens at
   <https://id.atlassian.com/manage-profile/security/api-tokens> and change both PostgreSQL
   passwords. Rotation is the only step that actually ends the exposure — everything below is
   cleanup.
2. Put the new values in the relevant project folder's `.env` — and remember the Jira token lives
   in **two** of them (`KPIs/` and `sdesk_export/`).
3. **Confirm the GitHub repository is private** and review who has access.
4. **Purge the history** (`git filter-repo`, or a fresh repository) — but only after rotating.
   Rewriting history without rotating first accomplishes nothing, since clones and caches persist.

Note also that notebook **outputs are committed alongside the code**. Outputs can embed customer
names, email addresses and ticket contents, so review them before sharing a notebook outside the
company. `jupyter nbconvert --clear-output --inplace <notebook>` strips them.

---

## Configuration

Each project folder holds its **own** `.env`, with a committed `.env.example` beside it as the
template. There is no repository-wide `.env` — a notebook can only see its own secrets, so opening
the KPIs notebook does not put two production database passwords into your environment.

```bash
cd "aquila statistics" && cp .env.example .env    # then fill in
```

| Folder | `.env` contains |
|---|---|
| `aquila statistics/` | `AQUILA_DB_*` (`HOST`, `PORT`, `NAME`, `USER`, `PASSWORD`, `SSLMODE`) |
| `client_statistics/` | `ANDROMEDA_DB_*` (same six) |
| `KPIs/` | `JIRA_DOMAIN`, `JIRA_EMAIL`, `JIRA_TOKEN`, `JIRA_BOARD_ID` |
| `sdesk_export/` | `JIRA_DOMAIN`, `JIRA_EMAIL`, `JIRA_TOKEN`, `JIRA_PROJECT`, `GDRIVE_*` |

> ⚠️ **`JIRA_DOMAIN` / `JIRA_EMAIL` / `JIRA_TOKEN` are duplicated** in `KPIs/.env` and
> `sdesk_export/.env`. Atlassian API tokens are account-scoped, not project-scoped, so both
> notebooks legitimately use the same credential — but **when you rotate the token you must update
> both files.** Miss one and it fails silently: the stale copy keeps working until the old token is
> revoked, and then that notebook breaks with a confusing 401, possibly weeks later.

Every notebook's config cell starts with the same block:

```python
import os
from pathlib import Path

from dotenv import load_dotenv

ENV_PATH = Path.cwd() / '.env'
if not ENV_PATH.is_file():
    raise RuntimeError(f'No .env found at {ENV_PATH}. ...')
load_dotenv(ENV_PATH)
```

The `.env` is resolved relative to the working directory, so **start Jupyter from the project
folder** (a kernel's working directory is its notebook's directory by default, so this is the
normal case). A missing `.env`, or a missing setting inside it, raises immediately in the config
cell and names what is absent — rather than failing later with an opaque authentication error.

Non-secret settings — report period, pricing, state filters, analysis options — stay in the
notebook config cells, since they are part of the report definition rather than the environment.

---

## Getting started

The project is defined by `pyproject.toml` (Poetry) with a committed `poetry.lock`.

```bash
poetry install                      # everything, including JupyterLab
poetry run jupyter lab              # launch

poetry install --without notebook   # headless / CI — skips the notebook runtime
```

There is also an existing conda env at `/home/josef/.conda/envs/grt-dataspell` (Python 3.11.15),
which is what these notebooks were developed and tested against. Either works; use one
consistently.

> **Version drift:** the dependency constraints are lower bounds (`^`) taken from the conda env,
> so `poetry.lock` resolved a little ahead of it — `pandas` 3.0.5 vs 3.0.2, `matplotlib` 3.11.1 vs
> 3.10.8, `numpy` 2.4.6 vs 2.4.4, plus newer `requests`, `jupyterlab`, `notebook`, `ipykernel` and
> `nbformat`. Patch-level differences are harmless, but a `matplotlib` minor bump can shift chart
> rendering. If you need Poetry to mirror the conda env exactly, change the constraints to `==`
> pins and re-run `poetry lock`.

Then:

1. Open the notebook for the report you need.
2. Edit **only the config cell** (section 1) — report period, pricing, analysis options.
3. Run all cells top to bottom.
4. The export cell at the end writes the PDF/Excel next to the notebook.

The `.sql` files under `source_files/` are the same queries in runnable form, for use in a
database IDE without touching Python. They are kept in sync with the notebooks by hand — if you
change a query in one, change it in the other.

---

## Projects

### `aquila statistics/` — Aquila consumption & billing

Billing and quality reporting for **Aquila**, the case-matching product. Single customer
(**System Air**); the Aquila schema has no tenant table, so all breakdowns are per `"user"`.

- **`aquila_statistics.ipynb`** — 14 report sections plus a PDF export cell that writes
  `aquila_statistics_<YEAR>_<MONTH>.pdf` (cover page + one page per section).
- **`source_files/aquila_statistics.sql`** — the monthly invoice summary as plain SQL.
- **`source_files/aquila_statistics_advanced.sql`** — 13 standalone analysis queries.
- **`case_db_full.sql`** — the full Aquila schema (migrations `V1`–`V6`), used as the reference
  data model. Not a migration runner; it is documentation.

**Billing model** — driven by the config cell:

| Setting | Value | Meaning |
|---|---|---|
| Billable item | `case_item.status_id IN (2, 4, 5)` | `MATCHED`, `MATCH_NOT_FOUND`, `PAIRED` |
| Period anchor | `"case".created_at` | `case_item` has no timestamp of its own |
| `UNIT_PRICE_EUR` | `0.035` | EUR per billable item |
| `AZURE_INFRA_FEE_EUR` | `650.0` | Mandatory monthly fee, **customer-wide** — never split per user |
| `EUR_TO_CZK_CURRECY_RATE` | *(confirm before invoicing)* | EUR is the billing currency; CZK is derived |
| `EXCLUDED_USER_IDS` | 5 accounts | Internal/test accounts, filtered out of **every** query |
| `INCLUDE_DELETED` | `True` | Matches the agreed billing definition; `False` excludes deleted rows |

Conventions worth preserving if you edit the queries:

- Periods are **half-open** — `created_at >= from AND created_at < to`. A strict `>` on the lower
  bound drops cases created at exactly midnight on the 1st from *both* adjacent months.
- The invoice total is charged off the **raw item count**, not the sum of rounded per-user rows,
  so per-user rounding never inflates the total. Per-user rows may differ from the subtotal by a
  cent or two; the subtotal is authoritative.
- **CZK converts from the rounded EUR figure** (the amount actually invoiced), not from the raw
  product.
- The user exclusion is written `(c.user_id IS NULL OR c.user_id NOT IN (...))`. A bare `NOT IN`
  would also silently drop cases with a `NULL` user_id, which are not on the exclusion list.

> **Before invoicing:** confirm `EUR_TO_CZK_CURRECY_RATE` — it ships as a placeholder.

### `client_statistics/` — Andromeda client billing & LLM cost

Per-client billing for the **Andromeda** document-harvesting platform, plus LLM token cost
attribution. This is the older, larger reporting project that the Aquila one was modelled on.

- **`client_statistics.ipynb`** — 17 PDF sections: billing summary, month-over-month growth,
  revenue trend, daily volume, harvest-job efficiency, Pareto, LLM cost per client, model usage,
  pipeline funnel, error analysis, duplicate rate, unbilled records.
- **`source_files/client_statistics.sql`** — single-month billing summary.
- **`source_files/client_statistics_advanced.sql`** — 8 analysis queries.
- **`source_files/llm_statistics.sql`** — LLM cost per client / per model, from `llm_data.llm_usage`.
- `client_statistics_<YEAR>_<MONTH>.pdf` — generated monthly reports, kept as a record. The
  several `2026_04-*` variants are alternative state filters for that month, not duplicates.

**Billing model:** tiered per-document pricing (10 → 5 Kč/doc across six volume tiers) with a
2,990 Kč monthly minimum, in CZK. Billable state filter is `state_id IN (12, 18, 19, 20)`.
Note this differs from Aquila in currency, tiering and minimum — the two are not interchangeable.

### `KPIs/` — Jira sprint carryover

Measures the team KPI *"tasks should not be passed to the next sprint at sprint end"* by pulling
every closed sprint of a board and counting per-person carryover.

- **`jira_sprint_carryover.ipynb`** — per-person × per-sprint matrix, heatmap, per-person and
  team trends, drill-down to the specific tickets each person carried (for 1:1s), and repeat
  offenders (the same issue carried across multiple sprints).
- Outputs `carryover_matrix_*.csv`, `carryover_details_*.csv`, `carryover_report_*.xlsx`.

Uses Jira's `greenhopper/sprintreport` endpoint — the same data behind Jira's own Sprint Report.
`COUNT_PUNTED` controls whether issues manually removed from a sprint count as carryover
(default `False` = only auto-carried issues).

### `sdesk_export/` — SDESK ticket export

Exports all issues from the **Granton AI – Customer Service Management** (`SDESK`) Jira project to
Excel and uploads the result to Google Drive.

- **`sdesk_export.ipynb`** — paginated Jira pull, SLA field parsing, then 10 analysis sections
  (volume over time, status/priority/type distribution, assignee workload, reporter view,
  open-issue aging, resolution time, monthly status heatmap) before the Excel export.
- Uploads via the internal Drive integration API (`POST /upload-file`), with `exists=True` to
  overwrite rather than duplicate.
- Outputs `sdesk_export_<timestamp>.xlsx`.

> `GDRIVE_API_BASE_URL` points at **UAT**, and `GDRIVE_CLIENT_ID` is an all-zero placeholder UUID.
> Both need real values before the upload cell will work against production.

---

## Repository layout

```
dataspell/
├── pyproject.toml              Poetry project definition
├── poetry.lock                 pinned dependency set — commit this
├── aquila statistics/          Aquila billing (System Air) — EUR, per-item + fixed fee
│   ├── .env                    git-ignored secrets    ┐ one pair per
│   ├── .env.example            committed template     ┘ project folder
│   ├── aquila_statistics.ipynb
│   ├── case_db_full.sql        reference schema (V1–V6)
│   └── source_files/*.sql
├── client_statistics/          Andromeda billing — CZK, tiered pricing + LLM cost
│   ├── .env  /  .env.example
│   ├── client_statistics.ipynb
│   └── source_files/*.sql
├── KPIs/                       Jira sprint carryover KPI
│   ├── .env  /  .env.example
│   └── jira_sprint_carryover.ipynb
└── sdesk_export/               SDESK ticket export → Excel → Google Drive
    ├── .env  /  .env.example
    └── sdesk_export.ipynb
```

**What is tracked:** notebooks, `.sql` files, the four `.env.example` templates, `pyproject.toml`
and `poetry.lock`. The `.gitignore` rule is a bare `.env`, which git matches at any depth, so every
folder's `.env` is covered by the one pattern.
Generated reports (PDF, XLSX, CSV) are currently **untracked but not ignored** — they show up as
noise in `git status`. If they are meant to be kept as a record, commit them; if not, uncomment
the corresponding lines at the bottom of `.gitignore`.

## Conventions

- **One notebook per report.** No shared modules; some duplication between notebooks is
  deliberate, so a notebook can be run or sent on its own.
- **Secrets come from the project folder's own `.env`**, never from the notebook. If you add a new
  credential, add it to that folder's `.env.example` too — with a placeholder, never a real value.
- **All other configuration lives in the first code cell**, above a `print()` that echoes the
  active settings — run it and read the output to confirm what you are about to generate.
- **SQL is embedded as f-strings** with filter fragments (`BILLABLE`, `USER_FILTER`,
  `ITEM_DELETED_FILTER`) interpolated in, so one constant change propagates to every query.
- **Query parameters use `psycopg2` placeholders** (`%(year)s`), never string interpolation of
  values.
- **Charts:** `matplotlib` + `seaborn` (`whitegrid`), `figsize=(14, 5)`, monthly axes formatted
  `%Y-%m`.
- **PDF export** is always the final section, via `PdfPages`, cover page first.

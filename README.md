# Gateway Company Restaurant ERP Inventory MVP

## Week 3 local submission

See [WEEK3-SUBMISSION.md](WEEK3-SUBMISSION.md) for the current local features,
offline evidence, pending migrations 005–007, and deployment limitations. The Week 2
delivery narrative below is historical; its disabled-frontend-flag statements do
not describe the current local `week2-config.js`, where `writeEnabled` is true.
The current server write-gate state has not been independently verified.

## Final delivery status — 2026-11-08

This English-only inventory MVP was developed for a Gateway Company simulated
internship. Restaurant-owner needs informed its scope; the implementation and tests
do not establish supervisor approval. It is an inventory MVP, not a complete ERP or
a production-readiness claim. AI invoice scanning, forecasting and dashboards are deferred.

- [Week 1 demonstration](https://kevinlu537.github.io/restaurant-erp/): independent
  localStorage prototype; its `restaurantInventory.v1` data is unchanged.
- [Week 2 demonstration](https://kevinlu537.github.io/restaurant-erp/week2.html):
  Supabase inventory/history, operator authentication and four controlled forms.
  Public frontend writes remain disabled.
- [Current requirements](REQUIREMENTS.md), [frontend operations](WEEK2-FRONTEND.md)
  and [database setup/security](database/README.md).

## Architecture and configuration

GitHub Pages serves plain HTML/CSS/JavaScript. Week 2 reads the two `erp_api` views
through Supabase REST using a public publishable key. The API must expose `erp_api`
with the reviewed anonymous view SELECT permissions; never expose `erp_private`.
Public data is fictional and includes retained test history.

Writes use a memory-only Supabase Auth session and the existing `inventory-write`
Deno Edge Function. Gateway JWT verification stays enabled; real ES256 acceptance
was verified. The handler independently verifies Auth identity, exact operator UID
allowlisting, the approved origin and the server write flag before connecting to
PostgreSQL. It calls existing M3 functions using parameterized values under the
restricted caller. RLS, restricted owners, strict certificate/hostname verification
and the Session Pooler protect the database path. Frontend flags and CORS do not
replace authorization. The approved origin covers the GitHub user origin, not just
this repository path.

`week2-config.js` contains only public configuration. Keep `writeEnabled:false`.
Server variables, their exact formats and the optional CA bundle are documented in
WEEK2-FRONTEND.md. Never commit passwords, session tokens, private keys or live
database connection URLs. Provision restricted credentials through trusted server
configuration only. Exclude `supabase/.temp/` and personal/local environment files
from any source-delivery staging list.

## Reproduction and deployment

Week 1 needs only a modern browser; its earlier local-file instructions remain below.
Week 2 needs a static HTTP server for local read-only development, JavaScript and
approved public configuration. Localhost is not an approved write origin. The frontend
requires no package installation or build. Database reproduction requires a separately
approved clean PostgreSQL 17/Supabase development target, reviewed administrative
capabilities and an execution record; follow database/README.md in M1–M5 order.
Do not rerun migrations or seed against the existing populated project.

The Edge Function requires Deno, its function-specific deno.json and Postgres.js
3.4.7. Deno 2.9.8 was used for the accepted type check, with strict mode disabled.
There is no committed lockfile. Dependency fetching requires separate approval;
when cached, use `deno check --cached-only --no-lock --node-modules-dir=none index.ts`
from the function directory. `handler_test.ts` contains offline synthetic tests;
with cached dependencies use `deno test --cached-only --no-lock --node-modules-dir=none handler_test.ts`
without granting network/environment permissions. Do not invoke the real handler to
test typing. Supabase CLI 3.0.0 was used with trusted browser-based CLI authentication.

For an independently authorized deployment, provision reviewed server variables,
retain `verify_jwt=true` in supabase/config.toml and deploy only `inventory-write`
with `supabase functions deploy inventory-write --project-ref <approved-project-ref> --use-api --yes`.
Never add `--no-verify-jwt` or `--prune`. Inspect remote metadata after deployment;
a CLI success alone does not establish function behavior. Publish static files from
the reviewed Pages source and check both site URLs and assets after deployment.
This delivery does not redeploy or reconfigure Supabase.

## Acceptance evidence and limitations

These are existing results, not tests rerun during documentation delivery.

| Area | Evidence |
| --- | --- |
| M1–M5 and initial seed | LIVE PASS, established execution evidence; not a new clean rebuild |
| Public reads, ES256 Auth, UID allowlist, CORS, restricted DB identity and peer-verifying TLS | LIVE PASS from earlier controlled steps |
| Backend business cases | LIVE PASS, eight controlled requests |
| Browser login/local logout and inventory rendering | LIVE PASS |
| Responsive desktop/tablet/mobile | LIVE PASS; accessibility smoke checks PASS, not a WCAG audit |
| Frontend hardening | MOCK PASS, 58/58; separate earlier Edge security mocks also 58/58 |
| Browser expiry and error/outcome handling | MOCK PASS, ten isolated scenarios including expiry |
| Four operations and business rejections through actual frontend | LIVE PASS, F4-4B seven requests |
| Server shutdown | LIVE PASS for authenticated contacted handler: HTTP 503, Inventory writes are disabled. |
| Source safeguards and disabled public configuration | STATIC PASS plus prior publication verification |
| Multi-session concurrency, fresh-target rebuild, backup restore and adverse TLS cases | NOT TESTED in accepted evidence |

F4-4B used a temporary browser-only configuration override at the approved origin,
not public write activation. Five requests committed and two business rejections
rolled back. All six original active inventory records and nine pre-test history
records matched canonical before/after comparisons. Final history contains twelve
entries and two retained inactive fictional fixtures; see WEEK2-FRONTEND.md.

Both write switches remain intended false. The authenticated shutdown result proves
the contacted handler, not every older isolate or indefinite future configuration.
UNKNOWN/timeout/lost-response outcomes require read-only ledger reconciliation and
operator review before any later submission. Never retry automatically or treat
reload as reconciliation. Use a quiet, bounded demonstration window; read views are
not one atomic snapshot. Controlled write demonstrations require explicit approval
and mandatory operator-managed shutdown verification.

Remaining production work includes concurrency evidence, operational ownership,
backup/recovery validation, monitoring and credential lifecycle. Submission format,
deadline and supervisor acceptance remain unconfirmed. Temporary frontend/browser
test harnesses were cleaned up; their historical counts are not a claim that those
harnesses are included here.

## Historical Week 1 prototype notes

The following notes describe only the original Week 1 scope. Statements about no
backend or ingredient management apply to Week 1, not the completed Week 2 MVP.

A lightweight, English-only inventory website prototype for restaurant owners, developed as the first working part of the Restaurant ERP System internship project.

## Implemented Features

- View the current ingredient quantity and unit in an inventory table.
- Start with Beef, a fixed unit of kg, zero stock, and no transactions when no saved data exists.
- Record incoming stock and consumption with a quantity and transaction date.
- Reject consumption exceeding available stock and quantities that are nonpositive, have more than two decimal places, or exceed the supported numeric range.
- Calculate quantities in integer hundredths to avoid floating-point balance errors.
- View transaction history in insertion order, including the date, ingredient, transaction type, quantity, unit, and remaining stock.
- Save inventory and history in browser localStorage and restore them on reload.
- Validate saved data and preserve invalid data without silently overwriting it.
- Use a responsive single-page interface with accessible form labels.

Transaction dates are record labels. They do not recalculate historical balances or provide backdated inventory accounting. Failed transactions do not change inventory or history.

## Technology Stack

- HTML
- CSS
- Vanilla JavaScript
- Browser localStorage

No frontend framework, npm packages, external dependencies, backend, or database integration is used.

## Run Locally

1. Download the project files into one folder. Extract the archive first if downloading a ZIP.
2. Open `index.html` in a modern browser with JavaScript and localStorage enabled.
3. Use **Record Incoming Stock** or **Record Consumption** to enter transactions.

No installation or build step is required. Keep `index.html`, `styles.css`, and `app.js` together. Browser support for storage on local file URLs varies. If storage cannot be accessed or validated, the page displays an error and disables transactions.

## Current Limitations

- Only Beef is supported. Adding, editing, and deleting ingredients are not implemented.
- Data is stored only in the current browser and origin. There is no shared database or synchronization across users, browsers, or devices.
- Clearing browser storage can remove records. Moving to a hosted URL does not automatically transfer locally saved records.
- Storage capacity is limited, and saving can fail if storage is disabled or full.
- Simultaneous writes from multiple tabs are not guaranteed to be safe.
- Saved data can be modified through browser tools; there is no server-side validation.
- Invalid saved data is preserved and transactions are disabled; no in-app recovery workflow is provided.
- Large transaction histories can slow validation, saving, and rendering.
- Native date picker language may depend on browser or operating system settings.

## Prototype and Future ERP Scope

The implemented prototype covers inventory, incoming stock, consumption, transaction history, and browser persistence only.

The longer-term ERP plan includes a backend database, PDF invoice uploads with AI extraction into the database, business metrics, and forecasting. These features are **not implemented** and are not automatically part of the first-week deliverable. Future development requires explicit approval.

Authentication, supplier management, dashboards, and external API integration are outside the approved prototype scope. Final first-week acceptance criteria, submission format, and deadline remain unconfirmed.

## Validation Status

The user reported successful real-browser testing: six transactions resulted in a Beef balance of 15.00 kg, records persisted after refresh, excessive consumption was rejected, and quantities with more than two decimal places were rejected. Codex did not independently rerun those browser acceptance tests. The reported balance is a test outcome, not seeded data.

See `REQUIREMENTS.md` for approved business rules and limitations, and `AGENTS.md` for project working rules.

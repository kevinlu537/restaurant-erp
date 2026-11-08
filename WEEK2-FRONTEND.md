# Week 2 frontend integration and hardening (F4-2)

## Final browser acceptance and delivery — 2026-11-08

This page now records the completed Gateway Company simulated-internship inventory
MVP. The F4-2 narrative below is retained as a historical implementation record;
its nine-row baseline and browser NOT TESTED statements refer to that stage.

Published pages are https://kevinlu537.github.io/restaurant-erp/ (Week 1) and
https://kevinlu537.github.io/restaurant-erp/week2.html (Week 2). Their source and
localStorage workflows remain separate. The public Week 2 configuration has
liveEnabled:true and writeEnabled:false. Server writes remain intended disabled;
the latest authenticated shutdown probe returned handler HTTP 503 REJECTED with
Inventory writes are disabled. This proves the contacted handler only, not every
older isolate or a permanent remote state. verify_jwt remains required and enabled
in source; earlier remote verification and real ES256 acceptance passed.

### Accepted evidence

- LIVE PASS: public data rendering, real operator sign-in and local sign-out.
- LIVE PASS: F4-3B headless desktop 1440x900, tablet 768x1024 and mobile 390x844;
  no whole-page horizontal overflow. Mobile tables use internal scrolling.
  Accessibility smoke checks passed; this is not a full WCAG audit.
- MOCK PASS: F4-2 frontend hardening 58/58, distinct from the earlier 58 Edge mocks.
- MOCK PASS: F4-3B ten browser scenarios: expiry plus nine HTTP/outcome cases,
  including UNKNOWN locking and timeout/lost response without retry.
- LIVE PASS: F4-4B seven fixture-only submissions from actual frontend form handlers,
  using headless Edge 157.0.4341.42 at the approved origin with a browser-only config
  response override. Public frontend files were never activated or changed.
- STATIC PASS: source safeguards and configuration review. Deno type check passed
  earlier with strict:false; no strict-mode correctness claim is made.
- NOT TESTED: production operations, multi-session concurrency, clean rebuild,
  backup recovery and adverse live TLS cases. No suite was rerun for source delivery.

### Permanent fictional records

The six original active ingredients retain balances Beef 27 lb, Chicken 18.50 lb,
Salmon 12 lb, Milk 8 pt, Cooking Oil 64 fl oz and Eggs 36 each. Final history is
twelve rows, including two inactive fixtures. Do not delete them for presentation.

- Earlier fixture: F3-3Q-a70f131e-428d-4bf6-babc-6b08b82b7352, ingredient UUID
  5c3bd76a-a8a1-4798-99bf-20694ceebea2, ledger sequences 10,11,12.
- Browser fixture: F4-4-1bed3154-9c02-49ee-abc9-0c9aa21082a3, ingredient UUID
  3a44fafd-275c-436d-825c-707265b2ba26, category Test, unit each, business date
  2026-11-08, ledger sequences 13,14,15.
- Each fixture retains INCOMING 12, CONSUMPTION 3 and CONSUMPTION 9. Sequence gaps
  are acceptable; never infer missing commits from a gap.

F4-4B results were add (200 COMMITTED, zero), receive 12 (200, balance 12), consume
3 (200, balance 9), consume 10 (409 ROLLED_BACK, unchanged), deactivate nonzero
(409 ROLLED_BACK, unchanged), consume 9 (200, zero), deactivate (200, inactive).
The browser displayed confirmed-change feedback or business-rule rejection as
appropriate. Canonical public records were compared with numeric tokens retained
as strings and explicit API ordering. All six original inventory records and nine
pre-test history records matched. Temporary input/session/browser artifacts were
cleaned up; passwords and tokens were never retained in delivery evidence.

### Controlled write demonstration and restoration

Public access is a read-only demonstration. A publishable key or a visible control
does not authorize writes. For a separately approved operator demonstration:

1. Keep the public file writeEnabled:false. Prefer an isolated headless browser
   loading the actual approved-origin page, overriding only that context's config
   response before script evaluation. A localhost page is not an approved write origin.
2. Before activation, install an exact sequential request allowlist, securely sign
   in without logging/persisting credentials, verify the expected operator UID,
   capture complete ordered/paginated baseline data and select a fresh unique fixture.
3. Only the operator saves ERP_WRITES_ENABLED=true in Dashboard. Confirm propagation
   with an authenticated non-writing unsupported-action probe: HTTP 400 REJECTED,
   Action not supported. Authentication and allowlisting precede that branch.
4. Submit only the authorized fixture sequence through forms, never original seed
   IDs. Verify HTTP outcome, visible feedback and authoritative reads after each.
   Do not automatically retry. A failed refresh does not undo a confirmed commit.
5. On any unexpected or UNKNOWN result, stop business requests. Reconcile history
   read-only; timeout is not rollback. Refresh, logout/login and reload are not proof
   of reconciliation. No compensating writes without separate approval.
6. Regardless of success/failure after activation, require the operator to save
   ERP_WRITES_ENABLED=false. An authenticated unsupported-action probe must return
   HTTP 503 REJECTED, Inventory writes are disabled. A 401, startup error or HTTP 400
   does not verify shutdown. Report residual isolate uncertainty explicitly.
7. Compare original records and expected fixture history, sign out where supported,
   clear memory/session references, close the isolated context, remove overrides
   and temporary artifacts, and independently recheck public writeEnabled:false.

Activation temporarily permits requests from all server-allowlisted operators,
including direct clients. Minimize that window. CORS is origin-wide, not a
repository-path permission. No Pages, Auth or CORS changes are needed for this
approved-origin method. Retain both divergent source commits during Git handoff;
matching published file contents do not mean identical Git history.

See README.md for local/Deno/CLI prerequisites, the consolidated evidence matrix
and publication instructions; see database/README.md for M1–M5 and API setup.
The exact server variable formats and earlier implementation rationale follow.

## Historical F4-2 implementation record

## Current scope and evidence

Week 2 uses plain HTML, CSS and vanilla JavaScript. The existing page contains stock
and history tables, password sign-in/out and four inventory forms. No new module,
framework or dependency is needed. Week 1 files and restaurantInventory.v1 remain
separate; Week 2 does not read, migrate or write that browser data.

The existing public connection is configured with liveEnabled: true. Frontend
writeEnabled remains false. The server-side ERP_WRITES_ENABLED guard was previously
verified disabled after the controlled F3-3Q test; F4-2 performs no live verification
and changes neither switch. Frontend configuration never authorizes server writes.

Established LIVE PASS evidence from earlier steps covers ES256 gateway acceptance,
independent handler authentication, exact operator allowlisting, approved/unapproved
origin CORS, peer-verifying database TLS, restricted database identity and all eight
controlled business requests. These were backend/isolated-client tests, not acceptance
of the newly hardened browser UI. The last reported function was ACTIVE, version 24,
with verify_jwt: true; this step does not recheck or redeploy it.

There are six original active ingredients and nine history entries. The retained
inactive fixture F3-3Q-a70f131e-428d-4bf6-babc-6b08b82b7352 has three entries: INCOMING
12, CONSUMPTION 3 and CONSUMPTION 9. It is absent from active stock and ingredient
selectors, while its history remains visible. Do not expect only six history rows or
delete audit records to restore that earlier count.

## Reads, rendering and public configuration

week2-config.js contains only liveEnabled, writeEnabled, public projectUrl and the
matching public sb_publishable_ key. A public key is not operator authorization.
Never put database passwords, secret/service-role keys or server configuration there.
No values are saved to browser storage. Invalid/missing public configuration produces
Not Connected. Keep the existing verified project configuration unchanged.

Reads use GET /rest/v1/inventory_balances and /rest/v1/inventory_history with apikey
and Accept-Profile: erp_api, without an authenticated bearer token. History requests
ledger_sequence.asc; balances request ingredient_id.asc. Pagination uses 500-row pages,
exact Content-Range totals, at most 100 pages/50,000 rows, and a shared 20-second
read timeout. Incomplete, changing or duplicate results fail validation. These separate
requests are not an atomic database snapshot; use a quiet demonstration window.

The existing lossless JSON decoder retains decimal and sequence tokens as strings.
History sorting uses BigInt. Database text is rendered with textContent. Each refresh
rereads both views. Failure clears the tables and selectors instead of presenting
stale rows as current. Loading, empty, unavailable and Connected states remain.

## Authentication and session behavior

Sign-in is available when public live configuration is valid, including when
writeEnabled: false. This permits authentication-only acceptance without enabling any
business form. The disabled fieldset and the submit-handler guard independently
block all four business actions while that frontend flag is false.

The existing password grant posts to /auth/v1/token?grant_type=password using the
publishable key. No OAuth, redirect flow, browser JWT verification or claims-based
client authorization is introduced. Password fields are cleared as soon as an attempt
starts and again when it finishes. Access tokens stay in the current JavaScript
closure only; refresh tokens are not retained. Nothing logs credentials or tokens.

Expiry uses expires_in, conservatively measured from the start of the login request.
A timer clears the session and updates controls at expiry. Focus/visibility checks
also catch expiry after background timer delays. A new sign-in is required; there is
no automatic token renewal. Failed sign-in and protected-request HTTP 401 clear the
session. HTTP 403 is an authorization denial and blocks further business submissions
until session reset; successful login alone never proves allowlisting.

Logout clears local session state and calls /auth/v1/logout?scope=local for the current
session only. Local clearing still occurs if remote sign-out fails. Backend Auth
verification and exact UID allowlisting remain authoritative for every request.

## Exact payloads and client validation

| Action | Payload fields |
| --- | --- |
| add_ingredient | action, name, category, unit_id |
| receive_stock | action, ingredient_id, quantity, date |
| consume_stock | action, ingredient_id, quantity, date |
| deactivate_ingredient | action, ingredient_id |

Creation trims name/category, rejects empty values and enforces the handler's
200-JavaScript-character limit. Unit IDs must be one of the four existing selector
values (lb, pt, fl oz, each). Selected ingredient IDs must match lowercase UUID syntax
and an active ingredient in the currently loaded inventory.

Quantities remain strings, at most 128 characters. Only unsigned decimal notation
with up to two fractional digits is accepted. BigInt hundredths enforce a positive
quantity and the maximum 9999999999.99 without floating-point arithmetic. For each,
the scaled quantity must be a whole number. Dates must be YYYY-MM-DD with a valid
calendar day, including leap-year checks; calendar validation uses no timezone shifts.

Apparent overconsumption produces an advisory message during submission, not an
assertion about authoritative stock. Deactivation selectors and submission messages
explain that zero stock is required. The server makes the final current-balance,
active-status and deactivation decision, even if the displayed snapshot is stale.

## Request outcomes and safety

Write requests use the fixed /functions/v1/inventory-write endpoint with apikey,
Authorization: Bearer <in-memory user token> and application/json. Cookies are omitted,
redirects rejected and requests bounded by a 20-second timeout. The writeBusy gate
prevents duplicate concurrent submissions. There are no automatic write retries.

| Response | UI behavior |
| --- | --- |
| 200 with ok:true and COMMITTED | Confirm success and refresh both authoritative views; never optimistically alter stock. A failed refresh does not undo a confirmed commit. |
| 409 ROLLED_BACK | Explain the inventory-rule rejection and retain inputs; no automatic retry or success refresh. |
| 503 ROLLED_BACK | Explain confirmed rollback and service failure. |
| 401 | Clear the rejected session and request sign-in; do not replay the request. Identifiable gateway authentication errors need no handler outcome envelope. |
| 403 | Explain authorization denial and block repeated submissions. |
| 400 REJECTED | Explain form/request rejection. |
| 503 REJECTED | Distinguish disabled server writes, unconfigured service and other unavailable-service rejections. |
| UNKNOWN, contradictory response, timeout, lost/invalid response or ambiguous transport failure | Lock further writes and require operator reconciliation. |

The UNKNOWN lock survives read refresh, logout and another sign-in within the page.
It has no automatic reset and is not persisted to storage. Reloading loses that
in-memory latch, but reload is NOT proof of reconciliation and must not be used as a
retry workaround. Reconcile the intended operation against ledger evidence before
any later manual submission. Inconsistent auth-status/outcome combinations also take
the conservative UNKNOWN path. No displayed server text is treated as HTML.

## Server configuration boundary (reference only)

The existing Edge entrypoint reads these server environment variables. F4-2 changes
none of them and adds no browser copies or fallback privileged credentials.

| Variable | Purpose |
| --- | --- |
| ERP_FRONTEND_ORIGIN | Exact approved HTTPS frontend origin; no repository path. |
| ERP_PROJECT_URL | Matching public HTTPS Supabase project origin. |
| ERP_PUBLISHABLE_KEY | Matching public publishable key for Auth verification. |
| ERP_ALLOWED_USER_IDS | Nonempty JSON array of unique lowercase operator UUIDs. |
| ERP_CALLER_DATABASE_URL | Restricted server-only database connection secret. |
| ERP_APPROVED_POOLER_HOST | Independently approved exact Session Pooler hostname. |
| ERP_PROJECT_REF | Project reference required in the pooled restricted username. |
| ERP_WRITES_ENABLED | Disabled unless the exact server string is true. Keep disabled. |
| ERP_DATABASE_CA_CERT | Optional verified PEM CA bundle if runtime roots are insufficient. |

The existing connector validates the exact approved Session Pooler host, port 5432,
restricted project-qualified erp_admin_caller username and /postgres database path.
TLS uses rejectUnauthorized: true and the approved servername; max: 1 and prepare:
false remain configured. It checks session/effective identities before business SQL.
Earlier positive live evidence is not proof of every negative certificate case or
of future configuration changes. Never weaken TLS or substitute privileged accounts.

## Origin and publication boundaries

The established approved write origin is https://kevinlu537.github.io. The handler
checks the full origin, not an individual repository path. localhost, file:// and
other origins are not covered by that approval. Do not change CORS or Auth settings
to make a local write test work. Password sign-in uses no redirect configuration.

Actual Week 2 GitHub Pages publication and browser acceptance of these local changes
remain NOT TESTED. Source files alone do not establish which revision is hosted.
Publishable configuration may be public; operator passwords, bearer tokens and server
secrets must stay out of source, browser persistence, reports and Git.

## Local validation and later browser acceptance

F4-2 syntax validation uses node --check week2.js. Focused tests execute the actual
script in a mocked DOM with synthetic public configuration, fake timers and mocked
fetch only. Synthetic writeEnabled:true configurations exercise write branches in
isolation; they do not change week2-config.js or bypass the production flag check.
No test makes a real Auth, Supabase or inventory-write request. Temporary tests are
outside the repository and are removed after execution.

Local/mock coverage includes reads, pagination/order, safe rendering, input boundaries,
calendar dates, memory-only login with writes disabled, session expiry, HTTP/outcome
handling, post-commit reads, duplicate submission and UNKNOWN locking. LOCAL / MOCK
PASS is distinct from LIVE PASS; real browser behavior remains NOT TESTED.

F4-2 validation result: JavaScript syntax PASS (exit 0); focused frontend mocked
tests PASS, 58 passed and 0 failed (exit 0). This count is a separate frontend suite
from the earlier 58 Edge Function security mocks. Temporary test files were cleaned
up. Browser functional testing and publication verification remain NOT TESTED.

Later, under separate authorization:
1. Verify the actual hosted Week 2 revision and approved HTTPS origin.
2. With both write switches disabled, verify reads, six active rows/nine history rows,
   safe rendering, responsive/keyboard use, sign-in, expiration and current-session
   sign-out. Confirm business controls and programmatically dispatched submissions
   cannot send writes while the frontend flag is false. Do not expose tokens in logs.
3. Verify the Week 1 page and its existing localStorage data remain intact.
4. Any frontend publication, write-flag activation or browser business-write test
   requires separate approval. Use a new fictional ingredient and preserve audit
   history; do not reuse seed IDs for mutation tests.

F4-2 changes only week2.js and this document. HTML, CSS, Week 1, public configuration,
database definitions, server code, Secrets, deployment and Git remain unchanged.

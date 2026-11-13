# Week 3 Submission — Gateway Company Restaurant ERP

**Status: locally implemented and offline checked; migrations and deployment pending.**

This simulated internship project extends the existing Week 2 inventory application
with a single-restaurant dashboard. It preserves plain HTML, CSS, vanilla JavaScript,
Supabase Authentication, and the existing ledger and authorization model. This is a
code submission, not a claim of production readiness or supervisor acceptance.

## Completed local features

- Login First, followed by Gateway Demo Restaurant selection and Dashboard access.
- Complete loaded Inventory History filtering by exact ingredient name.
- Ingredient reactivation using the original UUID and zero-balance rules.
- Low Stock alerts using exact decimal comparisons.
- Editable browser-local thresholds scoped to project, restaurant, user, ingredient,
  and unit, with save/reset and storage-error handling.
- Record Waste inside Administrator Inventory Management, with Spoiled, Damaged,
  and Other reasons, a read-only unit, and one ledger deduction.
- History reads compatible with the pre-006 and proposed post-006 views.
- Optional receipt expiry and protected paginated Expiration Overview, with UTC
  classifications and a seven-day demonstration warning horizon.
- Shared authentication, pending-write, stale-response, and UNKNOWN protections.

## Architecture and implementation

The frontend is `week2.html`, `week2.css`, and `week2.js`, with public configuration
in `week2-config.js`. Week 1 files and browser inventory remain separate.

Balances and history use the existing `erp_api` views. Login First gates this UI;
it does not make the anonymously readable database views private. History requests
use `select=*`: the reviewed views expose only approved history fields, with
`waste_reason` appended by 006. Operator identity is excluded. Future view additions
need another exposure review.

The existing `inventory-write` Edge Function independently verifies Auth, the exact
operator allowlist, and the approved origin. All writes require the exact server
`ERP_WRITES_ENABLED` value. SQL calls use parameters and an identity-checked
`erp_admin_caller` Session Pooler connection with certificate/hostname verification.
Gateway JWT verification remains enabled.

Expiration reads use the same protected Edge route but a READ ONLY transaction;
they remain available to authorized operators when writes are disabled. They do not
return UNKNOWN write outcomes. Read failures affect Expiration Overview separately
from stock/history.

## Database drafts and readiness

| File | Proposed change | Current status |
| --- | --- | --- |
| `database/migrations/005_reactivate_ingredient.sql` | Restricted status-only reactivation | Local draft; not applied according to user report |
| `database/migrations/006_waste_tracking.sql` | WASTE type, reason/private attribution, writer, history reason | Local draft; not applied according to user report |
| `database/migrations/007_expiration_tracking.sql` | Nullable expiry, atomic receipt writer, protected receipt reader | Local draft; not applied according to user report |

Static review found no critical code-submission blocker. Each draft depends on the
001–004 baseline; no functional dependency between the three new drafts was found.
The recommended operational order is 005, 006, 007, each with separate approval,
preflight, transaction, verification, and stop gate. They are not idempotent.

User-reported live metadata evidence covers PostgreSQL 17.11, postgres identity,
restricted role attributes/eight memberships, creator defaults, ownership, four
forced-RLS tables/thirteen policies, original routines/privileges, sequence access,
the original CHECK expression match, seven-column history, immutable triggers, and
absence of the new functions/columns. Codex did not independently verify this live.
Partial column-privilege screenshots do not establish the complete effective matrix.

Source reconciliation:

- 001 assigns both schemas to `erp_table_owner` (lines 128–129). Exact comparison
  with raw live schema-owner values is NOT VERIFIED in this finalization task;
  the supplied summary reports ownership checks but does not reproduce those values.
- Existing function-owner SELECT on ingredients/ledger, status UPDATE, ledger
  INSERT, unit-locking rights, and sequence USAGE support the new functions
  (`002_core_tables.sql:147–158`). Their full deployed effective combination remains
  NOT VERIFIED by Codex.
- 006 adds INSERT on reason/operator/created_at and view-owner SELECT on reason
  (`006_waste_tracking.sql:110–111`); 007 adds INSERT on expiry (line 71).
- The history view appends only reason; balance calculation already subtracts
  non-INCOMING entries. 007 does not expand either public view.
- Drafts retain immutable-ledger triggers/RLS, restricted SECURITY DEFINER execution,
  fixed search paths, creator-default checks, and removal of temporary CREATE.

Migration 006's exact catalog-expression match is supported by the user's reported
metadata result, not by PostgreSQL execution here. No SQL syntax/execution,
constraint migration, real RLS/grant enforcement, or concurrency test was performed.
Historical documentation's “M5” seed stage is distinct from migration file 005.

## Final offline verification

Finalization used the installed Node.js runtime, isolated VM contexts, synthetic
Auth/responses, a mocked database driver, and no exposed real network primitive.
Existing TypeScript handler/test source was stripped for execution; this is not a
Deno type check or a real database test. The temporary runner is outside Git.

| Check | Result |
| --- | --- |
| Existing handler suite: Auth, allowlist, gates, action dispatch, restricted caller/TLS configuration, rollback/UNKNOWN | **MOCK PASS — 144/144** |
| Frontend focused behavior checks | **MOCK PASS — 18/18** |
| Shared protection across all six frontend actions | **STATIC PASS — 1/1** |
| `node --check week2.js` | **STATIC PASS** |
| Migration dependencies, view/privilege/invariant source reconciliation | **STATIC PASS**, subject to live conditions above |
| `git diff --check` | **STATIC PASS** |
| Native Deno type check | **NOT TESTED** — tooling unavailable in PATH/checked runtime cache |
| Current browser rendering, physical mobile device, actual PostgreSQL and concurrent transactions | **NOT TESTED in finalization** |
| Live Supabase calls or real writes | **NOT TESTED; prohibited in this task** |

The 18 frontend mock checks cover initial Login/no reads, actual mocked login and
selection, legacy/post-006 history, invalid/missing/null reasons and non-WASTE
leakage, exact sequence decoding/duplicates, 501-row history/filtering, exact stock
thresholds, save/load/reset persistence, reactivation names, Waste validation,
optional Receive expiry, UTC statuses, 501-row expiration pagination/failure
isolation, session cleanup, two delayed-response scenarios, and pending/UNKNOWN
no-replay behavior. One additional static assertion checks the common action guard.

A temporary threshold-test fixture initially omitted enabling threshold controls;
the fixture was corrected to render Stock Overview, and the complete run passed.
No application logic was changed for that test correction. Earlier 110-handler and
144-handler results overlap and must not be added together.

## Screenshot references

Prior W3-7B offline evidence includes `w37b-desktop.png` (1440 × 900) and
`w37b-mobile.png` (390 × 844), captured with synthetic receipt data. The mobile
artifact was inspected during W3-8. These remain in local Codex artifacts outside
the repository and are not bundled or required to run the submitted source. They
are mock evidence, not screenshots of a newly deployed Week 3 environment.

## Running and demonstrating the source

1. Use the existing repository and an already-installed static HTTP server, then
   open `/week2.html`. No frontend build or dependency installation is required.
2. The initial Login-only page can be previewed without authenticating. Current
   public configuration targets Supabase (`liveEnabled:true`, `writeEnabled:true`);
   do not sign in, refresh business data, or submit forms for an offline review.
3. Fully interactive offline checks require synthetic configuration and intercepted
   requests/mocked DOM, as used above. A standalone offline fixture application is
   not shipped; serving the page alone does not create offline inventory data.
4. An integrated live Week 3 demonstration requires separately authorized migrations,
   compatible Edge/frontend deployment, approved configuration, and explicit
   authorization for any real writes. Localhost is not the approved write origin;
   do not weaken CORS to make it one.

Before migration, core reads remain pre-006 compatible. Reactivate requires 005;
Waste requires 006; expiry Receive and protected expiration reads require 007 plus
the updated Edge handler. Expiration unavailability does not invalidate otherwise
successful stock/history reads. No capability-discovery feature hides pending actions.

## Safeguards and limitations

- No optimistic stock mutation or automatic write retry. Ambiguous responses lock
  all inventory submissions pending trusted operator reconciliation.
- UNKNOWN survives logout/login in the page but is memory-only. Reload loses the
  latch and is not evidence of reconciliation; it must not be used as a bypass.
- Tokens remain in memory. Thresholds persist locally; no token or ledger persistence
  is added to localStorage. Browser thresholds are demo settings, not shared policy.
- Current server gate state is unknown. Frontend flags do not disable server writes.
- Old readers reject WASTE; keep server writes frozen until compatible readers and
  cache behavior are verified. Pages assets/open tabs do not update atomically.
- Paginated requests are not one global atomic snapshot; reads are bounded to
  50,000 rows and a 20-second frontend timeout. Protected reads/writes can contend
  for one active connection per Edge isolate.
- Expiry shows original receipt quantity, never remaining expired stock. There is
  no FEFO, batch allocation, automatic waste, or expiry backfill. UTC classification
  uses the browser clock and updates on render/focus/refresh.
- Existing history validation is not exhaustive UUID/unit/calendar/type validation;
  SQL constraints remain authoritative. Reason lookup also lacks an explicit string
  type check, although the reviewed database view emits TEXT. This known robustness
  limitation was not expanded into a business-logic change during finalization.
- Physical-device accessibility, PostgreSQL races, recovery and production readiness
  remain unproven. Old stage-specific SQL test suites must not be run unchanged as
  Week 3 postchecks against the expanded schema or populated project.

## Delivery boundary and next stage

This task created this document, added a README pointer/status clarification, and
corrected the History caption. It preserved prior implementation and all seven SQL
migrations. No SQL, Supabase call, real inventory operation, configuration/secret
change, dependency installation, Git staging/commit/push, or deployment occurred.

Week 3 migrations, modified Edge code, and frontend assets have not been deployed
by Codex. The user's reported live metadata is separate evidence from local mocks.
Next work is review of this code submission, then separately authorized staged
migration/deployment and PostgreSQL integration testing. No Week 4 work is included.

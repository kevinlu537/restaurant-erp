# Restaurant ERP database preparation

## Current delivery status — 2026-11-08

M1–M5 have been applied to the development project according to established live
execution evidence. Public reads, restricted login/identity, peer-verifying TLS and
controlled backend/browser business operations have LIVE PASS evidence. This is
not a new execution or a full acceptance of every SQL test, catalog or concurrency
gate. The historical PREPARED ONLY and NOT TESTED statements below describe their
original preparation stages, not today's deployment status. Preserve unresolved
gates rather than replacing them with blanket PASS claims.

### Reproduction order and prerequisites

Use a separately authorized clean PostgreSQL 17/Supabase development target and
review the exact source/checksums before running anything. M1 requires postgres
execution identity and the approved PostgreSQL 17 two-membership capability.
The established platform grantor is supabase_admin. Supply the non-secret session
setting `erp_migration.platform_grantor` in the same SQL Editor execution request:
`SET erp_migration.platform_grantor = 'supabase_admin';` followed by the complete
reviewed M1 source. M1 contains its own transaction and final COMMIT; do not nest
another BEGIN/COMMIT or execute selected fragments. Reconcile unknown outcomes
before any retry. Record target, identity, SHA-256, time and transaction outcome.

Execute the reviewed files in order: 001_foundations, 002_core_tables,
003_write_functions, 004_read_only_api, then seed/001_fictional_inventory.sql.
For each later migration, retain its exact identity, session-input and transaction
preconditions. The seed requires empty business tables and is not an update script.
Do not rerun any migration or seed against the existing populated project.
The table below maps M1–M5 to exact paths. Test 005_seed_safe_business_rules.sql is
the later seed-preserving suite; the earlier empty-target suites are not substitutes
and must not be run wholesale against the seeded project. Sequence allocations may
survive rollback. No database test was rerun for final source delivery.

### Runtime architecture and handoff

erp_private holds the units, suppliers, ingredients and append-only transaction
ledger. erp_api exposes inventory_balances and inventory_history. RLS is enabled
and forced on business tables. Separate restricted owner roles and fixed-search-path
SECURITY DEFINER functions enforce the approved privileges. erp_admin_caller has
only the required private-schema USAGE and three business-function EXECUTE grants:
create_ingredient, record_inventory_transaction and deactivate_ingredient. It must
not receive direct table writes or owner membership. See the detailed model below.

For browser reads, expose only the reviewed erp_api schema in the Supabase Data API,
with schema USAGE and view SELECT for anon as reviewed. Never expose erp_private.
SQL Editor access alone is not REST evidence. Server writes go through the existing
inventory-write Edge Function; provision its restricted Session Pooler login using
trusted operator tooling, never committed credentials. Exact environment formats,
CORS, TLS, deployment and switch procedures are in ../WEEK2-FRONTEND.md.

Final accepted state: six original active ingredients and twelve history records.
Two fictional test ingredients are inactive; their six combined ledger entries
remain intentionally visible. F4-4B preserved all original public inventory records
and the nine pre-test history rows by canonical comparison. This does not prove
every private column unchanged. No audit records were deleted or sequence reset.

Multi-session race tests, fresh-target reproduction, backup/restore and complete
catalog-negative-test acceptance remain NOT TESTED in the available delivery
evidence. Production readiness is not claimed. See ../README.md for the consolidated
evidence matrix and ../WEEK2-FRONTEND.md for fixture identities and shutdown limits.

## Historical preparation and security-contract record

All following execution prohibitions and preparation statuses are retained in
their original stage context; current execution still requires explicit approval.

Status: **Prepared for static review only. No SQL has been executed.**

Baseline: approved Schema v1.3; Implementation Contract Freeze v1.0
(Step 8.4E-P); SQL Preparation Contract Finalization v1.0 (Step 8.5A-C).
Historical authorization: Step 8.5A-I3b preparation within three existing files.
Current local correction: Step 8.5A-P5-I1, nine authorized existing files only.
A separate read-only review is required before any execution authorization. File approval does not authorize execution, seed application, connection,
API exposure, credentials, dependency installation, Git actions or deployment.

## Files and order

| Order | File | Purpose |
|---|---|---|
| M1 | `migrations/001_foundations.sql` | Four roles, two schemas, restrictive defaults |
| M2 | `migrations/002_core_tables.sql` | Four tables, indexes, sequence, RLS and grants |
| M3 | `migrations/003_write_functions.sql` | Three controlled writes and private invariant guards |
| M4 | `migrations/004_read_only_api.sql` | Two owner-rights read views, anonymous SELECT |
| M5 | `seed/001_fictional_inventory.sql` | Fictional reference data and six opening incoming records |
| Review | `tests/001_structure_and_privileges.sql` | Assertions and catalog evidence checklist |
| After M3 | `tests/002_business_rules.sql` | Self-contained rollback-based private business acceptance |
| Review | `tests/003_concurrency.sql` | Coordinated multi-session procedures; comment-only material |
| After M4 | `tests/004_api_security.sql` | Section A view fixtures, B database-role checks, C separate REST procedures |

The tenth file is this README. No additional runner or tracking table is added.

## Execution prerequisites and approval gates

**Requires Live Verification:** PostgreSQL 17 compatibility; Supabase custom role
creation and LOGIN feasibility; owner transfer and SET ROLE capability; function
effective privileges; owner-rights view/RLS behavior; Direct IPv6 or Session Pooler
connectivity; approved client/tool; restricted operator identity; API permissions;
concurrency; recovery and rebuild. None has been tested by local preparation.

Before execution, approve the postgres operator and stop-on-first-error tool.
P5-I1 supersedes the earlier absolute no-membership rule only with the exact
administrative exception below. No ordinary runtime privileges are broadened.
Direct owner creation replaces M3/M4 ownership transfers; CREATEROLE alone still
proves neither SET capability nor hosted support. No password provisioning appears
here. Hosted limitations require STOP, never an alternative membership shape.

### Approved P5-I1 administrative exception (not runtime-verified)

For EACH of erp_table_owner, erp_view_owner, erp_function_owner, erp_admin_caller,
require exactly these two rows, and no other row touching any ERP role:

| Member | Grantor | ADMIN | SET | INHERIT | Lifetime |
|---|---|---|---|---|---|
| postgres | independently verified exact platform grantor | true | false | false | persistent platform creator relationship |
| postgres | postgres | false | true | false | persistent approved administrative SET relationship |

Reject ERP-to-ERP edges, any ERP role as member, other members/grantors, missing or
extra rows, and any changed option. Existing ERP role attributes remain restricted.
These are administrator exceptions, not general runtime membership permissions.
The administrator can assume owners and perform maintenance; ordinary callers,
anon/authenticated/authenticator and application roles gain no owner membership.
Review effective access paths into postgres separately before live authorization.

The exact platform grantor is not yet pinned by independently reviewed evidence.
Before execution, pin its exact role name and OID in the approved external record
and supply that name as the non-secret session input erp_migration.platform_grantor
through the separately approved client procedure. Migrations and membership tests
require this input; do not infer it from rows under test, guess it, or change it to
make tests pass. It must resolve to the recorded platform role, not postgres or an
ERP role. Cross-check against the external record for every session, including tests.
No session configuration is performed by this local correction.

M1 validates four platform ADMIN-only rows, then proposes four postgres-granted
SET-only rows with explicit options/grantor. Their creation, coexistence, role
switching and any later revocation remain Requires Live Verification. Never revoke
platform rows. Grant errors stop execution; unexpected shapes fail exact validation.
Do not retry with broader options or another grantor. Persistent SET is intentional;
there is no promise that all administrative memberships will be removed.

M1 creates schemas after SET capability exists, administers schemas as table owner,
and changes each owner's defaults under that owner. Unrelated postgres defaults
are untouched. Fresh schemas have no executor schema-default additions to revoke.
M2 retains table-owner creation. M3 creates six routines as function owner with
temporary private-schema CREATE. Function owner temporarily grants only the three
trigger helpers' EXECUTE to table owner for trigger creation, then revokes it;
table owner revokes schema CREATE before commit. M4 creates views as view owner
with temporary API-schema CREATE and approved retained USAGE, then revokes CREATE.
Schema privileges are administered as table owner. No ownership transfers,
inherited owner privileges or broad helper grants are introduced.

Before M1, separately authorize capability checks for SET grant syntax/grantor,
all four role switches, schema creation/administration, owner defaults, direct
routine/view creation, helper EXECUTE, triggers and cleanup. User-reported version
17.11, corrected postgres defaults and development identity are context, not
independent execution results. M1-M5, business, concurrency and REST: NOT TESTED.

Preserve old source/checksums in an approved external review record. Record new
checksums, target, operator, pinned grantor, start/end and commit/rollback/unknown
outcome for separately approved execution. Stop on error and explicitly roll back.
On lost acknowledgments mark UNKNOWN and reconcile catalogs before retry.
Disposable recovery/rebuild requires separate approval; never drop/reset or blindly
rerun. Original historical contracts are not present locally; the user-approved
P5-I1 amendment supersedes only membership/execution requirements.

Schema-local default REVOKE cannot cancel global default grants. M1 stops unless
the executor's global function/table/sequence defaults are owner-only. Untouched PostgreSQL
defaults normally include PUBLIC EXECUTE and therefore fail this precondition.
These files do not change administrator defaults across unrelated schemas. Any
prerequisite global-default change requires separate M0 approval for that identity
and database, considering its other responsibilities. Use the same reviewed
executor for subsequent stages and inspect defaults before each stage. Review
global and schema-local ACLs, including non-PUBLIC additions, for every creator.

Use an approved stop-on-first-error client and apply each migration once in order,
in its own explicit transaction. After M1 verify grants/ownership; after M2 review
structure; after M3 verify controlled writes in approved disposable fixtures before
accepting the write path. M4 creation/grants do not expose the schema through
Supabase configuration. Review database security before separately authorizing
development API exposure/testing. Never release until actual anonymous REST tests
pass. M5 seed approval is separate; tests requiring seed must wait for M5.

M0 additionally reviews the exact name expression and collation below, the selected
PostgreSQL version, database CONNECT/TEMP privileges and existing PUBLIC/default
grants. Existing public/graphql_public exposure and automatic table-exposure
settings require platform review; no SQL here changes them.

## Schema and business model

All tables and administrative functions reside in unexposed `erp_private`.
Only `erp_api` may expose the two approved views. There is one fictional restaurant,
no tenancy/location field, no additional business table and no stored balance.

- `units`: UUID, code, name, type; fixed US reference meanings.
- `ingredients`: UUID, normalized display name, category, unit reference, active
  status, creation and deactivation timestamps.
- `suppliers`: UUID, name, nullable email/phone, active status, creation timestamp.
- `inventory_transactions`: UUID, unique BIGINT sequence, ingredient and optional
  supplier references, type, positive NUMERIC(12,2), finite business date and timestamp.

Names trim spaces, tabs, LF and CR only. Unique comparison uses
`lower(name COLLATE "C")` across all ingredients. This gives ASCII case-insensitive
comparison. Approved R01 allows non-ASCII names without guaranteed non-ASCII
case equivalence. No Unicode normalization is introduced. Do not
silently substitute a different collation. Category is non-null free text; no
unapproved vocabulary or supplier-name uniqueness rule is imposed.

`create_ingredient(text,text,uuid)` returns UUID. It creates an active ingredient
with no ledger rows. Duplicate names use database unique violation 23505.
`record_inventory_transaction(uuid,text,text,date,uuid)` returns UUID and sequence
as text; optional supplier defaults to NULL. `deactivate_ingredient(uuid)` returns
void. No restore, rename, hard-delete, supplier-management or unit-edit operation
is provided. Active/deactivation timestamp consistency is constrained.

Quantity text grammar is ASCII integer digits with optional one or two fractional
digits. No trimming, signs, exponent, decimal comma, NaN or Infinity. `12.500` is
rejected before conversion. Leading zeros are accepted; significant integer digits
are bounded before unrestricted numeric conversion. Values must be positive and
at most 9999999999.99; `each` requires zero fractional value (`12.00` valid).
Only then is NUMERIC(12,2) assigned. Typed direct inserts cannot preserve original
text precision; denying alternate insert paths is part of the contract.

The DATE argument is a PostgreSQL finite date, not a timestamp/order key. No
unapproved past/future restriction is imposed; trusted callers should use canonical
ISO dates. No business timezone or automatic date conversion is assumed.

## Ownership and permissions

`erp_table_owner` owns both schemas, four tables and sequence; NOLOGIN/NOBYPASSRLS.
`erp_view_owner` owns views, not tables, and reads only required underlying columns.
It has no supplier access. `erp_function_owner` owns restricted SECURITY DEFINER
functions and private guards, not tables. All three are non-login, non-inheriting,
without administrative or bypass attributes. `erp_admin_caller` is LOGIN, with
private-schema USAGE and EXECUTE on only the three business functions; it has no
direct table/sequence access. Only the exact postgres administrative memberships
defined above are permitted.

All tables enable and force RLS. Explicit owner policies support privileged
seed/maintenance; runtime policies permit required reads and writes. Locking
SELECT requires an UPDATE privilege on at least one column: function owner receives
unit-name and supplier-active UPDATE privileges with policies that permit row
visibility but reject actual new rows (WITH CHECK false). This locking/RLS behavior
is **Requires Live Verification**. Ingredient status/timestamp updates are permitted
for deactivation. Ledger owner privileges remain exceptional maintenance authority;
ordinary roles have no UPDATE/DELETE/TRUNCATE, and triggers reject these operations.

Functions have fixed `pg_catalog, pg_temp` search paths and fully qualified data
objects. Public execution is revoked before commit. Helpers are not callable by
the operator. Temporary schema CREATE grants for direct owner creation are revoked
in the same transaction. No dynamic SQL or caller-controlled identifiers are used.
Owner defaults and schema additions are restricted; executor global defaults are
an explicit preflight gate, not repaired by schema-local revocation;
actual inherited/default Supabase grants still require catalog review.

`anon` receives API-schema USAGE and only view SELECT. `authenticated` receives no
ERP grants. Neither can read private tables, execute administrative functions or
allocate sequence values. No service-role key is used as an ordinary writer.

## Locking, ordering and integrity

Write functions require READ COMMITTED and are VOLATILE. Each call participates in
the caller transaction; it does not commit itself. Lock order: ingredient FOR
UPDATE, separate balance aggregation statement, unit FOR SHARE, optional supplier
FOR SHARE, sequence allocation, insert. Deactivation uses the same ingredient lock
and a later balance statement. Locks persist until outer commit/rollback.

Supplier maintenance must take a conflicting supplier lock and never reverse the
ingredient-to-supplier order. Unit-definition guards coordinate with writers' unit
SHARE locks; ingredient-unit changes serialize with first writes. Historical units
and definitions cannot change. Ordinary roles cannot perform such maintenance.
No global application lock is introduced; same-unit/supplier shared locks coexist.

The sequence uses CACHE 1, NO CYCLE and no column default: allocation occurs only
after the ingredient lock. Gaps survive rollback. Sequence order is not global
commit order. Historical per-ingredient running calculations use sequence, never
business date or timestamp. A high global sequence watermark cannot safely mean
that all lower values have committed. All public history reads request explicit
ascending sequence order.

Triggers and privileges defend ordinary roles; a privileged administrator can
override protections and must follow separately reviewed maintenance procedures.
No retry/idempotency feature is invented. Retry confirmed rollback errors only
with a bounded approved policy. Ambiguous connection loss requires trusted ledger
reconciliation, not automatic replay. Keep outer transactions short.

## Public interface and exact serialization

Balances fields: ingredient_id, ingredient_name, category, unit_code, current_balance.
Active ingredients with no transactions yield exact zero. History fields:
ledger_sequence, ingredient_name, transaction_type, quantity, unit_code,
transaction_date, created_at. History retains inactive ingredients, with no
supplier join/contact disclosure. Views intentionally use owner rights.

SUM balances remain unrestricted exact numeric and can exceed an individual
transaction maximum. APIs may emit NUMERIC/BIGINT as JSON numeric tokens. Preserve
raw response text and use a separately approved lossless frontend decoding path;
ordinary JSON.parse/Number can lose precision before string conversion. Send
quantity input as original text; never parseFloat/round first. Sequence strings
may be handled as BigInt internally, serialized as strings. The write function's
sequence result is already text. Frontend serialization remains an integration
gate; no dependency or frontend implementation is introduced here.

## Seed and repeatability

Seed uses reserved fictional UUIDs for reference units and one supplier with an
example.invalid email and no phone. Six generated ingredients receive incoming
records dated 2026-01-01. There is no conversion or migration from Week 1.

| Ingredient | Balance | Unit |
|---|---|---|
| Beef | 27 | lb |
| Chicken | 18.50 | lb |
| Salmon | 12 | lb |
| Milk | 8 | pt |
| Cooking Oil | 64 | fl oz |
| Eggs | 36 | each |

Seed locks all four tables, requires all to be empty, uses approved write functions
for business records, checks results and commits atomically. A repeat seed fails
explicitly before insertion; it does not duplicate stock or delete existing data.

Migrations intentionally use CREATE without IF NOT EXISTS/OR REPLACE. Before each
run, an approved external execution record must establish exact version, file
checksum, target, identity, start/end, transaction outcome and sanitized errors.
No new tracking table/file is authorized here. Unknown state or existing objects
means STOP. Do not mark a version applied unless commit is confirmed. A client
disconnect is ambiguous; inspect actual state before any retry. Record the seed
version separately. Partial failures require an approved recovery plan, never blind
rerun, destructive down migrations, schema drops or database resets.

## Verification and evidence

No tests have run. `001` supplies assertions plus mandatory manual catalog review;
it is not exhaustive automated acceptance. `002` uses exception-specific assertions
inside a rolled-back fixture transaction; sequences can still advance. Remaining
manual checks are explicitly listed. `003` coordinates independent sessions;
commented blocks must not be treated as an executable single-session test.
`004` distinguishes database role checks from required real HTTP evidence.

I2 corrections retain the approved RLS/ACL architecture. Structure tests now
assert table shape/defaults, exact column privilege matrices, schema/sequence
access, function signatures and attributes, required triggers/indexes/constraints,
locking policies and effective default ACLs. Run default-ACL assertions as the
same reviewed migration executor; another inspection identity does not establish
the actual creator's defaults. Catalog expression-rendering differences require
review of equivalent semantics, not blind test weakening. Constraint expressions,
remaining policies and FK target/key definitions still require the explicit
catalog review alongside business tests; assertions are not exhaustive proof.

Business materials add permitted non-ASCII input with ASCII-case duplicates,
inactive suppliers, date/isolation boundaries, exact balances, minimum quantities,
rollback verification and function-owner locking/RLS probes. Those probes use
existing grants only and remain rollback-based. A probe under SET ROLE is not
restricted LOGIN evidence. RLS UPDATE rejection must be confirmed as the intended
policy rejection (not a missing fixture or unrelated ACL failure), together with
successful locking reads and the structure privilege matrix. Multi-session and
REST materials specify positive controls, barriers, before/after evidence and
lossless decimal comparisons. All database, concurrency and HTTP results remain
NOT TESTED. R3a statically accepted the I3a strict/null return assertion; I3b
preserves that assertion. The I3b stage separation requires its own read-only review.

Record PASS/FAIL/NOT TESTED for each contract gate S01-S04, C01-C03, D01-D05,
A01, R01 and W01. Retain sanitized SQL results, expected/actual errors, catalog
ownership/ACL/policy snapshots, multi-session timelines and raw REST responses.
Verify rollback leaves baseline rows unchanged, rebuild from an approved clean
development environment reproduces structure/balances, seed rerun stops, ordinary
roles cannot bypass validation, inactive history remains visible and supplier
contacts stay private. Recovery/rebuild execution requires separate approval.

Week 1 source and `restaurantInventory.v1` must remain unchanged. Any Week 2 frontend
is a separately approved read-only demonstration. Browser assets must contain no
database passwords, service_role keys or secrets. A publishable key is public and
does not replace RLS/grants. Never request or commit credentials.

STOP on missing platform capability, unsafe ownership/RLS behavior, unexpected
objects or privilege inheritance, partial/ambiguous migrations, credential exposure,
paid requirements, Week 1 changes or architectural drift. Return to design review
instead of weakening roles or switching to security_invoker. Static review cannot
establish database, REST, concurrency, backup or recovery correctness.

## I3b M3 acceptance and stage separation

All materials remain PREPARED ONLY. No PostgreSQL parsing/execution, database
test, multi-session test or HTTP verification has run. A local static PASS is
not a runtime PASS. R2-03 through R2-09 have not been remediated by this step.

### M3 single-session prerequisites

Use a quiescent isolated development target with M1-M3 confirmed applied, exactly
four empty business tables, six private routines, and an empty API schema.
Unexpected data or objects mean STOP; never reuse seed records or delete/reset
data. The suite uses private-table trusted verification only, without public views.
The full structure test 001 still requires M4 and must NOT be run wholesale as a
pre-M4 gate. Its relevant private checks are bounded by the M3 preflight in 002;
neither this subset nor 002 replaces all remaining catalog review.

The coordinator must already have independently verified authority to SET ROLE
at top-level statement boundaries to table owner, admin caller and function owner.
No SET ROLE is placed inside a function or exception subtransaction. The suite
adds no membership or grants. Exact P5-I1 administrator membership requirements,
hosted capability, global owner-only creator defaults, and removal of temporary
schema CREATE/helper EXECUTE remain separate execution-readiness gates. If
the coordinator cannot run the tests within that model, STOP for approval; do not
grant broader rights. SET ROLE probes do not prove direct restricted LOGIN.

### Independent fictional fixture inventory

All single-session fixtures live only in the test transaction:

| Object | Identity / behavior |
|---|---|
| lb unit | 83000000-0000-4000-8000-000000000001; Pound / WEIGHT |
| each unit | 83000000-0000-4000-8000-000000000002; Each / COUNT |
| Active supplier | 83000000-0000-4000-8000-000000000011; fictional, no contact secrets |
| Inactive supplier | 83000000-0000-4000-8000-000000000012; fictional |
| Missing unit/ingredient probe | ...0091 in the same UUID namespace, asserted absent by empty setup |
| Missing supplier probe | ...0092 in the same namespace |
| P3B Stock | Generated UUID; padded input normalized; four transactions, final zero, deactivated |
| P3B Count | Generated UUID; 12.00 incoming, 12 consumption; two rows, zero, active |
| P3B Precision | Generated UUID; 12 + 12.5 + 12.50 + 9999999999.99; four rows, balance 10000000036.99 |
| P3B Zero | Generated UUID; no ledger rows; deactivated at zero |
| P3B accented-name fixture | Generated UUID; non-ASCII allowed, embedded ASCII case duplicate rejected |
| P3B Rolled Back | Deliberate subtransaction fixture; two minimum-quantity writes, no surviving rows |

P3B Stock receives 12.50 with the active supplier, 0.50 without a supplier,
consumes 3.00, rejects 10.01 consumption and nonzero deactivation, consumes 10.00
with a backdated business label, then deactivates. Balances are 0,12.50,13,10,0.
Owner-only reference setup is justified because no ordinary reference-management
interface is approved. All ordinary ingredient/ledger operations use controlled
functions. No extra database objects, temporary tables or helper routines are made.

### Execution and evidence protocol (separate authorization required)

1. Review scripts, checksum, target and coordinator capabilities; enable approved
   stop-on-first-error behavior. Record session/effective identities and isolation.
2. Run the complete M3 file only after preconditions are verified. It begins READ
   COMMITTED, locks the fixture tables for the test, checks stage/security state,
   then inserts references as owner and runs business cases as admin caller.
3. Successful transaction calls use SELECT INTO STRICT with explicit null/digits
   assertions. A transaction-local custom setting, erp_test.return_evidence,
   transports JSON return evidence between top-level role blocks without a table
   or privilege change. Trusted verification matches ten distinct returned UUIDs,
   sequences and ingredients to ten exact ledger records. Rollback restores the
   setting along with the transaction context.
4. Expected business rejections check SQLSTATE plus the current function's English
   error message. Unrelated messages/states FAIL and propagate. Unique violations
   identify the intended normalized-name index. The deliberate rollback marker
   has its own SQLSTATE ZP301/message; cardinality errors are never accepted by it.
   Permission denials emit diagnostic messages. Locking probes require visible
   fixtures and UPDATE column rights; actual forbidden updates must report the
   intended row-policy rejection. Server-language/message differences require
   review, never blanket exception handling or an assumed PASS.
5. Trusted owner checks counts, exact ordered ledger content/balances and ingredient
   status; checks historical unit and ledger mutation guards against existing
   targets. Function-owner probes exercise existing locking grants/RLS.
6. Always ROLLBACK the outer fixture transaction. A fresh read-only transaction
   checks all four tables empty, including reference and non-ASCII fixtures.
   Unsupported-isolation probes use a separate REPEATABLE READ transaction that
   also rolls back. No trial row is committed.
7. On any unexpected error: stop, explicitly roll back using the approved client,
   and inspect baseline before deciding whether to retry. Do not continue later
   statements or migrations automatically. A lost connection/result is ambiguous;
   reconcile actual state before claiming rollback or success.

Expected states include 22023 invalid inputs/isolation, 23505 intended duplicate,
23514 intended business/guard rejection, and 42501 permission denial. Record each
case PASS/FAIL/NOT TESTED with observed errors and trusted results; missing evidence
is NOT VERIFIED. Preserve full sanitized output, returned values and final baseline
evidence through a separately approved recording mechanism. No credentials in logs.

All fixture rows roll back, but sequence allocations can survive rollback.
Never require contiguous values, a fixed initial value or sequence restoration.
Do not DELETE/TRUNCATE fixtures, disable guards, reset sequences or drop schemas
for cleanup. DELETE/TRUNCATE statements inside negative probes are rejection
tests, not cleanup operations; unexpected success raises failure and rolls back.

### Later stage gates

- Multi-session: no implementation/execution here. Test post-lock snapshots,
  consumption/deactivation/supplier races, rollback orderings and sequence behavior
  separately. Commit-based tests require a separately approved disposable M1-M3
  verification target or approved equivalent lifecycle. Shared committed fixtures
  cannot be erased through ordinary ledger cleanup; leaving them in the primary
  target would violate seed's empty-table prerequisite. Do not create a target
  or treat single-session PASS as concurrency acceptance. Full write-path
  acceptance remains conditional on the required multi-session evidence.
- Post-M4: API file Section A preserves all three former business-suite view
  assertions: active unused ingredient at zero; three inactive-ingredient history
  rows; inactive ingredients absent from balances. It creates its own each-unit
  and three ingredient fixtures in an empty post-M4 target, checks both view-owner
  and database anon outputs, rolls back and verifies the empty baseline.
  Section B is database-role inspection only. Sections A/B need no HTTP exposure.
  After seed, do not run Section A against populated tables; it must stop.
- Post-M5: retain all seed-specific checks: four exact US reference definitions,
  fictional supplier, six ingredients/transactions, Beef 27 lb, Chicken 18.50 lb,
  Salmon 12 lb, Milk 8 pt, Cooking Oil 64 fl oz, Eggs 36 each; seed rerun stops;
  recovery/rebuild require separate approved evidence. The seed is unchanged.
- REST/frontend: API file Section C comment procedures require actual anonymous
  requests, approved development exposure, confidentiality and lossless NUMERIC/
  BIGINT evidence. Database role results never establish HTTP/API PASS. No frontend
  integration, key handling or Data API configuration is authorized by these files.

Historically I3b prepared M3 tests and relocated view assertions only. P5-I1 adds
the approved local compatibility correction. Remaining risks retain separate gates.
Next: static review and separately authorized live capability checks, not automatic M1.

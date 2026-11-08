-- PREPARED ONLY. Section A: post-M4 database-view fixtures, BEFORE seed.
-- Section B: existing database-role checks. Section C: real REST instructions.
-- Each execution category needs separate approval. No HTTP is run by this file.
-- Run with the approved postgres session, verified stop-on-error and explicit transactions.
-- Require the exact P5-I1 membership matrix and pinned platform grantor from README;
-- verify through structure acceptance before this suite. No grants are added here.
BEGIN ISOLATION LEVEL READ COMMITTED;
SET LOCAL ROLE erp_table_owner;
LOCK TABLE erp_private.units, erp_private.ingredients, erp_private.suppliers,
  erp_private.inventory_transactions IN SHARE ROW EXCLUSIVE MODE;
DO $view_preflight$
BEGIN
  IF pg_catalog.to_regclass('erp_api.inventory_balances') IS NULL
    OR pg_catalog.to_regclass('erp_api.inventory_history') IS NULL THEN
    RAISE EXCEPTION 'FAIL: post-M4 views required';
  END IF;
  IF EXISTS (SELECT FROM erp_private.units) OR EXISTS (SELECT FROM erp_private.ingredients)
    OR EXISTS (SELECT FROM erp_private.suppliers) OR EXISTS (SELECT FROM erp_private.inventory_transactions) THEN
    RAISE EXCEPTION 'FAIL: view fixture section requires empty business tables; no cleanup/reset';
  END IF;
END;
$view_preflight$;
INSERT INTO erp_private.units(id,code,name,unit_type)
  VALUES ('84000000-0000-4000-8000-000000000001','each','Each','COUNT');
SET LOCAL ROLE erp_admin_caller;
DO $view_fixtures$
DECLARE v_count uuid; v_empty uuid;
BEGIN
  PERFORM erp_private.create_ingredient('P3B View Active Zero','Test','84000000-0000-4000-8000-000000000001');
  v_empty := erp_private.create_ingredient('P3B View Empty','Test','84000000-0000-4000-8000-000000000001');
  v_count := erp_private.create_ingredient('P3B View Count','Test','84000000-0000-4000-8000-000000000001');
  PERFORM erp_private.record_inventory_transaction(v_count,'INCOMING','12',DATE '2026-01-01');
  PERFORM erp_private.record_inventory_transaction(v_count,'INCOMING','12.00',DATE '2026-01-01');
  PERFORM erp_private.record_inventory_transaction(v_count,'CONSUMPTION','24',DATE '2025-12-31');
  PERFORM erp_private.deactivate_ingredient(v_count);
  PERFORM erp_private.deactivate_ingredient(v_empty);
END;
$view_fixtures$;
-- Preserved view-owner assertions formerly in the business suite:
SET LOCAL ROLE erp_view_owner;
DO $views$
BEGIN
  IF NOT EXISTS (SELECT FROM erp_api.inventory_balances
    WHERE ingredient_name='P3B View Active Zero' AND current_balance=0) THEN
    RAISE EXCEPTION 'FAIL: active zero-stock ingredient missing';
  END IF;
  IF (SELECT count(*) FROM erp_api.inventory_history WHERE ingredient_name='P3B View Count') <> 3 THEN
    RAISE EXCEPTION 'FAIL: inactive history hidden';
  END IF;
  IF EXISTS (SELECT FROM erp_api.inventory_balances WHERE ingredient_name IN ('P3B View Count','P3B View Empty')) THEN
    RAISE EXCEPTION 'FAIL: inactive ingredient in balances';
  END IF;
END;
$views$;
-- Same positive row controls under the database anonymous role; not HTTP proof.
SET LOCAL ROLE anon;
DO $anonymous_view_fixtures$
BEGIN
  IF NOT EXISTS (SELECT FROM erp_api.inventory_balances WHERE ingredient_name='P3B View Active Zero' AND current_balance=0)
    OR (SELECT count(*) FROM erp_api.inventory_history WHERE ingredient_name='P3B View Count')<>3
    OR EXISTS (SELECT FROM erp_api.inventory_balances WHERE ingredient_name IN ('P3B View Count','P3B View Empty')) THEN
    RAISE EXCEPTION 'FAIL: anonymous view fixture results';
  END IF;
END;
$anonymous_view_fixtures$;
ROLLBACK;
BEGIN READ ONLY;
SET LOCAL ROLE erp_table_owner;
DO $view_baseline$
BEGIN
  IF EXISTS (SELECT FROM erp_private.units) OR EXISTS (SELECT FROM erp_private.ingredients)
    OR EXISTS (SELECT FROM erp_private.suppliers) OR EXISTS (SELECT FROM erp_private.inventory_transactions) THEN
    RAISE EXCEPTION 'FAIL: post-M4 fixture rollback baseline';
  END IF;
END;
$view_baseline$;
ROLLBACK;

-- SECTION B: database-role checks only; not a substitute for real REST tests.
-- PREPARED ONLY. DATABASE CHECKS PLUS MANUAL REST VERIFICATION MATERIAL.
-- Separate execution/network approval required. No credentials included.
-- API exposure is an additional configuration action, not performed by SQL.
-- Section B requires M1-M4 DB checks and verified role-switching authority.
-- Section C additionally requires approved development API exposure and real
-- anonymous requests. Database checks do not require HTTP or API configuration.
BEGIN READ ONLY;
SET LOCAL ROLE anon;
SELECT ingredient_id, ingredient_name, category, unit_code, current_balance
  FROM erp_api.inventory_balances ORDER BY ingredient_name;
SELECT ledger_sequence, ingredient_name, transaction_type, quantity, unit_code,
  transaction_date, created_at FROM erp_api.inventory_history ORDER BY ledger_sequence;
DO $deny$
BEGIN
  BEGIN
    PERFORM 1 FROM erp_private.units;
    RAISE EXCEPTION 'FAIL: anonymous private read';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    PERFORM erp_private.deactivate_ingredient('00000000-0000-4000-8000-000000000000');
    RAISE EXCEPTION 'FAIL: anonymous administrative execution';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    PERFORM pg_catalog.nextval('erp_private.erp_ledger_sequence'::regclass);
    RAISE EXCEPTION 'FAIL: anonymous sequence manipulation';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END;
$deny$;
ROLLBACK;

-- REQUIRED REAL REST MATRIX (not executable by this SQL file):
-- In an approved HTTP client use the project's public publishable key, with
-- NO signed-in user and NO privileged bearer token. Verify effective anon role
-- and current platform header requirements before testing. Do not paste keys
-- or connection strings into evidence or add them to the repository.
-- Each row needs sanitized request/response, identity, timestamp, expected
-- status class and trusted before/after DB evidence for mutation attempts.
-- A network/authentication failure alone does not prove database authorization.
--
-- 1 GET /rest/v1/inventory_balances?select=* ; Accept-Profile: erp_api
--   Expected successful read, exactly five approved columns; unused active
--   ingredient zero; inactive ingredient absent. Include fixture evidence.
-- 2 GET /rest/v1/inventory_history?select=*&order=ledger_sequence.asc
--   Accept-Profile: erp_api. Exactly seven approved columns; inactive history
--   present, no supplier/contact fields, explicit ascending sequence order.
-- 3 GET every private table using Accept-Profile: erp_private, then erp_api,
--   public and any other exposed schema. No private data; denial/not exposed.
-- 4 POST/PATCH/DELETE each public view and each base-table route, using
--   Content-Profile for the intended schema. No mutation. Audit DB afterward.
-- 5 POST /rest/v1/rpc/create_ingredient, record_inventory_transaction,
--   deactivate_ingredient and each helper under every exposed schema and
--   erp_private. No administrative execution. Do not accept an exposed wrapper.
-- 6 Ask for supplier_id/contact_email/phone via explicit selection or embedding.
--   Requests must not return those fields or discover a supplier relation path.
-- 7 Review exposed schemas, generated API metadata and all RPC overloads.
--   public/graphql_public need independent review; private ERP references must
--   not become reachable through GraphQL, other views or SECURITY DEFINER RPCs.
-- 8 Repeat denial checks with a genuine authenticated context only under
--   separate approved testing arrangements; this project adds no Auth UI.
--
-- A01 NUMERIC/BIGINT SERIALIZATION:
-- Compare raw HTTP response text with trusted DB decimal strings for 12.50,
-- maximum quantity, aggregate balances above single-row range, and sequence
-- >9007199254740991 using separately approved isolated fixtures. Do not reset
-- the ordinary ledger sequence to manufacture this test. Native JSON.parse
-- of numeric tokens is not accepted as lossless evidence. Verify a frontend-
-- compatible decoder preserving numeric/BIGINT tokens as decimal strings,
-- before integration. Do not alter approved view fields to hide precision loss.
--
-- W01 FRONTEND GATE (future, not part of SQL execution): compare Week 1 source
-- and restaurantInventory.v1 before/after separate read-only Week 2 demo;
-- neither may change. No import/conversion from Beef/kg. Inspect browser
-- assets/source maps/network for passwords, service_role keys or secret keys.
-- Publishable key is public, not an authorization substitute.
--
-- Release gate: database role checks alone NEVER establish REST test PASS.
-- Record each row PASS/FAIL/NOT TESTED; release blocked by missing evidence.

-- I2 REQUIRED EVIDENCE DETAIL (Requires Live Verification):
-- First establish a successful anonymous positive control with the same project,
-- key/header setup and schema profile as the denial requests. Attribute denial
-- to the intended layer; invalid credentials or unreachable endpoints are not
-- authorization evidence. Capture HTTP status, sanitized headers/body, selected
-- profile and effective identity. Never persist credentials in test evidence.
-- Test write methods using separately approved fixtures and bounded filters;
-- an accidentally writable endpoint must not mutate all development rows.
-- Compare trusted before/after row counts, identities, quantities and status.
--
-- Verify view-owner RLS with active-unused and inactive-historical fixtures:
-- anonymous outputs must match the approved fields/rows, while supplier contact
-- sentinel values remain absent from select=*, explicit fields, embedding and
-- any unexpected RPC/view/GraphQL path. Catalog checks are complementary.
--
-- Numeric evidence compares exact mathematical decimal values; display scale
-- (12.50 versus 12.5) is a separate formatting matter. Original submitted text
-- is validated at the write boundary, not reconstructed from API output.
-- Compare raw numeric tokens BEFORE native JSON.parse with DB text, then with
-- the approved lossless decoder result. Check adjacent BIGINT values above
-- 9007199254740991 stay distinct, decimals retain hundredths and aggregate
-- balances above a single-row maximum stay exact. Use approved isolated fixture
-- setup; never alter normal sequence state or approved view types as a shortcut.
-- Decoder implementation, REST calls and exposure settings remain unauthorized.

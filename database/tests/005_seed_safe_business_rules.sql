-- PREPARED ONLY. Test 2A; execution requires separate authorization.
-- Run the COMPLETE file once as postgres in the confirmed restaurant-erp-dev project.
-- Require a quiescent M1-M5 target; supplied baseline is evidence, not test execution.
-- Stop on any unexpected error, explicitly roll back, and inspect the baseline.
-- No persistent helper objects. Sequence allocations may survive rollback.
BEGIN;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
SET LOCAL erp_migration.platform_grantor = 'supabase_admin';
SET LOCAL lock_timeout = '5s';
-- Exact P5-I1 administrator exception; no inferred platform grantor.
DO $seed_memberships$
DECLARE v_platform oid;
BEGIN
  IF session_user <> 'postgres' OR current_user <> 'postgres' THEN
    RAISE EXCEPTION 'P5-I1 requires session_user and current_user postgres at stage entry';
  END IF;
  SELECT oid INTO v_platform FROM pg_catalog.pg_roles
    WHERE rolname = NULLIF(pg_catalog.current_setting('erp_migration.platform_grantor', true), '');
  IF v_platform IS NULL OR v_platform = 'postgres'::regrole
    OR v_platform IN (SELECT oid FROM pg_catalog.pg_roles WHERE rolname IN ('erp_table_owner','erp_view_owner','erp_function_owner','erp_admin_caller')) THEN
    RAISE EXCEPTION 'Supply the independently verified exact platform grantor in erp_migration.platform_grantor; do not infer or guess it';
  END IF;
  IF (SELECT count(*) FROM pg_catalog.pg_roles WHERE rolname IN ('erp_table_owner','erp_view_owner','erp_function_owner','erp_admin_caller')) <> 4 THEN
    RAISE EXCEPTION 'All four ERP roles must exist for membership verification';
  END IF;
  IF EXISTS (
    WITH expected AS (
      SELECT oid AS roleid, 'postgres'::regrole::oid AS member, v_platform AS grantor,
        true AS admin_option, false AS inherit_option, false AS set_option
      FROM pg_catalog.pg_roles WHERE rolname IN ('erp_table_owner','erp_view_owner','erp_function_owner','erp_admin_caller')
      UNION ALL
      SELECT oid, 'postgres'::regrole::oid, 'postgres'::regrole::oid, false, false, true
      FROM pg_catalog.pg_roles WHERE rolname IN ('erp_table_owner','erp_view_owner','erp_function_owner','erp_admin_caller')
    ), actual AS (
      SELECT roleid, member, grantor, admin_option, inherit_option, set_option
      FROM pg_catalog.pg_auth_members
      WHERE roleid IN (SELECT oid FROM pg_catalog.pg_roles WHERE rolname IN ('erp_table_owner','erp_view_owner','erp_function_owner','erp_admin_caller'))
        OR member IN (SELECT oid FROM pg_catalog.pg_roles WHERE rolname IN ('erp_table_owner','erp_view_owner','erp_function_owner','erp_admin_caller'))
    )
    SELECT FROM expected e FULL JOIN actual a
      ON a.roleid=e.roleid AND a.member=e.member AND a.grantor=e.grantor
      AND a.admin_option=e.admin_option AND a.inherit_option=e.inherit_option AND a.set_option=e.set_option
    WHERE e.roleid IS NULL OR a.roleid IS NULL
  ) THEN
    RAISE EXCEPTION 'P5-I1 membership mismatch: stop and review exact member, role, grantor and ADMIN/INHERIT/SET; no automatic cleanup or alternative shape';
  END IF;
END;
$seed_memberships$;
DO $target$
BEGIN
  IF current_database()<>'postgres' OR current_setting('server_version_num')::integer/10000<>17
    OR (SELECT oid FROM pg_catalog.pg_roles WHERE rolname='supabase_admin') IS DISTINCT FROM 10::oid THEN
    RAISE EXCEPTION 'FAIL: unexpected database/version/platform grantor; confirm development project externally';
  END IF;
END;
$target$;
SET LOCAL ROLE erp_table_owner;
LOCK TABLE erp_private.units, erp_private.ingredients, erp_private.suppliers,
  erp_private.inventory_transactions IN SHARE ROW EXCLUSIVE MODE;
DO $seed_baseline$
DECLARE r record; v_snapshot jsonb;
BEGIN
  IF (SELECT count(*) FROM erp_private.ingredients)<>6
    OR (SELECT count(*) FROM erp_private.inventory_transactions)<>6
    OR (SELECT count(*) FROM erp_private.units)<>4
    OR (SELECT count(*) FROM erp_private.suppliers)<>1 THEN
    RAISE EXCEPTION 'FAIL: expected original six-ingredient/six-record seed baseline';
  END IF;
  IF EXISTS (
    SELECT FROM (VALUES
      ('10000000-0000-4000-8000-000000000001'::uuid,'lb','Pound','WEIGHT'),
      ('10000000-0000-4000-8000-000000000002'::uuid,'pt','US Pint','VOLUME'),
      ('10000000-0000-4000-8000-000000000003'::uuid,'fl oz','US Fluid Ounce','VOLUME'),
      ('10000000-0000-4000-8000-000000000004'::uuid,'each','Each','COUNT')
    ) e(id,code,name,unit_type) LEFT JOIN erp_private.units u ON u.id=e.id
    WHERE u.id IS NULL OR u.code IS DISTINCT FROM e.code OR u.name IS DISTINCT FROM e.name
      OR u.unit_type IS DISTINCT FROM e.unit_type
  ) OR NOT EXISTS (SELECT FROM erp_private.suppliers
    WHERE id='20000000-0000-4000-8000-000000000001'::uuid AND name='Fictional Demo Supply'
      AND contact_email='inventory@example.invalid' AND phone IS NULL AND is_active) THEN
    RAISE EXCEPTION 'FAIL: original seed units or supplier differ';
  END IF;
  IF EXISTS (
    SELECT FROM (VALUES ('Beef',27::numeric,'lb'),('Chicken',18.50,'lb'),
      ('Salmon',12,'lb'),('Milk',8,'pt'),('Cooking Oil',64,'fl oz'),('Eggs',36,'each')) e(name,balance,code)
    LEFT JOIN erp_private.ingredients i ON i.name=e.name
    LEFT JOIN erp_private.units u ON u.id=i.unit_id
    LEFT JOIN erp_private.inventory_transactions t ON t.ingredient_id=i.id
    GROUP BY e.name,e.balance,e.code,i.id,i.is_active,i.deactivated_at,u.code
    HAVING i.id IS NULL OR i.is_active IS DISTINCT FROM true OR i.deactivated_at IS NOT NULL
      OR u.code IS DISTINCT FROM e.code OR count(t.id)<>1
      OR bool_and(t.transaction_type='INCOMING' AND t.transaction_date=DATE '2026-01-01'
        AND t.supplier_id='20000000-0000-4000-8000-000000000001'::uuid) IS DISTINCT FROM true
      OR sum(t.quantity) IS DISTINCT FROM e.balance
  ) THEN
    RAISE EXCEPTION 'FAIL: seed ingredient, unit, opening record or balance mismatch';
  END IF;
  FOR r IN SELECT * FROM pg_catalog.pg_roles WHERE rolname IN
    ('erp_table_owner','erp_view_owner','erp_function_owner','erp_admin_caller') LOOP
    IF r.rolsuper OR r.rolcreatedb OR r.rolcreaterole OR r.rolinherit OR r.rolreplication OR r.rolbypassrls
      OR r.rolcanlogin<>(r.rolname='erp_admin_caller') THEN
      RAISE EXCEPTION 'FAIL: unexpected ERP role attributes: %',r.rolname;
    END IF;
  END LOOP;
  FOR r IN SELECT c.oid,c.relname,c.relowner,c.relrowsecurity,c.relforcerowsecurity
    FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='erp_private' AND c.relname IN ('units','ingredients','suppliers','inventory_transactions') LOOP
    IF r.relowner<>'erp_table_owner'::regrole OR NOT r.relrowsecurity OR NOT r.relforcerowsecurity
      OR pg_catalog.has_table_privilege('erp_admin_caller',r.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
      OR pg_catalog.has_any_column_privilege('erp_admin_caller',r.oid,'SELECT,INSERT,UPDATE,REFERENCES') THEN
      RAISE EXCEPTION 'FAIL: unexpected ownership, RLS or caller base-table access: %',r.relname;
    END IF;
  END LOOP;
  FOR r IN SELECT oid,proname,proowner,prosecdef,proconfig FROM pg_catalog.pg_proc
    WHERE oid IN ('erp_private.create_ingredient(text,text,uuid)'::regprocedure,
      'erp_private.record_inventory_transaction(uuid,text,text,date,uuid)'::regprocedure,
      'erp_private.deactivate_ingredient(uuid)'::regprocedure) LOOP
    IF r.proowner<>'erp_function_owner'::regrole OR NOT r.prosecdef
      OR NOT COALESCE('search_path=pg_catalog, pg_temp'=ANY(r.proconfig),false)
      OR NOT pg_catalog.has_function_privilege('erp_admin_caller',r.oid,'EXECUTE') THEN
      RAISE EXCEPTION 'FAIL: unexpected controlled function security: %',r.proname;
    END IF;
  END LOOP;
  IF NOT pg_catalog.has_schema_privilege('erp_admin_caller','erp_private','USAGE')
    OR pg_catalog.has_sequence_privilege('erp_admin_caller','erp_private.erp_ledger_sequence','USAGE,SELECT,UPDATE') THEN
    RAISE EXCEPTION 'FAIL: unexpected caller schema/sequence privileges';
  END IF;
  SELECT jsonb_build_object(
    'units',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM erp_private.units t),
    'suppliers',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM erp_private.suppliers t),
    'ingredients',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM erp_private.ingredients t),
    'ledger',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM erp_private.inventory_transactions t)) INTO v_snapshot;
  PERFORM pg_catalog.set_config('erp_test2a.seed_rows',v_snapshot::text,true);
  RAISE NOTICE 'Original seed IDs and full-row snapshot: %',v_snapshot;
END;
$seed_baseline$;
SET LOCAL ROLE erp_view_owner;
DO $seed_views$
DECLARE v_snapshot jsonb;
BEGIN
  IF (SELECT count(*) FROM erp_api.inventory_balances)<>6
    OR (SELECT count(*) FROM erp_api.inventory_history)<>6
    OR EXISTS (SELECT FROM erp_api.inventory_history WHERE transaction_type<>'INCOMING') THEN
    RAISE EXCEPTION 'FAIL: expected six seed balance/history view records';
  END IF;
  IF EXISTS (
    SELECT FROM (VALUES ('Beef',27::numeric,'lb'),('Chicken',18.50,'lb'),('Salmon',12,'lb'),
      ('Milk',8,'pt'),('Cooking Oil',64,'fl oz'),('Eggs',36,'each')) e(name,balance,code)
    LEFT JOIN erp_api.inventory_balances b ON b.ingredient_name=e.name
    WHERE b.ingredient_id IS NULL OR b.current_balance IS DISTINCT FROM e.balance
      OR b.unit_code IS DISTINCT FROM e.code
  ) THEN RAISE EXCEPTION 'FAIL: seed balance view differs'; END IF;
  SELECT jsonb_build_object(
    'balances',(SELECT jsonb_agg(to_jsonb(t) ORDER BY ingredient_id) FROM erp_api.inventory_balances t),
    'history',(SELECT jsonb_agg(to_jsonb(t) ORDER BY ledger_sequence) FROM erp_api.inventory_history t)) INTO v_snapshot;
  PERFORM pg_catalog.set_config('erp_test2a.seed_views',v_snapshot::text,true);
  RAISE NOTICE 'Original balance/history snapshot: %',v_snapshot;
END;
$seed_views$;
SET LOCAL ROLE erp_admin_caller;
DO $business$
DECLARE v_id uuid; v_name text; v_unit uuid := '10000000-0000-4000-8000-000000000004';
  v_result record; v_returns jsonb := '[]'::jsonb;
BEGIN
  IF current_user<>'erp_admin_caller' THEN RAISE EXCEPTION 'FAIL: incorrect caller identity'; END IF;
  v_name := 'SeedSafe-'||pg_catalog.gen_random_uuid()::text;
  v_id := erp_private.create_ingredient(v_name,'Test',v_unit);
  IF v_id IS NULL THEN RAISE EXCEPTION 'FAIL: missing test ingredient UUID'; END IF;
  PERFORM pg_catalog.set_config('erp_test2a.fixture_id',v_id::text,true);
  PERFORM pg_catalog.set_config('erp_test2a.fixture_name',v_name,true);
  SELECT * INTO STRICT v_result FROM erp_private.record_inventory_transaction(v_id,'INCOMING','12.00',DATE '2026-01-02',NULL);
  IF v_result.transaction_id IS NULL OR v_result.ledger_sequence_text IS NULL OR v_result.ledger_sequence_text !~ '^[0-9]+$' THEN
    RAISE EXCEPTION 'FAIL: invalid incoming return';
  END IF;
  v_returns := v_returns||jsonb_build_array(to_jsonb(v_result));
  SELECT * INTO STRICT v_result FROM erp_private.record_inventory_transaction(v_id,'CONSUMPTION','3',DATE '2026-01-02',NULL);
  IF v_result.transaction_id IS NULL OR v_result.ledger_sequence_text IS NULL OR v_result.ledger_sequence_text !~ '^[0-9]+$' THEN
    RAISE EXCEPTION 'FAIL: invalid consumption return';
  END IF;
  v_returns := v_returns||jsonb_build_array(to_jsonb(v_result));
  BEGIN
    PERFORM erp_private.record_inventory_transaction(v_id,'CONSUMPTION','10',DATE '2026-01-02',NULL);
    RAISE EXCEPTION 'FAIL: excessive consumption accepted';
  EXCEPTION WHEN SQLSTATE '23514' THEN
    IF SQLERRM<>'Consumption exceeds available stock' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM erp_private.deactivate_ingredient(v_id);
    RAISE EXCEPTION 'FAIL: nonzero deactivation accepted';
  EXCEPTION WHEN SQLSTATE '23514' THEN
    IF SQLERRM<>'Deactivation requires zero stock' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM erp_private.record_inventory_transaction(v_id,'INCOMING','1.001',DATE '2026-01-02',NULL);
    RAISE EXCEPTION 'FAIL: excess precision accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM<>'Quantity must be unsigned decimal text with at most two fractional digits' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM erp_private.record_inventory_transaction(v_id,'INCOMING','0',DATE '2026-01-02',NULL);
    RAISE EXCEPTION 'FAIL: zero quantity accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM<>'Quantity must be greater than zero and at most 9999999999.99' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM erp_private.record_inventory_transaction(v_id,'INCOMING','1.50',DATE '2026-01-02',NULL);
    RAISE EXCEPTION 'FAIL: fractional each quantity accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM<>'Each quantities must be whole numbers' THEN RAISE; END IF;
  END;
  SELECT * INTO STRICT v_result FROM erp_private.record_inventory_transaction(v_id,'CONSUMPTION','9',DATE '2026-01-02',NULL);
  IF v_result.transaction_id IS NULL OR v_result.ledger_sequence_text IS NULL OR v_result.ledger_sequence_text !~ '^[0-9]+$' THEN
    RAISE EXCEPTION 'FAIL: invalid final consumption return';
  END IF;
  v_returns := v_returns||jsonb_build_array(to_jsonb(v_result));
  PERFORM erp_private.deactivate_ingredient(v_id);
  BEGIN
    PERFORM erp_private.record_inventory_transaction(v_id,'INCOMING','1',DATE '2026-01-02',NULL);
    RAISE EXCEPTION 'FAIL: inactive ingredient write accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM<>'Ingredient is inactive' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM erp_private.deactivate_ingredient(v_id);
    RAISE EXCEPTION 'FAIL: repeated deactivation accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM<>'Ingredient is already inactive' THEN RAISE; END IF;
  END;
  PERFORM pg_catalog.set_config('erp_test2a.returns',v_returns::text,true);
END;
$business$;
SET LOCAL ROLE erp_table_owner;
DO $prepare_denial$
DECLARE v_next numeric;
BEGIN
  SELECT coalesce(max(ledger_sequence)::numeric,0)+1 INTO v_next FROM erp_private.inventory_transactions;
  IF v_next<1 OR v_next>9223372036854775807::numeric THEN
    RAISE EXCEPTION 'FAIL: no valid BIGINT direct-write probe candidate';
  END IF;
  PERFORM pg_catalog.set_config('erp_test2a.direct_sequence',v_next::text,true);
END;
$prepare_denial$;
SET LOCAL ROLE erp_admin_caller;
DO $direct_denial$
DECLARE v_id uuid := pg_catalog.current_setting('erp_test2a.fixture_id')::uuid;
  v_probe uuid := pg_catalog.gen_random_uuid();
  v_sequence bigint := pg_catalog.current_setting('erp_test2a.direct_sequence')::bigint;
BEGIN
  IF current_user<>'erp_admin_caller'
    OR NOT pg_catalog.has_schema_privilege(current_user,'erp_private','USAGE')
    OR pg_catalog.has_table_privilege(current_user,'erp_private.inventory_transactions','INSERT')
    OR pg_catalog.has_any_column_privilege(current_user,'erp_private.inventory_transactions','INSERT') THEN
    RAISE EXCEPTION 'FAIL: direct-write probe privilege prerequisites differ';
  END IF;
  BEGIN
    INSERT INTO erp_private.inventory_transactions
      (id,ledger_sequence,ingredient_id,supplier_id,transaction_type,quantity,transaction_date,created_at)
      VALUES (v_probe,v_sequence,v_id,NULL,'INCOMING',1.00,DATE '2026-01-02',TIMESTAMPTZ '2026-01-02 00:00:00+00');
    RAISE EXCEPTION 'FAIL: caller directly wrote ledger';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    IF SQLERRM IS DISTINCT FROM 'permission denied for table inventory_transactions' THEN RAISE; END IF;
  END;
END;
$direct_denial$;
SET LOCAL ROLE erp_table_owner;
DO $preservation$
DECLARE v_id uuid := pg_catalog.current_setting('erp_test2a.fixture_id')::uuid;
  v_snapshot jsonb; v_actual jsonb; v_returned jsonb := pg_catalog.current_setting('erp_test2a.returns')::jsonb;
BEGIN
  SELECT jsonb_build_object(
    'units',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM erp_private.units t),
    'suppliers',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM erp_private.suppliers t),
    'ingredients',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM erp_private.ingredients t WHERE id<>v_id),
    'ledger',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM erp_private.inventory_transactions t WHERE ingredient_id<>v_id)) INTO v_snapshot;
  IF v_snapshot IS DISTINCT FROM pg_catalog.current_setting('erp_test2a.seed_rows')::jsonb THEN
    RAISE EXCEPTION 'FAIL: original seed rows, IDs or ledger changed';
  END IF;
  IF (SELECT count(*) FROM erp_private.ingredients)<>7
    OR (SELECT count(*) FROM erp_private.inventory_transactions)<>9
    OR NOT EXISTS (SELECT FROM erp_private.ingredients WHERE id=v_id
      AND name=pg_catalog.current_setting('erp_test2a.fixture_name') AND category='Test'
      AND unit_id='10000000-0000-4000-8000-000000000004'::uuid
      AND NOT is_active AND deactivated_at IS NOT NULL)
    OR (SELECT sum(CASE transaction_type WHEN 'INCOMING' THEN quantity ELSE -quantity END)
      FROM erp_private.inventory_transactions WHERE ingredient_id=v_id) IS DISTINCT FROM 0::numeric THEN
    RAISE EXCEPTION 'FAIL: unexpected fixture state or balance';
  END IF;
  SELECT jsonb_agg(jsonb_build_array(transaction_type,quantity,transaction_date,supplier_id) ORDER BY ledger_sequence)
    INTO v_actual FROM erp_private.inventory_transactions WHERE ingredient_id=v_id;
  IF v_actual IS DISTINCT FROM '[["INCOMING",12,"2026-01-02",null],["CONSUMPTION",3,"2026-01-02",null],["CONSUMPTION",9,"2026-01-02",null]]'::jsonb THEN
    RAISE EXCEPTION 'FAIL: fixture ledger differs from controlled writes';
  END IF;
  IF jsonb_array_length(v_returned)<>3
    OR (SELECT count(DISTINCT x->>'transaction_id') FROM jsonb_array_elements(v_returned) x)<>3
    OR EXISTS (SELECT FROM jsonb_array_elements(v_returned) x
      LEFT JOIN erp_private.inventory_transactions t ON t.id=(x->>'transaction_id')::uuid
      WHERE t.id IS NULL OR t.ingredient_id<>v_id OR t.ledger_sequence::text IS DISTINCT FROM x->>'ledger_sequence_text') THEN
    RAISE EXCEPTION 'FAIL: function returns do not match fixture ledger';
  END IF;
END;
$preservation$;
SET LOCAL ROLE erp_view_owner;
DO $view_preservation$
DECLARE v_name text := pg_catalog.current_setting('erp_test2a.fixture_name'); v_snapshot jsonb;
BEGIN
  SELECT jsonb_build_object(
    'balances',(SELECT jsonb_agg(to_jsonb(t) ORDER BY ingredient_id) FROM erp_api.inventory_balances t),
    'history',(SELECT jsonb_agg(to_jsonb(t) ORDER BY ledger_sequence) FROM erp_api.inventory_history t WHERE ingredient_name<>v_name)) INTO v_snapshot;
  IF v_snapshot IS DISTINCT FROM pg_catalog.current_setting('erp_test2a.seed_views')::jsonb
    OR (SELECT count(*) FROM erp_api.inventory_history WHERE ingredient_name=v_name)<>3 THEN
    RAISE EXCEPTION 'FAIL: seed balance/history changed or fixture history missing';
  END IF;
  RAISE NOTICE 'Test 2A assertions passed before rollback; post-rollback verification still required. Fixture: %',v_name;
END;
$view_preservation$;
ROLLBACK;
-- REQUIRED OPERATOR CHECK: in a separate, explicitly read-only request after this
-- batch, compare seed IDs/full rows through the trusted table-owner read path and
-- both complete API views through view owner with the captured original notices.
-- Require six original ingredients and six original INCOMING ledger/history rows,
-- the six stated balances, unchanged units/supplier, and no recorded fixture UUID/name.
-- Do not require unchanged sequence state or contiguous ledger numbers.
-- If notices were not retained, or outcome/rollback is ambiguous, do not claim PASS:
-- inspect actual state with the approved operator before any retry. Never rerun for cleanup.

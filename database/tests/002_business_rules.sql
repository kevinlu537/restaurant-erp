-- PREPARED ONLY: I3b single-session acceptance after M1-M3, before later stages.
-- Separate execution approval required. PostgreSQL runtime: NOT TESTED.
-- Isolated, quiescent development target; stop-on-error coordinator must have
-- independently verified SET ROLE authority. Never grant privileges for tests.
-- Run the complete file, not selected success statements. On unexpected error:
-- stop, explicitly ROLLBACK in the approved client, and inspect baseline.
-- No cleanup deletion/reset. Sequence allocations can survive every rollback.
BEGIN ISOLATION LEVEL READ COMMITTED;
-- Exact P5-I1 administrator exception; no inferred platform grantor.
DO $business_memberships$
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
$business_memberships$;
SET LOCAL ROLE erp_table_owner;
SET LOCAL search_path = pg_catalog, pg_temp;
LOCK TABLE erp_private.units, erp_private.ingredients, erp_private.suppliers,
  erp_private.inventory_transactions IN SHARE ROW EXCLUSIVE MODE;
DO $preflight$
DECLARE v_role text; v_function regprocedure; v_table text;
BEGIN
  IF current_user <> 'erp_table_owner' OR current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'FAIL: wrong preflight identity/isolation';
  END IF;
  IF (SELECT count(*) FROM pg_catalog.pg_class WHERE relnamespace='erp_private'::regnamespace AND relkind='r') <> 4
    OR (SELECT count(*) FROM pg_catalog.pg_proc WHERE pronamespace='erp_private'::regnamespace) <> 6
    OR EXISTS (SELECT FROM pg_catalog.pg_class WHERE relnamespace='erp_api'::regnamespace)
    OR EXISTS (SELECT FROM pg_catalog.pg_proc WHERE pronamespace='erp_api'::regnamespace) THEN
    RAISE EXCEPTION 'FAIL: unexpected stage objects; require private M1-M3 and empty API schema';
  END IF;
  IF EXISTS (SELECT FROM erp_private.units) OR EXISTS (SELECT FROM erp_private.ingredients)
    OR EXISTS (SELECT FROM erp_private.suppliers) OR EXISTS (SELECT FROM erp_private.inventory_transactions) THEN
    RAISE EXCEPTION 'FAIL: all four business tables must start empty; never clear existing data';
  END IF;
  IF EXISTS (SELECT FROM pg_catalog.pg_class WHERE relnamespace='erp_private'::regnamespace
    AND relkind IN ('r','p','v','m','S','f') AND relname NOT IN
      ('units','ingredients','suppliers','inventory_transactions','erp_ledger_sequence'))
    OR (SELECT count(*) FROM pg_catalog.pg_class WHERE relnamespace='erp_private'::regnamespace AND relkind='S')<>1
    OR EXISTS (SELECT FROM pg_catalog.pg_proc WHERE pronamespace='erp_private'::regnamespace
      AND proname NOT IN ('create_ingredient','record_inventory_transaction','deactivate_ingredient',
        'guard_ingredient_unit','guard_unit_definition','guard_ledger_mutation')) THEN
    RAISE EXCEPTION 'FAIL: unexpected private objects; investigate stage drift';
  END IF;
  IF EXISTS (SELECT FROM pg_catalog.pg_class WHERE relnamespace='erp_private'::regnamespace AND relkind='r'
    AND (relowner <> 'erp_table_owner'::regrole OR NOT relrowsecurity OR NOT relforcerowsecurity)) THEN
    RAISE EXCEPTION 'FAIL: private ownership or forced RLS';
  END IF;
  FOREACH v_role IN ARRAY ARRAY['erp_table_owner','erp_view_owner','erp_function_owner','erp_admin_caller'] LOOP
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname=v_role AND NOT rolsuper AND NOT rolbypassrls
      AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolreplication AND NOT rolinherit
      AND rolcanlogin=(v_role='erp_admin_caller')) THEN RAISE EXCEPTION 'FAIL: role attributes %',v_role; END IF;
  END LOOP;
  FOREACH v_function IN ARRAY ARRAY[
    'erp_private.create_ingredient(text,text,uuid)'::regprocedure,
    'erp_private.record_inventory_transaction(uuid,text,text,date,uuid)'::regprocedure,
    'erp_private.deactivate_ingredient(uuid)'::regprocedure] LOOP
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_proc WHERE oid=v_function AND proowner='erp_function_owner'::regrole
      AND prosecdef AND provolatile='v' AND 'search_path=pg_catalog, pg_temp'=ANY(proconfig))
      OR NOT pg_catalog.has_function_privilege('erp_admin_caller',v_function,'EXECUTE')
      OR pg_catalog.has_function_privilege('anon',v_function,'EXECUTE')
      OR pg_catalog.has_function_privilege('authenticated',v_function,'EXECUTE') THEN
      RAISE EXCEPTION 'FAIL: business function security %',v_function;
    END IF;
  END LOOP;
  IF EXISTS (SELECT FROM pg_catalog.pg_proc WHERE pronamespace='erp_private'::regnamespace
    AND proname LIKE 'guard_%' AND pg_catalog.has_function_privilege('erp_admin_caller',oid,'EXECUTE')) THEN
    RAISE EXCEPTION 'FAIL: caller can execute trigger helper';
  END IF;
  FOREACH v_table IN ARRAY ARRAY['units','ingredients','suppliers','inventory_transactions'] LOOP
    FOREACH v_role IN ARRAY ARRAY['erp_admin_caller','anon','authenticated'] LOOP
      IF pg_catalog.has_table_privilege(v_role,'erp_private.'||v_table,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
        OR pg_catalog.has_any_column_privilege(v_role,'erp_private.'||v_table,'SELECT,INSERT,UPDATE,REFERENCES') THEN
        RAISE EXCEPTION 'FAIL: direct table/column access % %',v_role,v_table;
      END IF;
    END LOOP;
  END LOOP;
  IF pg_catalog.has_sequence_privilege('erp_admin_caller','erp_private.erp_ledger_sequence','USAGE,SELECT,UPDATE') THEN
    RAISE EXCEPTION 'FAIL: caller sequence privileges';
  END IF;
END;
$preflight$;
-- Owner-only reference setup. No business ingredient or ledger bypass.
INSERT INTO erp_private.units(id,code,name,unit_type) VALUES
  ('83000000-0000-4000-8000-000000000001','lb','Pound','WEIGHT'),
  ('83000000-0000-4000-8000-000000000002','each','Each','COUNT');
INSERT INTO erp_private.suppliers(id,name,is_active) VALUES
  ('83000000-0000-4000-8000-000000000011','P3B Fictional Active Supply',true),
  ('83000000-0000-4000-8000-000000000012','P3B Fictional Inactive Supply',false);

SET LOCAL ROLE erp_admin_caller;
DO $business$
DECLARE v_stock uuid; v_count uuid; v_zero uuid; v_precision uuid;
  v_trial uuid; v_text text; v_result record; v_previous bigint;
BEGIN
  IF current_user <> 'erp_admin_caller' THEN RAISE EXCEPTION 'FAIL: wrong business identity'; END IF;
  v_stock := erp_private.create_ingredient(E' \tP3B Stock\r\n','Test','83000000-0000-4000-8000-000000000001');
  v_count := erp_private.create_ingredient('P3B Count','Test','83000000-0000-4000-8000-000000000002');
  v_zero := erp_private.create_ingredient('P3B Zero','Test','83000000-0000-4000-8000-000000000001');
  v_precision := erp_private.create_ingredient('P3B Precision','Test','83000000-0000-4000-8000-000000000001');
  PERFORM erp_private.create_ingredient(U&'P3B \00C9pice','Test','83000000-0000-4000-8000-000000000001');
  IF v_stock IS NULL OR v_count IS NULL OR v_zero IS NULL OR v_precision IS NULL THEN
    RAISE EXCEPTION 'FAIL: missing ingredient UUID';
  END IF;
  -- Transaction-local evidence crosses top-level role blocks without objects.
  PERFORM pg_catalog.set_config('erp_test.return_evidence','[]',true);
  -- No handler encloses strict cardinality/value assertions.
  FOREACH v_text IN ARRAY ARRAY['12.50','0.50'] LOOP
    SELECT * INTO STRICT v_result FROM erp_private.record_inventory_transaction(v_stock,'INCOMING',v_text,
      DATE '2026-01-01',CASE WHEN v_text='12.50' THEN '83000000-0000-4000-8000-000000000011'::uuid ELSE NULL END);
    IF v_result.transaction_id IS NULL OR v_result.ledger_sequence_text IS NULL OR v_result.ledger_sequence_text !~ '^[0-9]+$' THEN
      RAISE EXCEPTION 'FAIL: missing precision-safe return';
    END IF;
    IF v_previous IS NOT NULL AND v_result.ledger_sequence_text::bigint <= v_previous THEN
      RAISE EXCEPTION 'FAIL: sequence did not increase';
    END IF;
    v_previous := v_result.ledger_sequence_text::bigint;
  PERFORM pg_catalog.set_config('erp_test.return_evidence',
    ((pg_catalog.current_setting('erp_test.return_evidence')::jsonb) ||
      jsonb_build_array(jsonb_build_object('id',v_result.transaction_id,'sequence',v_result.ledger_sequence_text,'ingredient',v_stock)))::text,true);

  END LOOP;
  SELECT * INTO STRICT v_result FROM erp_private.record_inventory_transaction(v_stock,'CONSUMPTION','3.00',DATE '2026-01-01');
  IF v_result.transaction_id IS NULL OR v_result.ledger_sequence_text IS NULL OR v_result.ledger_sequence_text !~ '^[0-9]+$' THEN
    RAISE EXCEPTION 'FAIL: missing precision-safe return';
  END IF;
  PERFORM pg_catalog.set_config('erp_test.return_evidence',
    ((pg_catalog.current_setting('erp_test.return_evidence')::jsonb) ||
      jsonb_build_array(jsonb_build_object('id',v_result.transaction_id,'sequence',v_result.ledger_sequence_text,'ingredient',v_stock)))::text,true);
  BEGIN
    PERFORM erp_private.record_inventory_transaction(v_stock,'CONSUMPTION','10.01',DATE '2026-01-01');
    RAISE EXCEPTION 'FAIL: expected rejection: Consumption exceeds available stock';
  EXCEPTION WHEN SQLSTATE '23514' THEN
    IF SQLERRM <> 'Consumption exceeds available stock' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM erp_private.deactivate_ingredient(v_stock);
    RAISE EXCEPTION 'FAIL: expected rejection: Deactivation requires zero stock';
  EXCEPTION WHEN SQLSTATE '23514' THEN
    IF SQLERRM <> 'Deactivation requires zero stock' THEN RAISE; END IF;
  END;
  SELECT * INTO STRICT v_result FROM erp_private.record_inventory_transaction(v_stock,'CONSUMPTION','10.00',DATE '2025-12-31');
  IF v_result.transaction_id IS NULL OR v_result.ledger_sequence_text IS NULL OR v_result.ledger_sequence_text !~ '^[0-9]+$' THEN
    RAISE EXCEPTION 'FAIL: missing precision-safe return';
  END IF;
  PERFORM pg_catalog.set_config('erp_test.return_evidence',
    ((pg_catalog.current_setting('erp_test.return_evidence')::jsonb) ||
      jsonb_build_array(jsonb_build_object('id',v_result.transaction_id,'sequence',v_result.ledger_sequence_text,'ingredient',v_stock)))::text,true);
  PERFORM erp_private.deactivate_ingredient(v_stock);
  PERFORM erp_private.deactivate_ingredient(v_zero);
  SELECT * INTO STRICT v_result FROM erp_private.record_inventory_transaction(v_count,'INCOMING','12.00',DATE '2026-01-01');
  IF v_result.transaction_id IS NULL OR v_result.ledger_sequence_text IS NULL OR v_result.ledger_sequence_text !~ '^[0-9]+$' THEN
    RAISE EXCEPTION 'FAIL: missing precision-safe return';
  END IF;
  PERFORM pg_catalog.set_config('erp_test.return_evidence',
    ((pg_catalog.current_setting('erp_test.return_evidence')::jsonb) ||
      jsonb_build_array(jsonb_build_object('id',v_result.transaction_id,'sequence',v_result.ledger_sequence_text,'ingredient',v_count)))::text,true);
  SELECT * INTO STRICT v_result FROM erp_private.record_inventory_transaction(v_count,'CONSUMPTION','12',DATE '2026-01-01');
  IF v_result.transaction_id IS NULL OR v_result.ledger_sequence_text IS NULL OR v_result.ledger_sequence_text !~ '^[0-9]+$' THEN
    RAISE EXCEPTION 'FAIL: missing precision-safe return';
  END IF;
  PERFORM pg_catalog.set_config('erp_test.return_evidence',
    ((pg_catalog.current_setting('erp_test.return_evidence')::jsonb) ||
      jsonb_build_array(jsonb_build_object('id',v_result.transaction_id,'sequence',v_result.ledger_sequence_text,'ingredient',v_count)))::text,true);
  FOREACH v_text IN ARRAY ARRAY['12','12.5','12.50','9999999999.99'] LOOP
    SELECT * INTO STRICT v_result FROM erp_private.record_inventory_transaction(v_precision,'INCOMING',v_text,DATE '2026-01-01');
    IF v_result.transaction_id IS NULL OR v_result.ledger_sequence_text IS NULL OR v_result.ledger_sequence_text !~ '^[0-9]+$' THEN
      RAISE EXCEPTION 'FAIL: missing precision-safe return';
    END IF;
  PERFORM pg_catalog.set_config('erp_test.return_evidence',
    ((pg_catalog.current_setting('erp_test.return_evidence')::jsonb) ||
      jsonb_build_array(jsonb_build_object('id',v_result.transaction_id,'sequence',v_result.ledger_sequence_text,'ingredient',v_precision)))::text,true);
  END LOOP;
  FOREACH v_text IN ARRAY ARRAY['12.500','12.555','0','0.00','-5','+5','1e3','NaN','Infinity',
    '10000000000','10000000000.00','12.',' .5','12 ', '12'||E'\n','',NULL] LOOP
    BEGIN
      PERFORM erp_private.record_inventory_transaction(v_precision,'INCOMING',v_text,DATE '2026-01-01');
      RAISE EXCEPTION 'FAIL: invalid quantity accepted';
    EXCEPTION WHEN invalid_parameter_value THEN
      IF SQLERRM NOT IN ('Quantity must be unsigned decimal text with at most two fractional digits',
        'Quantity exceeds 9999999999.99','Quantity must be greater than zero and at most 9999999999.99') THEN RAISE; END IF;
    END;
  END LOOP;
  BEGIN
    PERFORM erp_private.record_inventory_transaction(v_count,'INCOMING','12.50',DATE '2026-01-01');
    RAISE EXCEPTION 'FAIL: expected rejection: Each quantities must be whole numbers';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'Each quantities must be whole numbers' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM erp_private.record_inventory_transaction(v_precision,'INCOMING','1',DATE '2026-01-01','83000000-0000-4000-8000-000000000012');
    RAISE EXCEPTION 'FAIL: expected rejection: Supplier is unknown or inactive';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'Supplier is unknown or inactive' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM erp_private.record_inventory_transaction(v_precision,'INCOMING','1',DATE '2026-01-01','83000000-0000-4000-8000-000000000092');
    RAISE EXCEPTION 'FAIL: expected rejection: Supplier is unknown or inactive';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'Supplier is unknown or inactive' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM erp_private.record_inventory_transaction(v_count,'CONSUMPTION','1',DATE '2026-01-01','83000000-0000-4000-8000-000000000011');
    RAISE EXCEPTION 'FAIL: expected rejection: Consumption cannot have a supplier';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'Consumption cannot have a supplier' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM erp_private.record_inventory_transaction(v_stock,'INCOMING','1',DATE '2026-01-01');
    RAISE EXCEPTION 'FAIL: expected rejection: Ingredient is inactive';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'Ingredient is inactive' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM erp_private.deactivate_ingredient(v_zero);
    RAISE EXCEPTION 'FAIL: expected rejection: Ingredient is already inactive';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'Ingredient is already inactive' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM erp_private.record_inventory_transaction(v_precision,'ADJUSTMENT','1',DATE '2026-01-01');
    RAISE EXCEPTION 'FAIL: expected rejection: Invalid transaction type';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'Invalid transaction type' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM erp_private.record_inventory_transaction(v_precision,'INCOMING','1',NULL);
    RAISE EXCEPTION 'FAIL: expected rejection: Ingredient, transaction type and finite business date are required';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'Ingredient, transaction type and finite business date are required' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM erp_private.record_inventory_transaction(v_precision,'INCOMING','1','infinity'::date);
    RAISE EXCEPTION 'FAIL: expected rejection: Ingredient, transaction type and finite business date are required';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'Ingredient, transaction type and finite business date are required' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM erp_private.record_inventory_transaction(v_precision,'INCOMING','1','-infinity'::date);
    RAISE EXCEPTION 'FAIL: expected rejection: Ingredient, transaction type and finite business date are required';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'Ingredient, transaction type and finite business date are required' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM erp_private.record_inventory_transaction(NULL,'INCOMING','1',DATE '2026-01-01');
    RAISE EXCEPTION 'FAIL: expected rejection: Ingredient, transaction type and finite business date are required';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'Ingredient, transaction type and finite business date are required' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM erp_private.record_inventory_transaction('83000000-0000-4000-8000-000000000091','INCOMING','1',DATE '2026-01-01');
    RAISE EXCEPTION 'FAIL: expected rejection: Unknown ingredient';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'Unknown ingredient' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM erp_private.create_ingredient('P3B Missing Unit','Test','83000000-0000-4000-8000-000000000091');
    RAISE EXCEPTION 'FAIL: expected rejection: Unknown unit';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'Unknown unit' THEN RAISE; END IF;
  END;
  -- Valid category/unit isolate NULL-name validation; expected error rolls back this block.
  BEGIN
    PERFORM erp_private.create_ingredient(NULL,'Test','83000000-0000-4000-8000-000000000001');
    RAISE EXCEPTION 'FAIL: NULL ingredient name accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'Name, category and unit are required' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM erp_private.create_ingredient(E' \t\n\r','Test','83000000-0000-4000-8000-000000000001');
    RAISE EXCEPTION 'FAIL: expected rejection: Name, category and unit are required';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'Name, category and unit are required' THEN RAISE; END IF;
  END;
  -- Active/inactive names remain reserved; assert the intended index provenance.
  BEGIN
    PERFORM erp_private.create_ingredient('p3b stock','Test','83000000-0000-4000-8000-000000000001');
    RAISE EXCEPTION 'FAIL: inactive normalized name reused';
  EXCEPTION WHEN unique_violation THEN
    DECLARE v_constraint text;
    BEGIN
      GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
      IF v_constraint <> 'ingredients_normalized_name_key' THEN RAISE; END IF;
    END;
  END;
  BEGIN
    PERFORM erp_private.create_ingredient(U&'P3B \00C9PICE','Test','83000000-0000-4000-8000-000000000001');
    RAISE EXCEPTION 'FAIL: ASCII case comparison within non-ASCII name';
  EXCEPTION WHEN unique_violation THEN
    DECLARE v_constraint text;
    BEGIN
      GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
      IF v_constraint <> 'ingredients_normalized_name_key' THEN RAISE; END IF;
    END;
  END;
  -- Deliberate subtransaction rollback, not a catch-all for function errors.
  BEGIN
    v_trial := erp_private.create_ingredient('P3B Rolled Back','Test','83000000-0000-4000-8000-000000000001');
    PERFORM erp_private.record_inventory_transaction(v_trial,'INCOMING','0.01',DATE '2026-01-01');
    PERFORM erp_private.record_inventory_transaction(v_trial,'INCOMING','00000.01',DATE '2026-01-01');
    RAISE EXCEPTION 'P3B deliberate rollback' USING ERRCODE='ZP301';
  EXCEPTION WHEN SQLSTATE 'ZP301' THEN
    IF SQLERRM <> 'P3B deliberate rollback' THEN RAISE; END IF;
  END;
END;
$business$;
-- I3d: prepare one valid direct INSERT target and initialize independent evidence.
-- Existing table locks and the quiescent-target prerequisite protect the candidate.
SET LOCAL ROLE erp_table_owner;
DO $ledger_insert_precheck$
DECLARE v_ingredient erp_private.ingredients%ROWTYPE; v_candidate numeric;
  v_balance numeric; v_ingredients jsonb; v_ledger jsonb;
BEGIN
  IF current_user<>'erp_table_owner' THEN RAISE EXCEPTION 'FAIL: wrong INSERT precheck identity'; END IF;
  PERFORM pg_catalog.set_config('erp_test.ledger_insert_probe','',true);
  SELECT i.* INTO STRICT v_ingredient FROM erp_private.ingredients i WHERE i.name='P3B Precision';
  IF NOT v_ingredient.is_active OR v_ingredient.category IS DISTINCT FROM 'Test'
    OR v_ingredient.unit_id IS DISTINCT FROM '83000000-0000-4000-8000-000000000001'::uuid
    OR NOT EXISTS (SELECT FROM erp_private.units WHERE id=v_ingredient.unit_id
      AND code='lb' AND name='Pound' AND unit_type='WEIGHT') THEN
    RAISE EXCEPTION 'FAIL: invalid active ingredient/unit for ledger INSERT probe';
  END IF;
  IF EXISTS (SELECT FROM erp_private.inventory_transactions WHERE id='83000000-0000-4000-8000-000000000093') THEN
    RAISE EXCEPTION 'FAIL: ledger INSERT probe UUID already exists';
  END IF;
  SELECT COALESCE(MAX(ledger_sequence)::numeric,0)+1 INTO v_candidate FROM erp_private.inventory_transactions;
  IF v_candidate<1 OR v_candidate>9223372036854775807::numeric THEN
    RAISE EXCEPTION 'FAIL: no positive BIGINT ledger INSERT candidate';
  END IF;
  IF EXISTS (SELECT FROM erp_private.inventory_transactions WHERE ledger_sequence=v_candidate::bigint) THEN
    RAISE EXCEPTION 'FAIL: ledger INSERT candidate already used';
  END IF;
  SELECT COALESCE(SUM(CASE transaction_type WHEN 'INCOMING' THEN quantity ELSE -quantity END),0)
    INTO v_balance FROM erp_private.inventory_transactions WHERE ingredient_id=v_ingredient.id;
  IF v_balance IS DISTINCT FROM 10000000036.99::numeric THEN RAISE EXCEPTION 'FAIL: unexpected probe balance'; END IF;
  SELECT COALESCE(jsonb_agg(to_jsonb(i) ORDER BY i.id),'[]'::jsonb) INTO v_ingredients FROM erp_private.ingredients i;
  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb) INTO v_ledger FROM erp_private.inventory_transactions t;
  PERFORM pg_catalog.set_config('erp_test.ledger_insert_probe',jsonb_build_object(
    'ingredient_id',v_ingredient.id::text,'probe_id','83000000-0000-4000-8000-000000000093',
    'sequence',v_candidate::bigint::text,'balance',v_balance::text,
    'ingredients',v_ingredients,'ledger',v_ledger)::text,true);
END;
$ledger_insert_precheck$;
-- Every context switch is top-level, outside functions/exception subtransactions.
-- Catalog privilege checks above establish denial prerequisites; these are probes.
SET LOCAL ROLE erp_admin_caller;
DO $caller_denials$
DECLARE v_raw text; v_evidence jsonb; v_ingredient_id uuid; v_probe_id uuid;
  v_sequence bigint; v_balance numeric;
BEGIN
  BEGIN
    UPDATE erp_private.ingredients SET is_active=false WHERE name='P3B Precision';
    RAISE EXCEPTION 'FAIL: caller bypass accepted';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Expected caller denial: %',SQLERRM;
  END;
  BEGIN
    UPDATE erp_private.suppliers SET is_active=false WHERE id='83000000-0000-4000-8000-000000000011';
    RAISE EXCEPTION 'FAIL: caller bypass accepted';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Expected caller denial: %',SQLERRM;
  END;
  BEGIN
    UPDATE erp_private.inventory_transactions SET quantity=1 WHERE ingredient_id=(pg_catalog.current_setting('erp_test.return_evidence')::jsonb->0->>'ingredient')::uuid;
    RAISE EXCEPTION 'FAIL: caller bypass accepted';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Expected caller denial: %',SQLERRM;
  END;
  BEGIN
    DELETE FROM erp_private.inventory_transactions WHERE ingredient_id=(pg_catalog.current_setting('erp_test.return_evidence')::jsonb->0->>'ingredient')::uuid;
    RAISE EXCEPTION 'FAIL: caller bypass accepted';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Expected caller denial: %',SQLERRM;
  END;
  BEGIN
    TRUNCATE erp_private.inventory_transactions;
    RAISE EXCEPTION 'FAIL: caller bypass accepted';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Expected caller denial: %',SQLERRM;
  END;
  BEGIN
    INSERT INTO erp_private.ingredients(name,category,unit_id) VALUES ('P3B Direct','Test','83000000-0000-4000-8000-000000000001');
    RAISE EXCEPTION 'FAIL: caller bypass accepted';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Expected caller denial: %',SQLERRM;
  END;
  -- Required lookup/parsing occurs outside the INSERT exception handler.
  v_raw := pg_catalog.current_setting('erp_test.ledger_insert_probe');
  IF v_raw IS NULL OR pg_catalog.btrim(v_raw)='' THEN
    RAISE EXCEPTION 'FAIL: missing ledger INSERT precheck evidence';
  END IF;
  v_evidence := v_raw::jsonb;
  IF jsonb_typeof(v_evidence) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'FAIL: ledger INSERT evidence must be an object';
  END IF;
  IF NOT (v_evidence ?& ARRAY['ingredient_id','probe_id','sequence','balance','ingredients','ledger'])
    OR jsonb_typeof(v_evidence->'ingredient_id') IS DISTINCT FROM 'string'
    OR jsonb_typeof(v_evidence->'probe_id') IS DISTINCT FROM 'string'
    OR jsonb_typeof(v_evidence->'sequence') IS DISTINCT FROM 'string'
    OR jsonb_typeof(v_evidence->'balance') IS DISTINCT FROM 'string'
    OR jsonb_typeof(v_evidence->'ingredients') IS DISTINCT FROM 'array'
    OR jsonb_typeof(v_evidence->'ledger') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'FAIL: missing, NULL or malformed ledger INSERT evidence fields';
  END IF;
  IF (v_evidence->>'sequence') !~ '^[0-9]+$'
    OR (v_evidence->>'balance') !~ '^[0-9]+([.][0-9]+)?$' THEN
    RAISE EXCEPTION 'FAIL: invalid ledger INSERT evidence numbers';
  END IF;
  v_ingredient_id := (v_evidence->>'ingredient_id')::uuid;
  v_probe_id := (v_evidence->>'probe_id')::uuid;
  v_sequence := (v_evidence->>'sequence')::bigint;
  v_balance := (v_evidence->>'balance')::numeric;
  IF v_sequence<=0 OR v_probe_id<>'83000000-0000-4000-8000-000000000093'::uuid
    OR v_balance IS DISTINCT FROM 10000000036.99::numeric
    OR jsonb_array_length(v_evidence->'ingredients')<>5
    OR jsonb_array_length(v_evidence->'ledger')<>10 THEN
    RAISE EXCEPTION 'FAIL: inconsistent ledger INSERT evidence';
  END IF;
  IF EXISTS (SELECT FROM jsonb_array_elements(v_evidence->'ingredients') x
      WHERE jsonb_typeof(x) IS DISTINCT FROM 'object')
    OR EXISTS (SELECT FROM jsonb_array_elements(v_evidence->'ledger') x
      WHERE jsonb_typeof(x) IS DISTINCT FROM 'object'
        OR NOT (x ?& ARRAY['id','ledger_sequence','ingredient_id','supplier_id',
          'transaction_type','quantity','transaction_date','created_at'])) THEN
    RAISE EXCEPTION 'FAIL: malformed ledger INSERT snapshot rows';
  END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(v_evidence->'ingredients') x
    WHERE x->>'id'=v_ingredient_id::text AND x->>'name'='P3B Precision'
      AND x->>'category'='Test' AND x->>'is_active'='true'
      AND x->>'unit_id'='83000000-0000-4000-8000-000000000001')<>1
    OR EXISTS (SELECT FROM jsonb_array_elements(v_evidence->'ledger') x
      WHERE x->>'id'=v_probe_id::text OR (x->>'ledger_sequence')::bigint=v_sequence)
    OR (SELECT COALESCE(MAX((x->>'ledger_sequence')::numeric),0)+1
      FROM jsonb_array_elements(v_evidence->'ledger') x) IS DISTINCT FROM v_sequence::numeric
    OR (SELECT COALESCE(SUM(CASE x->>'transaction_type' WHEN 'INCOMING'
      THEN (x->>'quantity')::numeric ELSE -(x->>'quantity')::numeric END),0)
      FROM jsonb_array_elements(v_evidence->'ledger') x
      WHERE x->>'ingredient_id'=v_ingredient_id::text) IS DISTINCT FROM v_balance THEN
    RAISE EXCEPTION 'FAIL: inconsistent ledger INSERT target, balance or sequence snapshot';
  END IF;
  IF current_user<>'erp_admin_caller'
    OR NOT pg_catalog.has_schema_privilege(current_user,'erp_private','USAGE')
    OR pg_catalog.has_table_privilege(current_user,'erp_private.inventory_transactions','INSERT')
    OR pg_catalog.has_any_column_privilege(current_user,'erp_private.inventory_transactions','INSERT') THEN
    RAISE EXCEPTION 'FAIL: incorrect direct ledger INSERT authorization prerequisites';
  END IF;
  -- Exactly one INSERT; all values prepared before this handler. No defaults,
  -- private-table reads, RETURNING or sequence calls can mask table-ACL denial.
  -- Actual PostgreSQL English diagnostic and runtime behavior: NOT TESTED.
  BEGIN
    INSERT INTO erp_private.inventory_transactions
      (id,ledger_sequence,ingredient_id,supplier_id,transaction_type,quantity,transaction_date,created_at)
      VALUES (v_probe_id,v_sequence,v_ingredient_id,NULL,'INCOMING',1.00,
        DATE '2026-01-01',TIMESTAMPTZ '2026-01-01 00:00:00+00');
    RAISE EXCEPTION 'FAIL: caller directly inserted ledger';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    IF SQLERRM IS DISTINCT FROM 'permission denied for table inventory_transactions' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM pg_catalog.nextval('erp_private.erp_ledger_sequence'::regclass);
    RAISE EXCEPTION 'FAIL: caller bypass accepted';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Expected caller denial: %',SQLERRM;
  END;
END;
$caller_denials$;
SET LOCAL ROLE erp_table_owner;
DO $verify$
DECLARE v_rows jsonb; v_stock uuid; v_constraint text;
  v_raw text; v_evidence jsonb; v_ingredient_id uuid; v_probe_id uuid; v_sequence bigint; v_balance numeric;
BEGIN
  IF current_user <> 'erp_table_owner' THEN RAISE EXCEPTION 'FAIL: wrong verifier identity'; END IF;
  -- Required lookup/parsing occurs outside the INSERT exception handler.
  v_raw := pg_catalog.current_setting('erp_test.ledger_insert_probe');
  IF v_raw IS NULL OR pg_catalog.btrim(v_raw)='' THEN
    RAISE EXCEPTION 'FAIL: missing ledger INSERT precheck evidence';
  END IF;
  v_evidence := v_raw::jsonb;
  IF jsonb_typeof(v_evidence) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'FAIL: ledger INSERT evidence must be an object';
  END IF;
  IF NOT (v_evidence ?& ARRAY['ingredient_id','probe_id','sequence','balance','ingredients','ledger'])
    OR jsonb_typeof(v_evidence->'ingredient_id') IS DISTINCT FROM 'string'
    OR jsonb_typeof(v_evidence->'probe_id') IS DISTINCT FROM 'string'
    OR jsonb_typeof(v_evidence->'sequence') IS DISTINCT FROM 'string'
    OR jsonb_typeof(v_evidence->'balance') IS DISTINCT FROM 'string'
    OR jsonb_typeof(v_evidence->'ingredients') IS DISTINCT FROM 'array'
    OR jsonb_typeof(v_evidence->'ledger') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'FAIL: missing, NULL or malformed ledger INSERT evidence fields';
  END IF;
  IF (v_evidence->>'sequence') !~ '^[0-9]+$'
    OR (v_evidence->>'balance') !~ '^[0-9]+([.][0-9]+)?$' THEN
    RAISE EXCEPTION 'FAIL: invalid ledger INSERT evidence numbers';
  END IF;
  v_ingredient_id := (v_evidence->>'ingredient_id')::uuid;
  v_probe_id := (v_evidence->>'probe_id')::uuid;
  v_sequence := (v_evidence->>'sequence')::bigint;
  v_balance := (v_evidence->>'balance')::numeric;
  IF v_sequence<=0 OR v_probe_id<>'83000000-0000-4000-8000-000000000093'::uuid
    OR v_balance IS DISTINCT FROM 10000000036.99::numeric
    OR jsonb_array_length(v_evidence->'ingredients')<>5
    OR jsonb_array_length(v_evidence->'ledger')<>10 THEN
    RAISE EXCEPTION 'FAIL: inconsistent ledger INSERT evidence';
  END IF;
  IF EXISTS (SELECT FROM jsonb_array_elements(v_evidence->'ingredients') x
      WHERE jsonb_typeof(x) IS DISTINCT FROM 'object')
    OR EXISTS (SELECT FROM jsonb_array_elements(v_evidence->'ledger') x
      WHERE jsonb_typeof(x) IS DISTINCT FROM 'object'
        OR NOT (x ?& ARRAY['id','ledger_sequence','ingredient_id','supplier_id',
          'transaction_type','quantity','transaction_date','created_at'])) THEN
    RAISE EXCEPTION 'FAIL: malformed ledger INSERT snapshot rows';
  END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(v_evidence->'ingredients') x
    WHERE x->>'id'=v_ingredient_id::text AND x->>'name'='P3B Precision'
      AND x->>'category'='Test' AND x->>'is_active'='true'
      AND x->>'unit_id'='83000000-0000-4000-8000-000000000001')<>1
    OR EXISTS (SELECT FROM jsonb_array_elements(v_evidence->'ledger') x
      WHERE x->>'id'=v_probe_id::text OR (x->>'ledger_sequence')::bigint=v_sequence)
    OR (SELECT COALESCE(MAX((x->>'ledger_sequence')::numeric),0)+1
      FROM jsonb_array_elements(v_evidence->'ledger') x) IS DISTINCT FROM v_sequence::numeric
    OR (SELECT COALESCE(SUM(CASE x->>'transaction_type' WHEN 'INCOMING'
      THEN (x->>'quantity')::numeric ELSE -(x->>'quantity')::numeric END),0)
      FROM jsonb_array_elements(v_evidence->'ledger') x
      WHERE x->>'ingredient_id'=v_ingredient_id::text) IS DISTINCT FROM v_balance THEN
    RAISE EXCEPTION 'FAIL: inconsistent ledger INSERT target, balance or sequence snapshot';
  END IF;
  -- Combined preservation across ALL caller-denial cases, not attribution
  -- solely to the direct ledger INSERT. Snapshot comparisons are complete rows.
  IF (SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb)
      FROM erp_private.inventory_transactions t) IS DISTINCT FROM v_evidence->'ledger'
    OR (SELECT COALESCE(jsonb_agg(to_jsonb(i) ORDER BY i.id),'[]'::jsonb)
      FROM erp_private.ingredients i) IS DISTINCT FROM v_evidence->'ingredients'
    OR (SELECT COALESCE(SUM(CASE transaction_type WHEN 'INCOMING' THEN quantity ELSE -quantity END),0)
      FROM erp_private.inventory_transactions WHERE ingredient_id=v_ingredient_id) IS DISTINCT FROM v_balance
    OR EXISTS (SELECT FROM erp_private.inventory_transactions WHERE id=v_probe_id OR ledger_sequence=v_sequence) THEN
    RAISE EXCEPTION 'FAIL: caller-denial section changed ledger or ingredient baseline';
  END IF;
  IF (SELECT count(*) FROM erp_private.units)<>2 OR (SELECT count(*) FROM erp_private.suppliers)<>2
    OR (SELECT count(*) FROM erp_private.ingredients)<>5 OR (SELECT count(*) FROM erp_private.inventory_transactions)<>10 THEN
    RAISE EXCEPTION 'FAIL: partial/rejected/rollback operation left unexpected rows';
  END IF;
  IF jsonb_array_length(pg_catalog.current_setting('erp_test.return_evidence')::jsonb)<>10
    OR (SELECT count(DISTINCT x->>'id') FROM jsonb_array_elements(pg_catalog.current_setting('erp_test.return_evidence')::jsonb) x)<>10
    OR EXISTS (
      SELECT FROM jsonb_array_elements(pg_catalog.current_setting('erp_test.return_evidence')::jsonb) x
      LEFT JOIN erp_private.inventory_transactions t ON t.id=(x->>'id')::uuid
      WHERE t.id IS NULL OR t.ledger_sequence IS DISTINCT FROM (x->>'sequence')::bigint
        OR t.ingredient_id IS DISTINCT FROM (x->>'ingredient')::uuid
    ) THEN RAISE EXCEPTION 'FAIL: return values do not match exact stored ledger rows'; END IF;
  SELECT id INTO STRICT v_stock FROM erp_private.ingredients WHERE name='P3B Stock';
  IF EXISTS (SELECT FROM erp_private.ingredients WHERE category<>'Test' OR created_at IS NULL
    OR unit_id<>CASE WHEN name='P3B Count' THEN '83000000-0000-4000-8000-000000000002'::uuid ELSE '83000000-0000-4000-8000-000000000001'::uuid END
    OR is_active<>(name NOT IN ('P3B Stock','P3B Zero'))
    OR (deactivated_at IS NULL)<>(name NOT IN ('P3B Stock','P3B Zero'))) THEN
    RAISE EXCEPTION 'FAIL: ingredient creation/status preservation';
  END IF;
  SELECT jsonb_agg(jsonb_build_array(transaction_type,quantity,transaction_date,supplier_id) ORDER BY ledger_sequence)
    INTO v_rows FROM erp_private.inventory_transactions WHERE ingredient_id=v_stock;
  IF v_rows IS DISTINCT FROM '[["INCOMING",12.50,"2026-01-01","83000000-0000-4000-8000-000000000011"],["INCOMING",0.50,"2026-01-01",null],["CONSUMPTION",3.00,"2026-01-01",null],["CONSUMPTION",10.00,"2025-12-31",null]]'::jsonb THEN
    RAISE EXCEPTION 'FAIL: stock ledger, exact balances or failed-operation preservation';
  END IF;
  IF (SELECT SUM(CASE t.transaction_type WHEN 'INCOMING' THEN t.quantity ELSE -t.quantity END)
    FROM erp_private.inventory_transactions t JOIN erp_private.ingredients i ON i.id=t.ingredient_id WHERE i.name='P3B Precision')
    IS DISTINCT FROM 10000000036.99::numeric
    OR (SELECT count(*) FROM erp_private.inventory_transactions t JOIN erp_private.ingredients i ON i.id=t.ingredient_id WHERE i.name='P3B Precision')<>4 THEN
    RAISE EXCEPTION 'FAIL: exact precision ledger';
  END IF;
  IF (SELECT jsonb_agg(jsonb_build_array(t.transaction_type,t.quantity) ORDER BY t.ledger_sequence)
    FROM erp_private.inventory_transactions t JOIN erp_private.ingredients i ON i.id=t.ingredient_id WHERE i.name='P3B Count')
    IS DISTINCT FROM '[["INCOMING",12.00],["CONSUMPTION",12.00]]'::jsonb
    OR EXISTS (SELECT FROM erp_private.inventory_transactions t JOIN erp_private.ingredients i ON i.id=t.ingredient_id
      WHERE i.name IN ('P3B Zero',U&'P3B \00C9pice')) THEN RAISE EXCEPTION 'FAIL: count/zero-stock ledger'; END IF;
  IF EXISTS (SELECT FROM erp_private.suppliers WHERE is_active<>(id='83000000-0000-4000-8000-000000000011'::uuid)) THEN
    RAISE EXCEPTION 'FAIL: supplier state changed';
  END IF;
  -- Verify each mutation target before asserting rejection.
  PERFORM id FROM erp_private.units WHERE id='83000000-0000-4000-8000-000000000001' AND code='lb' AND name='Pound' AND unit_type='WEIGHT';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: historical unit fixture missing/drifted'; END IF;
  BEGIN
    UPDATE erp_private.ingredients SET unit_id='83000000-0000-4000-8000-000000000002' WHERE id=v_stock;
    RAISE EXCEPTION 'FAIL: expected rejection: Historical ingredient unit is immutable';
  EXCEPTION WHEN SQLSTATE '23514' THEN
    IF SQLERRM <> 'Historical ingredient unit is immutable' THEN RAISE; END IF;
  END;
  BEGIN
    UPDATE erp_private.units SET name='Changed Pound' WHERE id='83000000-0000-4000-8000-000000000001';
    RAISE EXCEPTION 'FAIL: expected rejection: Historical unit definition is immutable';
  EXCEPTION WHEN SQLSTATE '23514' THEN
    IF SQLERRM <> 'Historical unit definition is immutable' THEN RAISE; END IF;
  END;
  BEGIN
    UPDATE erp_private.units SET code='changed-lb' WHERE id='83000000-0000-4000-8000-000000000001';
    RAISE EXCEPTION 'FAIL: expected rejection: Historical unit definition is immutable';
  EXCEPTION WHEN SQLSTATE '23514' THEN
    IF SQLERRM <> 'Historical unit definition is immutable' THEN RAISE; END IF;
  END;
  BEGIN
    UPDATE erp_private.units SET unit_type='COUNT' WHERE id='83000000-0000-4000-8000-000000000001';
    RAISE EXCEPTION 'FAIL: expected rejection: Historical unit definition is immutable';
  EXCEPTION WHEN SQLSTATE '23514' THEN
    IF SQLERRM <> 'Historical unit definition is immutable' THEN RAISE; END IF;
  END;
  BEGIN
    DELETE FROM erp_private.units WHERE id='83000000-0000-4000-8000-000000000001';
    RAISE EXCEPTION 'FAIL: expected rejection: Historical unit cannot be deleted';
  EXCEPTION WHEN SQLSTATE '23514' THEN
    IF SQLERRM <> 'Historical unit cannot be deleted' THEN RAISE; END IF;
  END;
  BEGIN
    UPDATE erp_private.inventory_transactions SET quantity=1 WHERE ingredient_id=v_stock;
    RAISE EXCEPTION 'FAIL: expected rejection: Inventory ledger is append-only';
  EXCEPTION WHEN SQLSTATE '23514' THEN
    IF SQLERRM <> 'Inventory ledger is append-only' THEN RAISE; END IF;
  END;
  BEGIN
    DELETE FROM erp_private.inventory_transactions WHERE ingredient_id=v_stock;
    RAISE EXCEPTION 'FAIL: expected rejection: Inventory ledger is append-only';
  EXCEPTION WHEN SQLSTATE '23514' THEN
    IF SQLERRM <> 'Inventory ledger is append-only' THEN RAISE; END IF;
  END;
  BEGIN
    TRUNCATE erp_private.inventory_transactions;
    RAISE EXCEPTION 'FAIL: expected rejection: Inventory ledger is append-only';
  EXCEPTION WHEN SQLSTATE '23514' THEN
    IF SQLERRM <> 'Inventory ledger is append-only' THEN RAISE; END IF;
  END;
END;
$verify$;
SET LOCAL ROLE erp_function_owner;
DO $locking$
BEGIN
  IF current_user<>'erp_function_owner' THEN RAISE EXCEPTION 'FAIL: wrong locking identity'; END IF;
  PERFORM id FROM erp_private.ingredients WHERE name='P3B Precision' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: ingredient locking visibility'; END IF;
  PERFORM id FROM erp_private.units WHERE id='83000000-0000-4000-8000-000000000001' FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: unit locking visibility'; END IF;
  PERFORM id FROM erp_private.suppliers WHERE id='83000000-0000-4000-8000-000000000011' FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: supplier locking visibility'; END IF;
  IF NOT pg_catalog.has_column_privilege(current_user,'erp_private.units','name','UPDATE')
    OR NOT pg_catalog.has_column_privilege(current_user,'erp_private.suppliers','is_active','UPDATE') THEN
    RAISE EXCEPTION 'FAIL: locking UPDATE privilege missing';
  END IF;
  BEGIN
    UPDATE erp_private.units SET name=name WHERE id='83000000-0000-4000-8000-000000000001';
    RAISE EXCEPTION 'FAIL: function owner unit update accepted';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM NOT LIKE 'new row violates row-level security policy%' THEN RAISE; END IF;
  END;
  BEGIN
    UPDATE erp_private.suppliers SET is_active=is_active WHERE id='83000000-0000-4000-8000-000000000011';
    RAISE EXCEPTION 'FAIL: function owner supplier update accepted';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM NOT LIKE 'new row violates row-level security policy%' THEN RAISE; END IF;
  END;
END;
$locking$;
ROLLBACK;
-- Whole business-table baseline, including non-ASCII fixtures and references.
BEGIN READ ONLY;
SET LOCAL ROLE erp_table_owner;
DO $baseline$
BEGIN
  IF EXISTS (SELECT FROM erp_private.units) OR EXISTS (SELECT FROM erp_private.ingredients)
    OR EXISTS (SELECT FROM erp_private.suppliers) OR EXISTS (SELECT FROM erp_private.inventory_transactions) THEN
    RAISE EXCEPTION 'FAIL: outer rollback did not preserve empty baseline';
  END IF;
END;
$baseline$;
ROLLBACK;
BEGIN ISOLATION LEVEL REPEATABLE READ;
SET LOCAL ROLE erp_admin_caller;
DO $isolation$
BEGIN
  BEGIN
    PERFORM erp_private.create_ingredient('P3B Isolation','Test','83000000-0000-4000-8000-000000000001');
    RAISE EXCEPTION 'FAIL: expected rejection: READ COMMITTED isolation is required';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'READ COMMITTED isolation is required' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM erp_private.record_inventory_transaction(NULL,'INCOMING','1',DATE '2026-01-01');
    RAISE EXCEPTION 'FAIL: expected rejection: READ COMMITTED isolation is required';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'READ COMMITTED isolation is required' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM erp_private.deactivate_ingredient(NULL);
    RAISE EXCEPTION 'FAIL: expected rejection: READ COMMITTED isolation is required';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'READ COMMITTED isolation is required' THEN RAISE; END IF;
  END;
END;
$isolation$;
ROLLBACK;
-- Single-session results do not establish concurrency or API behavior.
-- Complete acceptance also requires separately approved multi-session evidence.

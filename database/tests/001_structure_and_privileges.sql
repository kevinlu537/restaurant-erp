-- PREPARED ONLY. Requires separate test execution approval after M1-M4.
-- Run as the reviewed migration executor (including its default-ACL checks).
-- Every unexpected result is a STOP. No runtime membership is added for tests.
BEGIN READ ONLY;
-- Exact P5-I1 administrator exception; no inferred platform grantor.
DO $structure_memberships$
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
$structure_memberships$;
-- P5-I2: validate exact catalog identities before any OID-based assertion.
-- No object-name resolution, schema USAGE, helper objects or role changes needed.
DO $catalog_identities$
DECLARE r record; v_count bigint;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('erp_private','units','r'), ('erp_private','ingredients','r'),
    ('erp_private','suppliers','r'), ('erp_private','inventory_transactions','r'),
    ('erp_private','erp_ledger_sequence','S'),
    ('erp_private','ingredients_normalized_name_key','i'),
    ('erp_private','ingredients_unit_idx','i'),
    ('erp_private','inventory_transactions_ingredient_sequence_idx','i'),
    ('erp_private','inventory_transactions_supplier_idx','i'),
    ('erp_api','inventory_balances','v'), ('erp_api','inventory_history','v')
  ) AS e(schema_name,object_name,object_kind) LOOP
    SELECT count(*) INTO v_count FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname=r.schema_name AND c.relname=r.object_name
        AND c.relkind=r.object_kind::"char";
    IF v_count<>1 THEN
      RAISE EXCEPTION 'FAIL: missing or ambiguous expected relation %.% (kind %, matches %)',
        r.schema_name,r.object_name,r.object_kind,v_count;
    END IF;
  END LOOP;
  FOR r IN SELECT * FROM (VALUES
    ('create_ingredient(text,text,uuid)'),
    ('record_inventory_transaction(uuid,text,text,date,uuid)'),
    ('deactivate_ingredient(uuid)'), ('guard_ingredient_unit()'),
    ('guard_unit_definition()'), ('guard_ledger_mutation()')
  ) AS e(signature) LOOP
    SELECT count(*) INTO v_count FROM pg_catalog.pg_proc p
      JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='erp_private' AND p.prokind='f'
        AND p.proname=pg_catalog.split_part(r.signature,'(',1)
        AND pg_catalog.oidvectortypes(p.proargtypes)=pg_catalog.replace(
          pg_catalog.split_part(pg_catalog.split_part(r.signature,'(',2),')',1),',',', ');
    IF v_count<>1 THEN
      RAISE EXCEPTION 'FAIL: missing or ambiguous expected function erp_private.% (matches %)',r.signature,v_count;
    END IF;
  END LOOP;
END;
$catalog_identities$;
DO $checks$
DECLARE v_role record; v_table text; v_function record; v_columns text[]; v_table_oid oid;
BEGIN
  IF (SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname = 'erp_private') <> 4 THEN
    RAISE EXCEPTION 'Expected exactly four private tables';
  END IF;
  IF (SELECT count(*) FROM pg_catalog.pg_views WHERE schemaname = 'erp_api') <> 2 THEN
    RAISE EXCEPTION 'Expected exactly two API views';
  END IF;
  SELECT array_agg(attname::text ORDER BY attnum) INTO v_columns FROM pg_catalog.pg_attribute
    WHERE attrelid=(SELECT c.oid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='erp_api' AND c.relname='inventory_balances') AND attnum>0 AND NOT attisdropped;
  IF v_columns IS DISTINCT FROM ARRAY['ingredient_id','ingredient_name','category','unit_code','current_balance'] THEN
    RAISE EXCEPTION 'Unexpected balances fields';
  END IF;
  SELECT array_agg(attname::text ORDER BY attnum) INTO v_columns FROM pg_catalog.pg_attribute
    WHERE attrelid=(SELECT c.oid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='erp_api' AND c.relname='inventory_history') AND attnum>0 AND NOT attisdropped;
  IF v_columns IS DISTINCT FROM ARRAY['ledger_sequence','ingredient_name','transaction_type','quantity','unit_code','transaction_date','created_at'] THEN
    RAISE EXCEPTION 'Unexpected history fields';
  END IF;
  IF (SELECT count(*) FROM pg_catalog.pg_roles WHERE rolname IN
    ('erp_table_owner','erp_view_owner','erp_function_owner','erp_admin_caller')) <> 4 THEN
    RAISE EXCEPTION 'ERP role missing';
  END IF;
  FOR v_role IN SELECT * FROM pg_catalog.pg_roles WHERE rolname IN
    ('erp_table_owner','erp_view_owner','erp_function_owner','erp_admin_caller') LOOP
    IF v_role.rolsuper OR v_role.rolbypassrls OR v_role.rolcreaterole OR v_role.rolcreatedb
      OR v_role.rolreplication OR v_role.rolinherit
      OR v_role.rolcanlogin <> (v_role.rolname = 'erp_admin_caller') THEN
      RAISE EXCEPTION 'Unexpected ERP role attributes: %', v_role.rolname;
    END IF;
  END LOOP;
  IF EXISTS (SELECT FROM pg_catalog.pg_namespace WHERE nspname IN ('erp_private','erp_api')
    AND nspowner <> 'erp_table_owner'::regrole) THEN RAISE EXCEPTION 'Wrong schema owner'; END IF;
  IF EXISTS (SELECT FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='erp_private' AND c.relkind='r'
    AND (c.relowner <> 'erp_table_owner'::regrole OR NOT c.relrowsecurity OR NOT c.relforcerowsecurity)) THEN
    RAISE EXCEPTION 'Wrong table owner or RLS configuration';
  END IF;
  IF EXISTS (SELECT FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='erp_api' AND c.relkind='v'
    AND (c.relowner <> 'erp_view_owner'::regrole OR 'security_invoker=true' = ANY(COALESCE(c.reloptions, ARRAY[]::text[])))) THEN
    RAISE EXCEPTION 'Wrong view owner or invoker semantics';
  END IF;
  FOREACH v_table IN ARRAY ARRAY['units','ingredients','suppliers','inventory_transactions'] LOOP
    SELECT c.oid INTO STRICT v_table_oid FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='erp_private' AND c.relname=v_table AND c.relkind='r';
    IF pg_catalog.has_table_privilege('anon', v_table_oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
      OR pg_catalog.has_table_privilege('authenticated', v_table_oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
      OR pg_catalog.has_table_privilege('erp_admin_caller', v_table_oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') THEN
      RAISE EXCEPTION 'Unexpected base-table permission: %', v_table;
    END IF;
  END LOOP;
  FOR v_function IN SELECT p.oid, p.proname, p.proowner, p.prosecdef, p.proconfig
    FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='erp_private' LOOP
    IF v_function.proowner <> 'erp_function_owner'::regrole
      OR pg_catalog.has_function_privilege('anon', v_function.oid, 'EXECUTE')
      OR pg_catalog.has_function_privilege('authenticated', v_function.oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'Unexpected function owner/execution: %', v_function.proname;
    END IF;
    IF v_function.proname IN ('create_ingredient','record_inventory_transaction','deactivate_ingredient') THEN
      IF NOT v_function.prosecdef OR NOT pg_catalog.has_function_privilege('erp_admin_caller',v_function.oid,'EXECUTE') THEN
        RAISE EXCEPTION 'Wrong administrative execution model';
      END IF;
    ELSIF pg_catalog.has_function_privilege('erp_admin_caller',v_function.oid,'EXECUTE') THEN
      RAISE EXCEPTION 'Caller can execute helper';
    END IF;
    IF NOT ('search_path=pg_catalog, pg_temp' = ANY(COALESCE(v_function.proconfig, ARRAY[]::text[]))) THEN
      RAISE EXCEPTION 'Unsafe function search_path: %', v_function.proname;
    END IF;
  END LOOP;
END;
$checks$;
-- Capture these catalogs as evidence. Review all rows, including column ACLs,
-- PUBLIC ACL entries and defaults; zero rows here is not a passing result.
SELECT table_schema, table_name, column_name, data_type, is_nullable, column_default
  FROM information_schema.columns WHERE table_schema IN ('erp_private','erp_api')
  ORDER BY table_schema, table_name, ordinal_position;
SELECT schemaname, tablename, policyname, roles, cmd, qual, with_check
  FROM pg_catalog.pg_policies WHERE schemaname='erp_private';
SELECT n.nspname, c.relname, c.relkind, c.relowner::regrole, c.relacl, c.reloptions
  FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname IN ('erp_private','erp_api') ORDER BY 1,2;
SELECT * FROM information_schema.column_privileges WHERE table_schema IN ('erp_private','erp_api');
SELECT defaclrole::regrole, defaclnamespace::regnamespace, defaclobjtype, defaclacl FROM pg_catalog.pg_default_acl;
SELECT * FROM pg_catalog.pg_sequences WHERE schemaname='erp_private';
-- Manual acceptance: exact approved columns; UUID/defaults, FK RESTRICT,
-- name unique expression, positive finite quantity/type/supplier constraints,
-- CACHE 1 NO CYCLE, all helper triggers enabled; no sequence access to callers;
-- view owner no supplier/contact access, no column write grants; no runtime
-- schema CREATE, no private USAGE for anon/authenticated, no extra API objects.
SELECT conrelid::regclass, conname, pg_catalog.pg_get_constraintdef(oid)
  FROM pg_catalog.pg_constraint WHERE connamespace='erp_private'::regnamespace;
SELECT schemaname, tablename, indexname, indexdef FROM pg_catalog.pg_indexes WHERE schemaname='erp_private';
SELECT tgrelid::regclass, tgname, tgenabled, pg_catalog.pg_get_triggerdef(oid)
  FROM pg_catalog.pg_trigger WHERE tgrelid IN
    ((SELECT c.oid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='erp_private' AND c.relname='units'),(SELECT c.oid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='erp_private' AND c.relname='ingredients'),(SELECT c.oid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='erp_private' AND c.relname='inventory_transactions'))
    AND NOT tgisinternal;
SELECT schemaname, viewname, definition FROM pg_catalog.pg_views WHERE schemaname='erp_api';
-- R04: assertions supplement, rather than replace, catalog evidence above.
DO $extended$
DECLARE r record; a record; v_role text; v_priv text; v_expected boolean;
  v_columns text[]; v_oid oid; v_acl aclitem[];
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('units', ARRAY['id:uuid:false','code:text:false','name:text:false','unit_type:text:false']),
    ('ingredients', ARRAY['id:uuid:false','name:text:false','category:text:false','unit_id:uuid:false','is_active:boolean:false','created_at:timestamp with time zone:false','deactivated_at:timestamp with time zone:true']),
    ('suppliers', ARRAY['id:uuid:false','name:text:false','contact_email:text:true','phone:text:true','is_active:boolean:false','created_at:timestamp with time zone:false']),
    ('inventory_transactions', ARRAY['id:uuid:false','ledger_sequence:bigint:false','ingredient_id:uuid:false','supplier_id:uuid:true','transaction_type:text:false','quantity:numeric(12,2):false','transaction_date:date:false','created_at:timestamp with time zone:false'])
  ) AS e(table_name, columns) LOOP
    v_oid := (SELECT c.oid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='erp_private' AND c.relname=r.table_name);
    IF v_oid IS NULL THEN RAISE EXCEPTION 'FAIL: missing table %', r.table_name; END IF;
    SELECT array_agg(attname || ':' || pg_catalog.format_type(atttypid,atttypmod) || ':' || (NOT attnotnull)::text ORDER BY attnum)
      INTO v_columns FROM pg_catalog.pg_attribute WHERE attrelid=v_oid AND attnum>0 AND NOT attisdropped;
    IF v_columns IS DISTINCT FROM r.columns THEN RAISE EXCEPTION 'FAIL: table shape %', r.table_name; END IF;
    FOR a IN SELECT attname, attnum FROM pg_catalog.pg_attribute WHERE attrelid=v_oid AND attnum>0 AND NOT attisdropped LOOP
      FOREACH v_role IN ARRAY ARRAY['anon','authenticated','erp_admin_caller','erp_view_owner','erp_function_owner'] LOOP
        FOREACH v_priv IN ARRAY ARRAY['SELECT','INSERT','UPDATE','REFERENCES'] LOOP
          v_expected := false;
          IF v_role='erp_view_owner' AND v_priv='SELECT' THEN
            v_expected := (r.table_name='units' AND a.attname IN ('id','code'))
              OR (r.table_name='ingredients' AND a.attname IN ('id','name','category','unit_id','is_active'))
              OR (r.table_name='inventory_transactions' AND a.attname IN ('ledger_sequence','ingredient_id','transaction_type','quantity','transaction_date','created_at'));
          ELSIF v_role='erp_function_owner' THEN
            v_expected := (v_priv='SELECT' AND (r.table_name<>'suppliers' OR a.attname IN ('id','is_active')))
              OR (v_priv='INSERT' AND r.table_name='ingredients' AND a.attname IN ('name','category','unit_id'))
              OR (v_priv='INSERT' AND r.table_name='inventory_transactions' AND a.attname IN ('ledger_sequence','ingredient_id','supplier_id','transaction_type','quantity','transaction_date'))
              OR (v_priv='UPDATE' AND ((r.table_name='ingredients' AND a.attname IN ('is_active','deactivated_at'))
                OR (r.table_name='units' AND a.attname='name') OR (r.table_name='suppliers' AND a.attname='is_active')));
          END IF;
          IF pg_catalog.has_column_privilege(v_role,v_oid,a.attnum,v_priv) <> v_expected THEN
            RAISE EXCEPTION 'FAIL: column privilege %.% % %',r.table_name,a.attname,v_role,v_priv;
          END IF;
        END LOOP;
      END LOOP;
    END LOOP;
    FOREACH v_role IN ARRAY ARRAY['anon','authenticated','erp_admin_caller','erp_view_owner','erp_function_owner'] LOOP
      IF pg_catalog.has_table_privilege(v_role,v_oid,'DELETE,TRUNCATE,TRIGGER,REFERENCES') THEN
        RAISE EXCEPTION 'FAIL: forbidden table permission % %',r.table_name,v_role;
      END IF;
    END LOOP;
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_constraint WHERE conrelid=v_oid AND contype='p') THEN
      RAISE EXCEPTION 'FAIL: primary key missing %',r.table_name;
    END IF;
  END LOOP;
  FOREACH v_role IN ARRAY ARRAY['anon','authenticated','erp_admin_caller','erp_view_owner','erp_function_owner'] LOOP
    IF pg_catalog.has_schema_privilege(v_role,'erp_private','CREATE') OR pg_catalog.has_schema_privilege(v_role,'erp_api','CREATE') THEN
      RAISE EXCEPTION 'FAIL: retained schema CREATE %',v_role;
    END IF;
    IF pg_catalog.has_schema_privilege(v_role,'erp_private','USAGE') <> (v_role IN ('erp_admin_caller','erp_view_owner','erp_function_owner'))
      OR pg_catalog.has_schema_privilege(v_role,'erp_api','USAGE') <> (v_role IN ('anon','erp_view_owner')) THEN
      RAISE EXCEPTION 'FAIL: schema USAGE %',v_role;
    END IF;
    IF pg_catalog.has_sequence_privilege(v_role,(SELECT c.oid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='erp_private' AND c.relname='erp_ledger_sequence'),'USAGE') <> (v_role='erp_function_owner')
      OR pg_catalog.has_sequence_privilege(v_role,(SELECT c.oid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='erp_private' AND c.relname='erp_ledger_sequence'),'SELECT,UPDATE') THEN
      RAISE EXCEPTION 'FAIL: sequence privileges %',v_role;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_sequences WHERE schemaname='erp_private' AND sequencename='erp_ledger_sequence'
    AND sequenceowner='erp_table_owner' AND data_type='bigint'::regtype AND increment_by=1 AND min_value=1 AND cache_size=1 AND NOT cycle) THEN
    RAISE EXCEPTION 'FAIL: ledger sequence configuration';
  END IF;
  FOR r IN SELECT * FROM (VALUES
    ('create_ingredient(text,text,uuid)','uuid',false,true),
    ('record_inventory_transaction(uuid,text,text,date,uuid)','record',true,true),
    ('deactivate_ingredient(uuid)','void',false,true),
    ('guard_ingredient_unit()','trigger',false,true),
    ('guard_unit_definition()','trigger',false,true),
    ('guard_ledger_mutation()','trigger',false,false)
  ) AS e(signature, result_type, returns_set, definer) LOOP
    v_oid := (SELECT p.oid FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='erp_private' AND p.prokind='f' AND p.proname=pg_catalog.split_part(r.signature,'(',1) AND pg_catalog.oidvectortypes(p.proargtypes)=pg_catalog.replace(pg_catalog.split_part(pg_catalog.split_part(r.signature,'(',2),')',1),',',', '));
    IF v_oid IS NULL OR NOT EXISTS (SELECT FROM pg_catalog.pg_proc WHERE oid=v_oid
      AND prorettype=pg_catalog.to_regtype(r.result_type) AND proretset=r.returns_set
      AND prosecdef=r.definer AND provolatile='v' AND prolang=(SELECT oid FROM pg_catalog.pg_language WHERE lanname='plpgsql')) THEN
      RAISE EXCEPTION 'FAIL: function signature/behavior %',r.signature;
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM pg_catalog.pg_proc WHERE pronamespace='erp_private'::regnamespace) <> 6
    OR EXISTS (SELECT FROM pg_catalog.pg_proc WHERE pronamespace='erp_api'::regnamespace) THEN
    RAISE EXCEPTION 'FAIL: unexpected function or overload';
  END IF;
  FOR r IN SELECT * FROM (VALUES
    ('ingredients_unit_guard','ingredients','guard_ingredient_unit()',19),
    ('units_definition_guard','units','guard_unit_definition()',27),
    ('ledger_mutation_guard','inventory_transactions','guard_ledger_mutation()',27),
    ('ledger_truncate_guard','inventory_transactions','guard_ledger_mutation()',34)
  ) AS e(trigger_name,table_name,signature,type_bits) LOOP
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_trigger WHERE tgrelid=(SELECT c.oid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='erp_private' AND c.relname=r.table_name)
      AND tgname=r.trigger_name AND tgfoid=(SELECT p.oid FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='erp_private' AND p.prokind='f' AND p.proname=pg_catalog.split_part(r.signature,'(',1) AND pg_catalog.oidvectortypes(p.proargtypes)=pg_catalog.replace(pg_catalog.split_part(pg_catalog.split_part(r.signature,'(',2),')',1),',',', '))
      AND tgenabled='O' AND tgtype=r.type_bits) THEN
      RAISE EXCEPTION 'FAIL: trigger configuration %',r.trigger_name;
    END IF;
  END LOOP;
  FOR r IN SELECT * FROM (VALUES
    ('ingredients_normalized_name_key',true),('ingredients_unit_idx',false),
    ('inventory_transactions_ingredient_sequence_idx',false),('inventory_transactions_supplier_idx',false)
  ) AS e(index_name,is_unique) LOOP
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_index WHERE indexrelid=(SELECT c.oid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='erp_private' AND c.relname=r.index_name)
      AND indisvalid AND indisready AND indisunique=r.is_unique) THEN
      RAISE EXCEPTION 'FAIL: required index %',r.index_name;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_index WHERE indexrelid=(SELECT c.oid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='erp_private' AND c.relname='ingredients_normalized_name_key')
    AND pg_catalog.pg_get_expr(indexprs,indrelid)='lower((name COLLATE "C"))' AND indpred IS NULL) THEN
    RAISE EXCEPTION 'FAIL: name uniqueness expression; review PostgreSQL catalog rendering if different';
  END IF;
  IF (SELECT count(*) FROM pg_catalog.pg_constraint WHERE connamespace='erp_private'::regnamespace AND contype='f') <> 3
    OR EXISTS (SELECT FROM pg_catalog.pg_constraint WHERE connamespace='erp_private'::regnamespace AND contype='f'
      AND (confdeltype<>'r' OR NOT convalidated)) THEN RAISE EXCEPTION 'FAIL: foreign key restrictions'; END IF;
  IF (SELECT count(*) FROM pg_catalog.pg_policy WHERE polrelid IN
    ((SELECT c.oid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='erp_private' AND c.relname='units'),(SELECT c.oid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='erp_private' AND c.relname='ingredients'),(SELECT c.oid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='erp_private' AND c.relname='suppliers'),(SELECT c.oid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='erp_private' AND c.relname='inventory_transactions'))) <> 13 THEN
    RAISE EXCEPTION 'FAIL: unexpected RLS policy inventory';
  END IF;
  FOR r IN SELECT * FROM (VALUES ('units_function_lock','units'),('suppliers_function_lock','suppliers')) AS e(policy_name,table_name) LOOP
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_policy WHERE polrelid=(SELECT c.oid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='erp_private' AND c.relname=r.table_name)
      AND polname=r.policy_name AND polcmd='w' AND polpermissive
      AND polroles=ARRAY['erp_function_owner'::regrole::oid]
      AND pg_catalog.pg_get_expr(polqual,polrelid)='true' AND pg_catalog.pg_get_expr(polwithcheck,polrelid)='false') THEN
      RAISE EXCEPTION 'FAIL: locking policy %',r.policy_name;
    END IF;
  END LOOP;
  FOR r IN SELECT * FROM (VALUES
    ('units','units_code_key','u'),('ingredients','ingredient_name_normalized','c'),
    ('ingredients','ingredient_status_consistent','c'),
    ('inventory_transactions','inventory_transactions_ledger_sequence_key','u'),
    ('inventory_transactions','inventory_transactions_ledger_sequence_check','c'),
    ('inventory_transactions','inventory_transactions_transaction_type_check','c'),
    ('inventory_transactions','inventory_transactions_quantity_check','c'),
    ('inventory_transactions','inventory_transactions_transaction_date_check','c'),
    ('inventory_transactions','consumption_has_no_supplier','c')
  ) AS e(table_name,constraint_name,constraint_type) LOOP
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_constraint WHERE conrelid=(SELECT c.oid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='erp_private' AND c.relname=r.table_name)
      AND conname=r.constraint_name AND contype=r.constraint_type::"char" AND convalidated) THEN
      RAISE EXCEPTION 'FAIL: required constraint %',r.constraint_name;
    END IF;
  END LOOP;
  FOR r IN SELECT * FROM (VALUES
    ('ingredients_unit_idx',ARRAY['unit_id']),
    ('inventory_transactions_ingredient_sequence_idx',ARRAY['ingredient_id','ledger_sequence']),
    ('inventory_transactions_supplier_idx',ARRAY['supplier_id'])
  ) AS e(index_name,columns) LOOP
    SELECT array_agg(a.attname::text ORDER BY k.ordinality) INTO v_columns
      FROM pg_catalog.pg_index i CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY k(attnum,ordinality)
      JOIN pg_catalog.pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=k.attnum
      WHERE i.indexrelid=(SELECT c.oid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='erp_private' AND c.relname=r.index_name);
    IF v_columns IS DISTINCT FROM r.columns THEN RAISE EXCEPTION 'FAIL: index columns %',r.index_name; END IF;
  END LOOP;
  FOR r IN SELECT c.relname,a.attname,pg_catalog.pg_get_expr(d.adbin,d.adrelid) AS expression
    FROM pg_catalog.pg_class c JOIN pg_catalog.pg_attribute a ON a.attrelid=c.oid
    LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid=c.oid AND d.adnum=a.attnum
    WHERE c.relnamespace='erp_private'::regnamespace AND c.relkind='r'
      AND a.attnum>0 AND NOT a.attisdropped LOOP
    IF r.attname='id' THEN v_expected := r.expression='gen_random_uuid()';
    ELSIF r.attname='created_at' THEN v_expected := r.expression='clock_timestamp()';
    ELSIF r.attname='is_active' THEN v_expected := r.expression='true';
    ELSE v_expected := r.expression IS NULL;
    END IF;
    IF NOT COALESCE(v_expected,false) THEN RAISE EXCEPTION 'FAIL: default %.%',r.relname,r.attname; END IF;
  END LOOP;
  FOREACH v_role IN ARRAY ARRAY['anon','authenticated','erp_admin_caller','erp_view_owner','erp_function_owner'] LOOP
    FOR r IN SELECT oid,relname FROM pg_catalog.pg_class WHERE relnamespace='erp_api'::regnamespace AND relkind='v' LOOP
      IF pg_catalog.has_table_privilege(v_role,r.oid,'SELECT') <> (v_role IN ('anon','erp_view_owner'))
        OR pg_catalog.has_table_privilege(v_role,r.oid,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
          AND v_role<>'erp_view_owner' THEN RAISE EXCEPTION 'FAIL: view grants % %',v_role,r.relname; END IF;
      -- The view owner has inherent ownership rights; underlying write grants
      -- are denied separately. Never treat owner privileges as anonymous grants.
    END LOOP;
  END LOOP;
  -- Evaluate global defaults INCLUDING built-in defaults if no ACL row exists;
  -- schema additions must not reintroduce a non-owner recipient.
  FOREACH v_role IN ARRAY ARRAY['erp_table_owner','erp_view_owner','erp_function_owner',current_user::text] LOOP
    FOREACH v_priv IN ARRAY ARRAY['f','r','S'] LOOP
      SELECT defaclacl INTO v_acl FROM pg_catalog.pg_default_acl
        WHERE defaclrole=v_role::regrole AND defaclnamespace=0 AND defaclobjtype=v_priv::"char";
      v_acl := COALESCE(v_acl,pg_catalog.acldefault(v_priv::"char",v_role::regrole));
      IF EXISTS (SELECT FROM pg_catalog.aclexplode(v_acl) WHERE grantee<>v_role::regrole) THEN
        RAISE EXCEPTION 'FAIL: non-owner global default % %',v_role,v_priv;
      END IF;
      IF EXISTS (SELECT FROM pg_catalog.pg_default_acl d CROSS JOIN LATERAL pg_catalog.aclexplode(d.defaclacl) x
        WHERE d.defaclrole=v_role::regrole AND d.defaclobjtype=v_priv::"char"
          AND d.defaclnamespace IN ('erp_private'::regnamespace,'erp_api'::regnamespace)
          AND x.grantee<>v_role::regrole) THEN RAISE EXCEPTION 'FAIL: schema default addition % %',v_role,v_priv; END IF;
    END LOOP;
  END LOOP;
END;
$extended$;
ROLLBACK;

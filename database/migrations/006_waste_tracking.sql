-- LOCAL DRAFT ONLY. PostgreSQL 17. Never apply without separate authorization.
-- Requires M1-M4; no functional dependency on the unapplied M5 reactivation draft.
BEGIN;
-- Exact P5-I1 administrator exception; no inferred platform grantor.
DO $m6_memberships$
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
$m6_memberships$;
DO $m6_defaults$
DECLARE v_kind "char";
BEGIN
  FOREACH v_kind IN ARRAY ARRAY['f'::"char",'r'::"char",'S'::"char"] LOOP
    IF EXISTS (SELECT FROM pg_catalog.aclexplode(COALESCE(
      (SELECT defaclacl FROM pg_catalog.pg_default_acl WHERE defaclrole='erp_function_owner'::regrole AND defaclnamespace=0 AND defaclobjtype=v_kind),
      pg_catalog.acldefault(v_kind,'erp_function_owner'::regrole))) a WHERE a.grantee<>'erp_function_owner'::regrole)
      OR EXISTS (SELECT FROM pg_catalog.pg_default_acl d CROSS JOIN LATERAL pg_catalog.aclexplode(d.defaclacl) a
        WHERE d.defaclrole='erp_function_owner'::regrole AND d.defaclobjtype=v_kind
        AND d.defaclnamespace IN ('erp_private'::regnamespace,'erp_api'::regnamespace) AND a.grantee<>'erp_function_owner'::regrole) THEN
      RAISE EXCEPTION 'Non-owner creator defaults for erp_function_owner; stop for separately approved remediation';
    END IF;
  END LOOP;
END;
$m6_defaults$;
DO $m6_view_defaults$
DECLARE v_kind "char";
BEGIN
  FOREACH v_kind IN ARRAY ARRAY['f'::"char",'r'::"char",'S'::"char"] LOOP
    IF EXISTS (SELECT FROM pg_catalog.aclexplode(COALESCE(
      (SELECT defaclacl FROM pg_catalog.pg_default_acl WHERE defaclrole='erp_view_owner'::regrole AND defaclnamespace=0 AND defaclobjtype=v_kind),
      pg_catalog.acldefault(v_kind,'erp_view_owner'::regrole))) a WHERE a.grantee<>'erp_view_owner'::regrole)
      OR EXISTS (SELECT FROM pg_catalog.pg_default_acl d CROSS JOIN LATERAL pg_catalog.aclexplode(d.defaclacl) a
        WHERE d.defaclrole='erp_view_owner'::regrole AND d.defaclobjtype=v_kind
        AND d.defaclnamespace IN ('erp_private'::regnamespace,'erp_api'::regnamespace) AND a.grantee<>'erp_view_owner'::regrole) THEN
      RAISE EXCEPTION 'Non-owner creator defaults for erp_view_owner; stop for separately approved remediation';
    END IF;
  END LOOP;
END;
$m6_view_defaults$;
SET LOCAL ROLE erp_table_owner;
LOCK TABLE erp_private.inventory_transactions IN ACCESS EXCLUSIVE MODE;
DO $waste_constraint$
DECLARE v_att smallint; v_count integer; v_constraint name;
BEGIN
  IF current_setting('server_version_num')::integer / 10000 <> 17 THEN
    RAISE EXCEPTION 'M6 requires PostgreSQL 17';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_class
    WHERE oid='erp_private.inventory_transactions'::regclass AND relowner='erp_table_owner'::regrole
      AND relrowsecurity AND relforcerowsecurity) THEN
    RAISE EXCEPTION 'M6 ledger ownership/RLS differs from baseline';
  END IF;
  SELECT attnum INTO STRICT v_att FROM pg_catalog.pg_attribute
    WHERE attrelid='erp_private.inventory_transactions'::regclass AND attname='transaction_type' AND NOT attisdropped;
  SELECT count(*), min(conname::text)::name INTO v_count,v_constraint FROM pg_catalog.pg_constraint
    WHERE conrelid='erp_private.inventory_transactions'::regclass AND contype='c'
      AND conkey=ARRAY[v_att] AND convalidated AND NOT connoinherit
      AND pg_catalog.regexp_replace(pg_catalog.pg_get_expr(conbin,conrelid), '[[:space:]]', '', 'g')
        = '(transaction_type=ANY(ARRAY[''INCOMING''::text,''CONSUMPTION''::text]))';
  IF v_count <> 1 OR (SELECT count(*) FROM pg_catalog.pg_constraint
      WHERE conrelid='erp_private.inventory_transactions'::regclass AND contype='c' AND conkey=ARRAY[v_att]) <> 1 THEN
    RAISE EXCEPTION 'M6 expected exact original transaction-type CHECK; stop, do not guess its name';
  END IF;
  -- Identifier is taken only from the exact, validated catalog match under the DDL lock.
  EXECUTE pg_catalog.format('ALTER TABLE erp_private.inventory_transactions DROP CONSTRAINT %I',v_constraint);
END;
$waste_constraint$;
ALTER TABLE erp_private.inventory_transactions
  ADD COLUMN waste_reason text,
  ADD COLUMN recorded_by uuid,
  ADD CONSTRAINT inventory_transaction_type_waste_check CHECK (transaction_type IN ('INCOMING','CONSUMPTION','WASTE')),
  ADD CONSTRAINT inventory_waste_metadata_check CHECK (
    (transaction_type='WASTE' AND waste_reason IS NOT NULL
      AND waste_reason IN ('spoiled','damaged','other') AND recorded_by IS NOT NULL AND supplier_id IS NULL)
    OR (transaction_type<>'WASTE' AND waste_reason IS NULL AND recorded_by IS NULL));
-- Keep the original consumption supplier CHECK, RLS policies and immutable triggers.
GRANT INSERT (waste_reason, recorded_by, created_at) ON erp_private.inventory_transactions TO erp_function_owner;
GRANT SELECT (waste_reason) ON erp_private.inventory_transactions TO erp_view_owner;
GRANT CREATE ON SCHEMA erp_private TO erp_function_owner;
SET LOCAL ROLE erp_function_owner;
CREATE FUNCTION erp_private.record_waste(
  p_ingredient_id uuid, p_quantity_text text, p_reason text, p_operator_id uuid)
RETURNS TABLE (transaction_id uuid, ledger_sequence_text text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  v_ingredient erp_private.ingredients%ROWTYPE;
  v_unit_code text; v_quantity numeric; v_balance numeric;
  v_id uuid; v_sequence bigint; v_recorded_at timestamptz;
BEGIN
  -- The restricted Edge caller supplies the Auth-verified, allowlisted operator UUID.
  -- SQL does not independently verify a JWT; never expose EXECUTE to API roles.
  IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'READ COMMITTED isolation is required' USING ERRCODE='22023';
  END IF;
  IF p_ingredient_id IS NULL OR p_operator_id IS NULL OR p_reason IS NULL
    OR p_reason NOT IN ('spoiled','damaged','other') THEN
    RAISE EXCEPTION 'Invalid waste fields' USING ERRCODE='22023';
  END IF;
  IF p_quantity_text IS NULL OR p_quantity_text !~ '^[0-9]+([.][0-9]{1,2})?$' THEN
    RAISE EXCEPTION 'Invalid waste quantity' USING ERRCODE='22023';
  END IF;
  IF pg_catalog.length(pg_catalog.ltrim(pg_catalog.split_part(p_quantity_text,'.',1),'0')) > 10 THEN
    RAISE EXCEPTION 'Quantity exceeds maximum' USING ERRCODE='22023';
  END IF;
  v_quantity := ('0' || pg_catalog.ltrim(p_quantity_text,'0'))::numeric;
  IF v_quantity <= 0 OR v_quantity > 9999999999.99 THEN
    RAISE EXCEPTION 'Waste quantity outside bounds' USING ERRCODE='22023';
  END IF;
  SELECT i.* INTO v_ingredient FROM erp_private.ingredients i WHERE i.id=p_ingredient_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown ingredient' USING ERRCODE='22023'; END IF;
  IF NOT v_ingredient.is_active THEN RAISE EXCEPTION 'Ingredient is inactive' USING ERRCODE='22023'; END IF;
  -- Separate statement after locking: see newly committed ledger rows at READ COMMITTED.
  SELECT COALESCE(SUM(CASE t.transaction_type WHEN 'INCOMING' THEN t.quantity ELSE -t.quantity END),0)
    INTO v_balance FROM erp_private.inventory_transactions t WHERE t.ingredient_id=p_ingredient_id;
  SELECT u.code INTO v_unit_code FROM erp_private.units u WHERE u.id=v_ingredient.unit_id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown unit' USING ERRCODE='22023'; END IF;
  IF v_unit_code='each' AND v_quantity<>pg_catalog.trunc(v_quantity) THEN
    RAISE EXCEPTION 'Each quantities must be whole numbers' USING ERRCODE='22023';
  END IF;
  IF v_quantity > v_balance THEN RAISE EXCEPTION 'Waste exceeds available stock' USING ERRCODE='23514'; END IF;
  v_recorded_at := pg_catalog.clock_timestamp();
  v_sequence := pg_catalog.nextval('erp_private.erp_ledger_sequence'::regclass);
  INSERT INTO erp_private.inventory_transactions
    (ledger_sequence,ingredient_id,supplier_id,transaction_type,quantity,transaction_date,created_at,waste_reason,recorded_by)
    VALUES (v_sequence,p_ingredient_id,NULL,'WASTE',v_quantity::numeric(12,2),
      (v_recorded_at AT TIME ZONE 'UTC')::date,v_recorded_at,p_reason,p_operator_id)
    RETURNING id INTO v_id;
  RETURN QUERY SELECT v_id,v_sequence::text;
END;
$function$;
REVOKE ALL ON FUNCTION erp_private.record_waste(uuid,text,text,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION erp_private.record_waste(uuid,text,text,uuid) TO erp_admin_caller;
SET LOCAL ROLE erp_table_owner;
REVOKE CREATE ON SCHEMA erp_private FROM erp_function_owner;
-- Existing view owner needs temporary schema CREATE for CREATE OR REPLACE VIEW.
GRANT CREATE ON SCHEMA erp_api TO erp_view_owner;
SET LOCAL ROLE erp_view_owner;
DO $history_shape$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_class WHERE oid='erp_api.inventory_history'::regclass
      AND relkind='v' AND relowner='erp_view_owner'::regrole)
    OR (SELECT array_agg(attname::text ORDER BY attnum) FROM pg_catalog.pg_attribute
      WHERE attrelid='erp_api.inventory_history'::regclass AND attnum>0 AND NOT attisdropped)
      IS DISTINCT FROM ARRAY['ledger_sequence','ingredient_name','transaction_type','quantity','unit_code','transaction_date','created_at'] THEN
    RAISE EXCEPTION 'M6 history view shape/owner differs; stop for review';
  END IF;
END;
$history_shape$;
-- Append only the approved non-sensitive reason. Existing names/types/order are retained.
-- recorded_by remains private; reasons inherit the existing anonymous demo read exposure.
CREATE OR REPLACE VIEW erp_api.inventory_history WITH (security_barrier=true) AS
SELECT t.ledger_sequence, i.name AS ingredient_name, t.transaction_type, t.quantity,
  u.code AS unit_code, t.transaction_date, t.created_at, t.waste_reason
FROM erp_private.inventory_transactions t
JOIN erp_private.ingredients i ON i.id=t.ingredient_id
JOIN erp_private.units u ON u.id=i.unit_id;
SET LOCAL ROLE erp_table_owner;
REVOKE CREATE ON SCHEMA erp_api FROM erp_view_owner;
SET LOCAL ROLE postgres;
DO $m6_cleanup$
BEGIN
  IF pg_catalog.has_schema_privilege('erp_function_owner','erp_private','CREATE')
    OR pg_catalog.has_schema_privilege('erp_view_owner','erp_api','CREATE')
    OR pg_catalog.has_function_privilege('anon','erp_private.record_waste(uuid,text,text,uuid)','EXECUTE')
    OR pg_catalog.has_function_privilege('authenticated','erp_private.record_waste(uuid,text,text,uuid)','EXECUTE')
    OR NOT pg_catalog.has_function_privilege('erp_admin_caller','erp_private.record_waste(uuid,text,text,uuid)','EXECUTE')
    OR (SELECT proowner FROM pg_catalog.pg_proc WHERE oid='erp_private.record_waste(uuid,text,text,uuid)'::regprocedure)
      <> 'erp_function_owner'::regrole THEN
    RAISE EXCEPTION 'M6 unexpected final privileges/ownership';
  END IF;
END;
$m6_cleanup$;
COMMIT;

-- LOCAL DRAFT ONLY. PostgreSQL 17. Requires M1-M4, not execution of M5/M6.
BEGIN;
-- Exact P5-I1 administrator exception; no inferred platform grantor.
DO $m7_memberships$
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
$m7_memberships$;
DO $m7_defaults$
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
$m7_defaults$;

SET LOCAL ROLE erp_table_owner;
DO $m7_version$
BEGIN
  IF current_setting('server_version_num')::integer / 10000 <> 17 THEN
    RAISE EXCEPTION 'M7 requires PostgreSQL 17';
  END IF;
END;
$m7_version$;
ALTER TABLE erp_private.inventory_transactions ADD COLUMN expires_on date;
ALTER TABLE erp_private.inventory_transactions ADD CONSTRAINT incoming_expiration_check CHECK (
  expires_on IS NULL OR
  (transaction_type='INCOMING' AND pg_catalog.isfinite(expires_on) AND expires_on >= transaction_date));
-- Existing rows remain NULL. No ledger UPDATE/backfill, no public view expansion.
GRANT INSERT (expires_on) ON erp_private.inventory_transactions TO erp_function_owner;
-- M2 already grants table SELECT to this trusted function owner; no new SELECT
-- grant (especially none on recorded_by) or public/authenticated table access is needed.
GRANT CREATE ON SCHEMA erp_private TO erp_function_owner;
SET LOCAL ROLE erp_function_owner;
CREATE FUNCTION erp_private.record_receipt_v1(
  p_ingredient_id uuid, p_quantity_text text, p_transaction_date date, p_expires_on date)
RETURNS TABLE (transaction_id uuid, ledger_sequence_text text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  v_ingredient erp_private.ingredients%ROWTYPE;
  v_unit_code text;
  v_quantity numeric;
  v_id uuid;
  v_sequence bigint;
BEGIN
  IF current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'READ COMMITTED isolation is required' USING ERRCODE = '22023';
  END IF;
  IF p_ingredient_id IS NULL OR p_transaction_date IS NULL
     OR NOT pg_catalog.isfinite(p_transaction_date) THEN
    RAISE EXCEPTION 'Ingredient and finite business date are required' USING ERRCODE = '22023';
  END IF;
  IF p_expires_on IS NOT NULL AND (NOT pg_catalog.isfinite(p_expires_on) OR p_expires_on < p_transaction_date) THEN
    RAISE EXCEPTION 'Invalid expiration date' USING ERRCODE = '22023';
  END IF;
  -- Strict ASCII decimal grammar. No trimming, signs, exponent or rounding.
  IF p_quantity_text IS NULL OR p_quantity_text !~ '^[0-9]+([.][0-9]{1,2})?$' THEN
    RAISE EXCEPTION 'Quantity must be unsigned decimal text with at most two fractional digits' USING ERRCODE = '22023';
  END IF;
  -- Limit significant integer digits before NUMERIC parsing, including huge
  -- zero-padded input. This prevents typmod rounding and numeric overflow.
  IF pg_catalog.length(pg_catalog.ltrim(pg_catalog.split_part(p_quantity_text, '.', 1), '0')) > 10 THEN
    RAISE EXCEPTION 'Quantity exceeds 9999999999.99' USING ERRCODE = '22023';
  END IF;
  v_quantity := ('0' || pg_catalog.ltrim(p_quantity_text, '0'))::numeric;
  IF v_quantity <= 0 OR v_quantity > 9999999999.99 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero and at most 9999999999.99' USING ERRCODE = '22023';
  END IF;

  SELECT i.* INTO v_ingredient FROM erp_private.ingredients AS i
    WHERE i.id = p_ingredient_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown ingredient' USING ERRCODE = '22023';
  END IF;
  IF NOT v_ingredient.is_active THEN
    RAISE EXCEPTION 'Ingredient is inactive' USING ERRCODE = '22023';
  END IF;
  -- Receipt-only operation: lock ingredient then authoritative unit until commit.
  SELECT u.code INTO v_unit_code FROM erp_private.units AS u
    WHERE u.id = v_ingredient.unit_id FOR SHARE;
  IF v_unit_code = 'each' AND v_quantity <> pg_catalog.trunc(v_quantity) THEN
    RAISE EXCEPTION 'Each quantities must be whole numbers' USING ERRCODE = '22023';
  END IF;
  v_sequence := pg_catalog.nextval('erp_private.erp_ledger_sequence'::regclass);
  INSERT INTO erp_private.inventory_transactions
    (ledger_sequence, ingredient_id, supplier_id, transaction_type, quantity, transaction_date, expires_on)
    VALUES (v_sequence, p_ingredient_id, NULL, 'INCOMING', v_quantity::numeric(12,2), p_transaction_date, p_expires_on)
    RETURNING id INTO v_id;
  RETURN QUERY SELECT v_id, v_sequence::text;
END;
$function$;
-- Protected read: Edge verifies Auth and exact operator allowlisting before execution.
-- This function deliberately exposes no actor, supplier contact, or Waste metadata.
CREATE FUNCTION erp_private.list_receipt_expirations(p_offset integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE v_total integer; v_rows jsonb;
BEGIN
  IF p_offset IS NULL OR p_offset < 0 OR p_offset > 49500 OR p_offset % 500 <> 0 THEN
    RAISE EXCEPTION 'Invalid receipt page' USING ERRCODE='22023';
  END IF;
  SELECT count(*) INTO v_total FROM (
    SELECT 1 FROM erp_private.inventory_transactions WHERE transaction_type='INCOMING' LIMIT 50001
  ) bounded;
  IF v_total > 50000 THEN RAISE EXCEPTION 'Receipt read limit exceeded' USING ERRCODE='22023'; END IF;
  WITH page AS (
    SELECT t.id AS receipt_id,t.ingredient_id,i.name,t.quantity,u.code,t.transaction_date,t.expires_on,t.ledger_sequence
    FROM erp_private.inventory_transactions t
    JOIN erp_private.ingredients i ON i.id=t.ingredient_id
    JOIN erp_private.units u ON u.id=i.unit_id
    WHERE t.transaction_type='INCOMING'
    ORDER BY t.ledger_sequence,t.id LIMIT 500 OFFSET p_offset
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'receipt_id',receipt_id::text,'ingredient_id',ingredient_id::text,'ingredient_name',name,
    'original_quantity',quantity::text,'unit_code',code,'transaction_date',pg_catalog.to_char(transaction_date,'YYYY-MM-DD'),
    'expires_on',pg_catalog.to_char(expires_on,'YYYY-MM-DD'),'ledger_sequence',ledger_sequence::text)
    ORDER BY ledger_sequence,receipt_id),'[]'::jsonb) INTO v_rows FROM page;
  RETURN jsonb_build_object('total',v_total::text,'rows',v_rows);
END;
$function$;
REVOKE ALL ON FUNCTION erp_private.record_receipt_v1(uuid,text,date,date),
  erp_private.list_receipt_expirations(integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION erp_private.record_receipt_v1(uuid,text,date,date),
  erp_private.list_receipt_expirations(integer) TO erp_admin_caller;
SET LOCAL ROLE erp_table_owner;
REVOKE CREATE ON SCHEMA erp_private FROM erp_function_owner;
SET LOCAL ROLE postgres;
DO $m7_cleanup$
BEGIN
  IF pg_catalog.has_schema_privilege('erp_function_owner','erp_private','CREATE') THEN
    RAISE EXCEPTION 'M7 temporary CREATE remains';
  END IF;
  IF EXISTS (SELECT FROM pg_catalog.pg_proc WHERE oid IN (
      'erp_private.record_receipt_v1(uuid,text,date,date)'::regprocedure,
      'erp_private.list_receipt_expirations(integer)'::regprocedure)
    AND (proowner<>'erp_function_owner'::regrole OR NOT prosecdef
      OR pg_catalog.has_function_privilege('anon',oid,'EXECUTE')
      OR pg_catalog.has_function_privilege('authenticated',oid,'EXECUTE')
      OR NOT pg_catalog.has_function_privilege('erp_admin_caller',oid,'EXECUTE'))) THEN
    RAISE EXCEPTION 'M7 unexpected routine ownership/privileges';
  END IF;
END;
$m7_cleanup$;
COMMIT;

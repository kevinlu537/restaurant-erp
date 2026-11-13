-- PREPARED ONLY. M5; requires M1-M4 and separate execution approval.
-- P5-I1: direct owner creation with exact postgres administrative memberships.
-- Runtime privileges remain restricted. Requires Live Verification.
BEGIN;
-- Exact P5-I1 administrator exception; no inferred platform grantor.
DO $m5_memberships$
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
$m5_memberships$;
DO $m5_defaults$
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
$m5_defaults$;
SET LOCAL ROLE erp_table_owner;
-- Temporary owner creation authority; removed in this transaction.
GRANT CREATE ON SCHEMA erp_private TO erp_function_owner;
SET LOCAL ROLE erp_function_owner;

-- Resolve by the same C-collation lower(name) key as the global unique index.
-- Runtime execution is restricted to the authenticated Edge write identity.
CREATE FUNCTION erp_private.reactivate_ingredient(p_name text)
RETURNS uuid LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  v_name text := pg_catalog.btrim(p_name, E' \t\n\r');
  v_ingredient erp_private.ingredients%ROWTYPE;
  v_balance numeric;
BEGIN
  IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'READ COMMITTED isolation is required' USING ERRCODE = '22023';
  END IF;
  -- Match create_ingredient: ASCII boundary trim and nonempty name only.
  -- The existing 200-UTF-16-unit limit is enforced by the frontend and Edge.
  IF v_name IS NULL OR v_name = '' THEN
    RAISE EXCEPTION 'Invalid ingredient name' USING ERRCODE = '22023';
  END IF;
  SELECT i.* INTO v_ingredient FROM erp_private.ingredients AS i
    WHERE pg_catalog.lower(i.name COLLATE "C") = pg_catalog.lower(v_name COLLATE "C")
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Ingredient not found' USING ERRCODE = 'P3401';
  END IF;
  IF v_ingredient.is_active THEN
    RAISE EXCEPTION 'Ingredient is already active' USING ERRCODE = 'P3402';
  END IF;
  -- Read after acquiring the same ingredient lock used by stock operations.
  SELECT COALESCE(SUM(CASE t.transaction_type WHEN 'INCOMING' THEN t.quantity ELSE -t.quantity END), 0)
    INTO v_balance FROM erp_private.inventory_transactions AS t
    WHERE t.ingredient_id = v_ingredient.id;
  IF v_balance <> 0 THEN
    RAISE EXCEPTION 'Inactive ingredient has nonzero stock' USING ERRCODE = 'P3403';
  END IF;
  UPDATE erp_private.ingredients SET is_active = true, deactivated_at = NULL
    WHERE id = v_ingredient.id;
  RETURN v_ingredient.id;
END;
$function$;
REVOKE ALL ON FUNCTION erp_private.reactivate_ingredient(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION erp_private.reactivate_ingredient(text) TO erp_admin_caller;
SET LOCAL ROLE erp_table_owner;
REVOKE CREATE ON SCHEMA erp_private FROM erp_function_owner;
SET LOCAL ROLE erp_function_owner;
DO $m5_cleanup$
BEGIN
  IF pg_catalog.has_schema_privilege('erp_function_owner','erp_private','CREATE')
    OR (SELECT proowner FROM pg_catalog.pg_proc
        WHERE oid = 'erp_private.reactivate_ingredient(text)'::regprocedure) <> 'erp_function_owner'::regrole
    OR pg_catalog.has_function_privilege('anon','erp_private.reactivate_ingredient(text)','EXECUTE')
    OR pg_catalog.has_function_privilege('authenticated','erp_private.reactivate_ingredient(text)','EXECUTE')
    OR NOT pg_catalog.has_function_privilege('erp_admin_caller','erp_private.reactivate_ingredient(text)','EXECUTE') THEN
    RAISE EXCEPTION 'M5 unexpected ownership or privileges; roll back and inspect';
  END IF;
END;
$m5_cleanup$;
SET LOCAL ROLE postgres;
COMMIT;

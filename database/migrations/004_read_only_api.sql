-- PREPARED ONLY. M4; requires M3 and separate execution approval.
-- Creating views/grants DOES NOT configure or authorize Data API exposure.
-- Expose only after database permission review; release only after real REST tests.
BEGIN;
-- Exact P5-I1 administrator exception; no inferred platform grantor.
DO $m4_memberships$
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
$m4_memberships$;
DO $m4_defaults$
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
$m4_defaults$;
SET LOCAL ROLE erp_table_owner;
GRANT USAGE, CREATE ON SCHEMA erp_api TO erp_view_owner;
SET LOCAL ROLE erp_view_owner;
CREATE VIEW erp_api.inventory_balances WITH (security_barrier = true) AS
SELECT i.id AS ingredient_id, i.name AS ingredient_name, i.category, u.code AS unit_code,
  COALESCE(b.balance, 0::numeric) AS current_balance
FROM erp_private.ingredients AS i
JOIN erp_private.units AS u ON u.id = i.unit_id
LEFT JOIN (
  SELECT ingredient_id, SUM(CASE transaction_type WHEN 'INCOMING' THEN quantity ELSE -quantity END) AS balance
  FROM erp_private.inventory_transactions GROUP BY ingredient_id
) AS b ON b.ingredient_id = i.id
WHERE i.is_active;
CREATE VIEW erp_api.inventory_history WITH (security_barrier = true) AS
SELECT t.ledger_sequence, i.name AS ingredient_name, t.transaction_type, t.quantity,
  u.code AS unit_code, t.transaction_date, t.created_at
FROM erp_private.inventory_transactions AS t
JOIN erp_private.ingredients AS i ON i.id = t.ingredient_id
JOIN erp_private.units AS u ON u.id = i.unit_id;
REVOKE ALL ON erp_api.inventory_balances, erp_api.inventory_history FROM PUBLIC, anon, authenticated, erp_admin_caller;
GRANT SELECT ON erp_api.inventory_balances, erp_api.inventory_history TO anon;
SET LOCAL ROLE erp_table_owner;
GRANT USAGE ON SCHEMA erp_api TO anon;
GRANT USAGE ON SCHEMA erp_api TO erp_view_owner;
REVOKE CREATE ON SCHEMA erp_api FROM erp_view_owner;
SET LOCAL ROLE erp_view_owner;
DO $m4_cleanup$
BEGIN
  IF pg_catalog.has_schema_privilege('erp_view_owner','erp_api','CREATE') THEN
    RAISE EXCEPTION 'M4 temporary schema CREATE remains; roll back and inspect';
  END IF;
  IF (SELECT count(*) FROM pg_catalog.pg_class WHERE relnamespace='erp_api'::regnamespace AND relkind='v')<>2
    OR EXISTS (SELECT FROM pg_catalog.pg_class WHERE relnamespace='erp_api'::regnamespace AND relkind='v' AND relowner<>'erp_view_owner'::regrole) THEN
    RAISE EXCEPTION 'M4 unexpected view inventory or ownership';
  END IF;
END;
$m4_cleanup$;
SET LOCAL ROLE postgres;
-- Ordinary owner-rights semantics intentionally retained (not security_invoker).
-- Consumers must request explicit ORDER BY ledger_sequence for history.
COMMIT;

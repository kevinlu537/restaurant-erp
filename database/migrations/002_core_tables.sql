-- PREPARED ONLY. M2; requires M1 and separate execution approval.
BEGIN;
-- Exact P5-I1 administrator exception; no inferred platform grantor.
DO $m2_memberships$
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
$m2_memberships$;
DO $m2_defaults$
DECLARE v_kind "char";
BEGIN
  FOREACH v_kind IN ARRAY ARRAY['f'::"char",'r'::"char",'S'::"char"] LOOP
    IF EXISTS (SELECT FROM pg_catalog.aclexplode(COALESCE(
      (SELECT defaclacl FROM pg_catalog.pg_default_acl WHERE defaclrole='erp_table_owner'::regrole AND defaclnamespace=0 AND defaclobjtype=v_kind),
      pg_catalog.acldefault(v_kind,'erp_table_owner'::regrole))) a WHERE a.grantee<>'erp_table_owner'::regrole)
      OR EXISTS (SELECT FROM pg_catalog.pg_default_acl d CROSS JOIN LATERAL pg_catalog.aclexplode(d.defaclacl) a
        WHERE d.defaclrole='erp_table_owner'::regrole AND d.defaclobjtype=v_kind
        AND d.defaclnamespace IN ('erp_private'::regnamespace,'erp_api'::regnamespace) AND a.grantee<>'erp_table_owner'::regrole) THEN
      RAISE EXCEPTION 'Non-owner creator defaults for erp_table_owner; stop for separately approved remediation';
    END IF;
  END LOOP;
END;
$m2_defaults$;
SET LOCAL ROLE erp_table_owner;
SET LOCAL search_path = pg_catalog, pg_temp;

CREATE TABLE erp_private.units (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  code text NOT NULL UNIQUE,
  name text NOT NULL,
  unit_type text NOT NULL CHECK (unit_type IN ('WEIGHT', 'VOLUME', 'COUNT'))
);
CREATE TABLE erp_private.ingredients (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  name text NOT NULL,
  category text NOT NULL,
  unit_id uuid NOT NULL REFERENCES erp_private.units(id) ON DELETE RESTRICT,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  deactivated_at timestamptz,
  CONSTRAINT ingredient_name_normalized CHECK (
    name = pg_catalog.btrim(name, E' \t\n\r') AND name <> ''),
  CONSTRAINT ingredient_status_consistent CHECK (
    (is_active AND deactivated_at IS NULL) OR
    (NOT is_active AND deactivated_at IS NOT NULL))
);
-- Explicit C collation: ASCII case-insensitive comparison; no promise of
-- Unicode case folding, accent equivalence, or Unicode normalization.
-- Approved R01: non-ASCII names are allowed, without guaranteed non-ASCII
-- case equivalence. No Unicode normalization is introduced.
CREATE UNIQUE INDEX ingredients_normalized_name_key ON erp_private.ingredients
  (pg_catalog.lower(name COLLATE "C"));
CREATE INDEX ingredients_unit_idx ON erp_private.ingredients(unit_id);

CREATE TABLE erp_private.suppliers (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  name text NOT NULL,
  contact_email text,
  phone text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp()
);
CREATE SEQUENCE erp_private.erp_ledger_sequence AS bigint
  START WITH 1 INCREMENT BY 1 MINVALUE 1 NO MAXVALUE CACHE 1 NO CYCLE;
CREATE TABLE erp_private.inventory_transactions (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  ledger_sequence bigint NOT NULL UNIQUE CHECK (ledger_sequence > 0),
  ingredient_id uuid NOT NULL REFERENCES erp_private.ingredients(id) ON DELETE RESTRICT,
  supplier_id uuid REFERENCES erp_private.suppliers(id) ON DELETE RESTRICT,
  transaction_type text NOT NULL CHECK (transaction_type IN ('INCOMING', 'CONSUMPTION')),
  quantity numeric(12,2) NOT NULL CHECK (quantity > 0 AND quantity <= 9999999999.99),
  transaction_date date NOT NULL CHECK (pg_catalog.isfinite(transaction_date)),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT consumption_has_no_supplier CHECK (
    transaction_type <> 'CONSUMPTION' OR supplier_id IS NULL)
);
CREATE INDEX inventory_transactions_ingredient_sequence_idx
  ON erp_private.inventory_transactions(ingredient_id, ledger_sequence);
CREATE INDEX inventory_transactions_supplier_idx
  ON erp_private.inventory_transactions(supplier_id);

ALTER TABLE erp_private.units ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp_private.units FORCE ROW LEVEL SECURITY;
ALTER TABLE erp_private.ingredients ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp_private.ingredients FORCE ROW LEVEL SECURITY;
ALTER TABLE erp_private.suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp_private.suppliers FORCE ROW LEVEL SECURITY;
ALTER TABLE erp_private.inventory_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp_private.inventory_transactions FORCE ROW LEVEL SECURITY;

-- Explicit owner policy supports separately approved seed/maintenance work.
CREATE POLICY units_owner ON erp_private.units TO erp_table_owner USING (true) WITH CHECK (true);
CREATE POLICY ingredients_owner ON erp_private.ingredients TO erp_table_owner USING (true) WITH CHECK (true);
CREATE POLICY suppliers_owner ON erp_private.suppliers TO erp_table_owner USING (true) WITH CHECK (true);
CREATE POLICY ledger_owner ON erp_private.inventory_transactions TO erp_table_owner USING (true) WITH CHECK (true);
CREATE POLICY units_read ON erp_private.units FOR SELECT TO erp_view_owner, erp_function_owner USING (true);
CREATE POLICY ingredients_read ON erp_private.ingredients FOR SELECT TO erp_view_owner, erp_function_owner USING (true);
CREATE POLICY ledger_read ON erp_private.inventory_transactions FOR SELECT TO erp_view_owner, erp_function_owner USING (true);
CREATE POLICY suppliers_function_read ON erp_private.suppliers FOR SELECT TO erp_function_owner USING (true);
-- Locking reads need row visibility under UPDATE policy; actual UPDATE is
-- rejected by WITH CHECK. Verify this distinction on PostgreSQL 17.
CREATE POLICY units_function_lock ON erp_private.units FOR UPDATE TO erp_function_owner USING (true) WITH CHECK (false);
CREATE POLICY suppliers_function_lock ON erp_private.suppliers FOR UPDATE TO erp_function_owner USING (true) WITH CHECK (false);
CREATE POLICY ingredients_insert ON erp_private.ingredients FOR INSERT TO erp_function_owner WITH CHECK (is_active AND deactivated_at IS NULL);
CREATE POLICY ingredients_update ON erp_private.ingredients FOR UPDATE TO erp_function_owner USING (true) WITH CHECK (true);
CREATE POLICY ledger_insert ON erp_private.inventory_transactions FOR INSERT TO erp_function_owner WITH CHECK (true);

REVOKE ALL ON ALL TABLES IN SCHEMA erp_private FROM PUBLIC, anon, authenticated, erp_admin_caller;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA erp_private FROM PUBLIC, anon, authenticated, erp_admin_caller;
GRANT SELECT (id, code) ON erp_private.units TO erp_view_owner;
GRANT SELECT (id, name, category, unit_id, is_active) ON erp_private.ingredients TO erp_view_owner;
GRANT SELECT (ledger_sequence, ingredient_id, transaction_type, quantity, transaction_date, created_at)
  ON erp_private.inventory_transactions TO erp_view_owner;
GRANT SELECT (id, code, name, unit_type) ON erp_private.units TO erp_function_owner;
GRANT SELECT ON erp_private.ingredients, erp_private.inventory_transactions TO erp_function_owner;
GRANT SELECT (id, is_active) ON erp_private.suppliers TO erp_function_owner;
GRANT INSERT (name, category, unit_id) ON erp_private.ingredients TO erp_function_owner;
GRANT UPDATE (is_active, deactivated_at) ON erp_private.ingredients TO erp_function_owner;
-- Row-locking SELECT requires UPDATE on at least one column. These grants
-- confer no caller access; UPDATE policies reject actual new row values.
GRANT UPDATE (name) ON erp_private.units TO erp_function_owner;
GRANT UPDATE (is_active) ON erp_private.suppliers TO erp_function_owner;
GRANT INSERT (ledger_sequence, ingredient_id, supplier_id, transaction_type, quantity, transaction_date)
  ON erp_private.inventory_transactions TO erp_function_owner;
GRANT USAGE ON SEQUENCE erp_private.erp_ledger_sequence TO erp_function_owner;
COMMIT;

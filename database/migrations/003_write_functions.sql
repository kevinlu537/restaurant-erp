-- PREPARED ONLY. M3; requires M2 and separate execution approval.
-- P5-I1: direct owner creation with exact postgres administrative memberships.
-- Runtime privileges remain restricted. Requires Live Verification.
BEGIN;
-- Exact P5-I1 administrator exception; no inferred platform grantor.
DO $m3_memberships$
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
$m3_memberships$;
DO $m3_defaults$
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
$m3_defaults$;
SET LOCAL ROLE erp_table_owner;
-- Temporary owner creation authority; removed in this transaction.
GRANT CREATE ON SCHEMA erp_private TO erp_function_owner;
SET LOCAL ROLE erp_function_owner;

CREATE FUNCTION erp_private.create_ingredient(p_name text, p_category text, p_unit_id uuid)
RETURNS uuid LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  v_name text := pg_catalog.btrim(p_name, E' \t\n\r');
  v_id uuid;
BEGIN
  IF current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'READ COMMITTED isolation is required' USING ERRCODE = '22023';
  END IF;
  IF v_name IS NULL OR v_name = '' OR p_category IS NULL OR p_unit_id IS NULL THEN
    RAISE EXCEPTION 'Name, category and unit are required' USING ERRCODE = '22023';
  END IF;
  PERFORM u.id FROM erp_private.units AS u WHERE u.id = p_unit_id FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown unit' USING ERRCODE = '22023';
  END IF;
  INSERT INTO erp_private.ingredients(name, category, unit_id)
    VALUES (v_name, p_category, p_unit_id) RETURNING id INTO v_id;
  RETURN v_id;
END;
$function$;
REVOKE ALL ON FUNCTION erp_private.create_ingredient(text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION erp_private.create_ingredient(text, text, uuid) TO erp_admin_caller;

CREATE FUNCTION erp_private.record_inventory_transaction(
  p_ingredient_id uuid, p_transaction_type text, p_quantity_text text,
  p_transaction_date date, p_supplier_id uuid DEFAULT NULL)
RETURNS TABLE (transaction_id uuid, ledger_sequence_text text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  v_ingredient erp_private.ingredients%ROWTYPE;
  v_unit_code text;
  v_supplier_active boolean;
  v_quantity numeric;
  v_balance numeric;
  v_id uuid;
  v_sequence bigint;
BEGIN
  IF current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'READ COMMITTED isolation is required' USING ERRCODE = '22023';
  END IF;
  IF p_ingredient_id IS NULL OR p_transaction_type IS NULL OR p_transaction_date IS NULL
     OR NOT pg_catalog.isfinite(p_transaction_date) THEN
    RAISE EXCEPTION 'Ingredient, transaction type and finite business date are required' USING ERRCODE = '22023';
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
  IF p_transaction_type NOT IN ('INCOMING', 'CONSUMPTION') THEN
    RAISE EXCEPTION 'Invalid transaction type' USING ERRCODE = '22023';
  END IF;
  IF p_transaction_type = 'CONSUMPTION' AND p_supplier_id IS NOT NULL THEN
    RAISE EXCEPTION 'Consumption cannot have a supplier' USING ERRCODE = '22023';
  END IF;

  SELECT i.* INTO v_ingredient FROM erp_private.ingredients AS i
    WHERE i.id = p_ingredient_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown ingredient' USING ERRCODE = '22023';
  END IF;
  IF NOT v_ingredient.is_active THEN
    RAISE EXCEPTION 'Ingredient is inactive' USING ERRCODE = '22023';
  END IF;
  -- A separate statement after waiting for the ingredient lock is essential.
  SELECT COALESCE(SUM(CASE t.transaction_type WHEN 'INCOMING' THEN t.quantity ELSE -t.quantity END), 0)
    INTO v_balance FROM erp_private.inventory_transactions AS t WHERE t.ingredient_id = p_ingredient_id;
  -- Lock order: ingredient -> unit -> optional supplier. Keep until commit.
  SELECT u.code INTO v_unit_code FROM erp_private.units AS u
    WHERE u.id = v_ingredient.unit_id FOR SHARE;
  IF v_unit_code = 'each' AND v_quantity <> pg_catalog.trunc(v_quantity) THEN
    RAISE EXCEPTION 'Each quantities must be whole numbers' USING ERRCODE = '22023';
  END IF;
  IF p_supplier_id IS NOT NULL THEN
    SELECT s.is_active INTO v_supplier_active FROM erp_private.suppliers AS s
      WHERE s.id = p_supplier_id FOR SHARE;
    IF NOT FOUND OR NOT v_supplier_active THEN
      RAISE EXCEPTION 'Supplier is unknown or inactive' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF p_transaction_type = 'CONSUMPTION' AND v_quantity > v_balance THEN
    RAISE EXCEPTION 'Consumption exceeds available stock' USING ERRCODE = '23514';
  END IF;
  v_sequence := pg_catalog.nextval('erp_private.erp_ledger_sequence'::regclass);
  INSERT INTO erp_private.inventory_transactions
    (ledger_sequence, ingredient_id, supplier_id, transaction_type, quantity, transaction_date)
    VALUES (v_sequence, p_ingredient_id, p_supplier_id, p_transaction_type, v_quantity::numeric(12,2), p_transaction_date)
    RETURNING id INTO v_id;
  RETURN QUERY SELECT v_id, v_sequence::text;
END;
$function$;
REVOKE ALL ON FUNCTION erp_private.record_inventory_transaction(uuid, text, text, date, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION erp_private.record_inventory_transaction(uuid, text, text, date, uuid) TO erp_admin_caller;

CREATE FUNCTION erp_private.deactivate_ingredient(p_ingredient_id uuid)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE v_active boolean; v_balance numeric;
BEGIN
  IF current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'READ COMMITTED isolation is required' USING ERRCODE = '22023';
  END IF;
  SELECT i.is_active INTO v_active FROM erp_private.ingredients AS i
    WHERE i.id = p_ingredient_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown ingredient' USING ERRCODE = '22023'; END IF;
  IF NOT v_active THEN RAISE EXCEPTION 'Ingredient is already inactive' USING ERRCODE = '22023'; END IF;
  SELECT COALESCE(SUM(CASE t.transaction_type WHEN 'INCOMING' THEN t.quantity ELSE -t.quantity END), 0)
    INTO v_balance FROM erp_private.inventory_transactions AS t WHERE t.ingredient_id = p_ingredient_id;
  IF v_balance <> 0 THEN RAISE EXCEPTION 'Deactivation requires zero stock' USING ERRCODE = '23514'; END IF;
  UPDATE erp_private.ingredients SET is_active = false, deactivated_at = pg_catalog.clock_timestamp()
    WHERE id = p_ingredient_id;
END;
$function$;
REVOKE ALL ON FUNCTION erp_private.deactivate_ingredient(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION erp_private.deactivate_ingredient(uuid) TO erp_admin_caller;

-- Private trigger helpers enforce existing invariants, not new interfaces.
CREATE FUNCTION erp_private.guard_ingredient_unit() RETURNS trigger
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF NEW.unit_id IS DISTINCT FROM OLD.unit_id AND EXISTS (
    SELECT FROM erp_private.inventory_transactions WHERE ingredient_id = OLD.id) THEN
    RAISE EXCEPTION 'Historical ingredient unit is immutable' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$function$;
CREATE FUNCTION erp_private.guard_unit_definition() RETURNS trigger
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  -- Maintenance UPDATE/DELETE already locks the unit row. Writers hold SHARE.
  IF EXISTS (SELECT FROM erp_private.ingredients AS i
    JOIN erp_private.inventory_transactions AS t ON t.ingredient_id = i.id
    WHERE i.unit_id = OLD.id) THEN
    IF TG_OP = 'DELETE' THEN
      RAISE EXCEPTION 'Historical unit cannot be deleted' USING ERRCODE = '23514';
    END IF;
    IF ROW(NEW.id, NEW.code, NEW.name, NEW.unit_type) IS DISTINCT FROM ROW(OLD.id, OLD.code, OLD.name, OLD.unit_type) THEN
      RAISE EXCEPTION 'Historical unit definition is immutable' USING ERRCODE = '23514';
    END IF;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$function$;
CREATE FUNCTION erp_private.guard_ledger_mutation() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  RAISE EXCEPTION 'Inventory ledger is append-only' USING ERRCODE = '23514';
END;
$function$;
REVOKE ALL ON FUNCTION erp_private.guard_ingredient_unit(), erp_private.guard_unit_definition(), erp_private.guard_ledger_mutation()
  FROM PUBLIC, anon, authenticated, erp_admin_caller;
-- Table owner needs helper EXECUTE only while creating triggers.
GRANT EXECUTE ON FUNCTION erp_private.guard_ingredient_unit(), erp_private.guard_unit_definition(), erp_private.guard_ledger_mutation() TO erp_table_owner;
SET LOCAL ROLE erp_table_owner;
CREATE TRIGGER ingredients_unit_guard BEFORE UPDATE OF unit_id ON erp_private.ingredients
  FOR EACH ROW EXECUTE FUNCTION erp_private.guard_ingredient_unit();
CREATE TRIGGER units_definition_guard BEFORE UPDATE OR DELETE ON erp_private.units
  FOR EACH ROW EXECUTE FUNCTION erp_private.guard_unit_definition();
CREATE TRIGGER ledger_mutation_guard BEFORE UPDATE OR DELETE ON erp_private.inventory_transactions
  FOR EACH ROW EXECUTE FUNCTION erp_private.guard_ledger_mutation();
CREATE TRIGGER ledger_truncate_guard BEFORE TRUNCATE ON erp_private.inventory_transactions
  FOR EACH STATEMENT EXECUTE FUNCTION erp_private.guard_ledger_mutation();
SET LOCAL ROLE erp_function_owner;
REVOKE EXECUTE ON FUNCTION erp_private.guard_ingredient_unit(), erp_private.guard_unit_definition(), erp_private.guard_ledger_mutation() FROM erp_table_owner;
SET LOCAL ROLE erp_table_owner;
REVOKE CREATE ON SCHEMA erp_private FROM erp_function_owner;
SET LOCAL ROLE erp_function_owner;
DO $m3_cleanup$
BEGIN
  IF pg_catalog.has_schema_privilege('erp_function_owner','erp_private','CREATE')
    OR pg_catalog.has_function_privilege('erp_table_owner','erp_private.guard_ingredient_unit()','EXECUTE')
    OR pg_catalog.has_function_privilege('erp_table_owner','erp_private.guard_unit_definition()','EXECUTE')
    OR pg_catalog.has_function_privilege('erp_table_owner','erp_private.guard_ledger_mutation()','EXECUTE') THEN
    RAISE EXCEPTION 'M3 temporary grants remain; roll back and inspect';
  END IF;
  IF (SELECT count(*) FROM pg_catalog.pg_proc WHERE pronamespace='erp_private'::regnamespace)<>6
    OR EXISTS (SELECT FROM pg_catalog.pg_proc WHERE pronamespace='erp_private'::regnamespace AND proowner<>'erp_function_owner'::regrole) THEN
    RAISE EXCEPTION 'M3 unexpected routine inventory or ownership';
  END IF;
END;
$m3_cleanup$;
SET LOCAL ROLE postgres;
COMMIT;

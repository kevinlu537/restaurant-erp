-- PREPARED ONLY. M5: separate seed execution approval required after M1-M4.
-- Entire script is one transaction. Any existing business data is a STOP,
-- including a successful prior seed. Never delete data or reset sequences.
BEGIN ISOLATION LEVEL READ COMMITTED;
SET LOCAL ROLE erp_table_owner;
LOCK TABLE erp_private.units, erp_private.ingredients, erp_private.suppliers,
  erp_private.inventory_transactions IN ACCESS EXCLUSIVE MODE;
DO $preflight$
BEGIN
  IF EXISTS (SELECT FROM erp_private.units) OR EXISTS (SELECT FROM erp_private.ingredients)
    OR EXISTS (SELECT FROM erp_private.suppliers) OR EXISTS (SELECT FROM erp_private.inventory_transactions) THEN
    RAISE EXCEPTION 'Seed requires empty business tables; stop and inspect execution history';
  END IF;
END;
$preflight$;
INSERT INTO erp_private.units(id, code, name, unit_type) VALUES
  ('10000000-0000-4000-8000-000000000001', 'lb', 'Pound', 'WEIGHT'),
  ('10000000-0000-4000-8000-000000000002', 'pt', 'US Pint', 'VOLUME'),
  ('10000000-0000-4000-8000-000000000003', 'fl oz', 'US Fluid Ounce', 'VOLUME'),
  ('10000000-0000-4000-8000-000000000004', 'each', 'Each', 'COUNT');
INSERT INTO erp_private.suppliers(id, name, contact_email, phone) VALUES
  ('20000000-0000-4000-8000-000000000001', 'Fictional Demo Supply', 'inventory@example.invalid', NULL);

SET LOCAL ROLE erp_admin_caller;
DO $seed$
DECLARE v_id uuid; v_row record;
BEGIN
  FOR v_row IN SELECT * FROM (VALUES
    ('Beef', 'Meat', '10000000-0000-4000-8000-000000000001'::uuid, '27'),
    ('Chicken', 'Meat', '10000000-0000-4000-8000-000000000001'::uuid, '18.50'),
    ('Salmon', 'Seafood', '10000000-0000-4000-8000-000000000001'::uuid, '12'),
    ('Milk', 'Dairy', '10000000-0000-4000-8000-000000000002'::uuid, '8'),
    ('Cooking Oil', 'Pantry', '10000000-0000-4000-8000-000000000003'::uuid, '64'),
    ('Eggs', 'Dairy', '10000000-0000-4000-8000-000000000004'::uuid, '36')
  ) AS fixtures(name, category, unit_id, amount)
  LOOP
    v_id := erp_private.create_ingredient(v_row.name, v_row.category, v_row.unit_id);
    PERFORM erp_private.record_inventory_transaction(v_id, 'INCOMING', v_row.amount,
      DATE '2026-01-01', '20000000-0000-4000-8000-000000000001'::uuid);
  END LOOP;
END;
$seed$;

SET LOCAL ROLE erp_table_owner;
DO $verify$
BEGIN
  IF (SELECT count(*) FROM erp_private.ingredients) <> 6
    OR (SELECT count(*) FROM erp_private.inventory_transactions) <> 6
    OR EXISTS (
      SELECT 1 FROM (VALUES ('Beef', 27::numeric), ('Chicken', 18.50),
        ('Salmon', 12), ('Milk', 8), ('Cooking Oil', 64), ('Eggs', 36)) AS e(name, balance)
      LEFT JOIN erp_private.ingredients i ON i.name = e.name
      LEFT JOIN erp_private.inventory_transactions t ON t.ingredient_id = i.id
      GROUP BY e.name, e.balance HAVING COALESCE(SUM(t.quantity), 0) <> e.balance
    ) THEN
    RAISE EXCEPTION 'Seed verification failed; entire seed must roll back';
  END IF;
END;
$verify$;
COMMIT;

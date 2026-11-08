-- PREPARED ONLY. PostgreSQL 17 / Supabase: Requires Live Verification.
-- M1. Separate execution approval required. Stop on the first error.
-- Run once, using an approved administrator able to create roles, assign owners,
-- SET ROLE to the ERP owners, and configure their default privileges.
-- Do not substitute platform roles or silently reuse existing ERP objects.
BEGIN;
DO $identity$
BEGIN
  IF session_user <> 'postgres' OR current_user <> 'postgres' THEN
    RAISE EXCEPTION 'M1 requires the approved postgres session and effective identity';
  END IF;
  IF NULLIF(pg_catalog.current_setting('erp_migration.platform_grantor', true), '') IS NULL THEN
    RAISE EXCEPTION 'M1 requires separately verified erp_migration.platform_grantor input before execution';
  END IF;
END;
$identity$;
DO $preflight$
DECLARE v_kind "char";
BEGIN
  -- Schema-local REVOKE cannot cancel global default PUBLIC EXECUTE.
  -- M0 must review the executor's defaults; do not change unrelated defaults.
  FOREACH v_kind IN ARRAY ARRAY['f'::"char",'r'::"char",'S'::"char"] LOOP
  IF EXISTS (
    SELECT FROM pg_catalog.aclexplode(COALESCE(
      (SELECT defaclacl FROM pg_catalog.pg_default_acl
       WHERE defaclrole = current_user::regrole AND defaclnamespace = 0 AND defaclobjtype = v_kind),
      pg_catalog.acldefault(v_kind, current_user::regrole))) AS a
    WHERE a.grantee <> current_user::regrole
  ) THEN
    RAISE EXCEPTION 'Executor global defaults must be owner-only (kind %); resolve in approved M0 review', v_kind;
  END IF;
  END LOOP;
  IF current_setting('server_version_num')::integer / 10000 <> 17 THEN
    RAISE EXCEPTION 'PostgreSQL 17 is required; compatibility review needed';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'anon')
     OR NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'authenticated') THEN
    RAISE EXCEPTION 'Expected Supabase API roles are missing';
  END IF;
END;
$preflight$;

CREATE ROLE erp_table_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
CREATE ROLE erp_view_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
CREATE ROLE erp_function_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
-- No password or credential provisioning is included. Login feasibility is gated.
CREATE ROLE erp_admin_caller LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;

-- Exact P5-I1 administrator exception; no inferred platform grantor.
DO $creator_memberships$
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
$creator_memberships$;
-- Proposed SET grant capability must be live-verified separately before M1.
-- Preserve the platform-granted ADMIN rows; never revoke or rewrite them.
GRANT erp_table_owner, erp_view_owner, erp_function_owner, erp_admin_caller
  TO postgres WITH ADMIN FALSE, INHERIT FALSE, SET TRUE GRANTED BY postgres;
-- Exact P5-I1 administrator exception; no inferred platform grantor.
DO $administrator_memberships$
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
$administrator_memberships$;
CREATE SCHEMA erp_private AUTHORIZATION erp_table_owner;
CREATE SCHEMA erp_api AUTHORIZATION erp_table_owner;
SET LOCAL ROLE erp_table_owner;
REVOKE ALL ON SCHEMA erp_private, erp_api FROM PUBLIC, anon, authenticated, erp_admin_caller;
GRANT USAGE ON SCHEMA erp_private TO erp_view_owner, erp_function_owner, erp_admin_caller;
-- Only postgres holds the exact administrative memberships; no runtime CREATE.

SET LOCAL ROLE erp_table_owner;
ALTER DEFAULT PRIVILEGES FOR ROLE erp_table_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
SET LOCAL ROLE erp_function_owner;
ALTER DEFAULT PRIVILEGES FOR ROLE erp_function_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
SET LOCAL ROLE erp_view_owner;
ALTER DEFAULT PRIVILEGES FOR ROLE erp_view_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
SET LOCAL ROLE erp_table_owner;
ALTER DEFAULT PRIVILEGES FOR ROLE erp_table_owner REVOKE ALL ON TABLES FROM PUBLIC, anon, authenticated, erp_admin_caller;
ALTER DEFAULT PRIVILEGES FOR ROLE erp_table_owner REVOKE ALL ON SEQUENCES FROM PUBLIC, anon, authenticated, erp_admin_caller;
SET LOCAL ROLE erp_view_owner;
ALTER DEFAULT PRIVILEGES FOR ROLE erp_view_owner REVOKE ALL ON TABLES FROM PUBLIC, anon, authenticated, erp_admin_caller;
SET LOCAL ROLE postgres;
-- Fresh schemas have no executor schema-default additions; verify, never repair
-- unrelated executor defaults or rely on inherited schema-owner authority.
-- Exact P5-I1 administrator exception; no inferred platform grantor.
DO $final_memberships$
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
$final_memberships$;
DO $final_foundations$
DECLARE v_role text; v_kind "char"; v_schema text;
BEGIN
  IF EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname IN ('erp_table_owner','erp_view_owner','erp_function_owner','erp_admin_caller')
    AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolinherit OR rolreplication OR rolbypassrls
      OR rolcanlogin <> (rolname='erp_admin_caller'))) THEN
    RAISE EXCEPTION 'M1 unexpected ERP role attributes';
  END IF;
  FOREACH v_schema IN ARRAY ARRAY['erp_private','erp_api'] LOOP
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_namespace WHERE nspname=v_schema AND nspowner='erp_table_owner'::regrole) THEN
      RAISE EXCEPTION 'M1 wrong schema owner: %', v_schema;
    END IF;
    IF EXISTS (SELECT FROM pg_catalog.pg_namespace n CROSS JOIN LATERAL pg_catalog.aclexplode(n.nspacl) a
      WHERE n.nspname=v_schema AND a.grantee=0) THEN
      RAISE EXCEPTION 'M1 PUBLIC schema grant: %', v_schema;
    END IF;
    FOREACH v_role IN ARRAY ARRAY['anon','authenticated','erp_admin_caller','erp_view_owner','erp_function_owner'] LOOP
      IF pg_catalog.has_schema_privilege(v_role,v_schema,'CREATE')
        OR pg_catalog.has_schema_privilege(v_role,v_schema,'USAGE') <>
          (v_schema='erp_private' AND v_role IN ('erp_admin_caller','erp_view_owner','erp_function_owner')) THEN
        RAISE EXCEPTION 'M1 unexpected schema privilege: % %', v_schema, v_role;
      END IF;
    END LOOP;
  END LOOP;
  FOREACH v_role IN ARRAY ARRAY['postgres','erp_table_owner','erp_view_owner','erp_function_owner'] LOOP
    FOREACH v_kind IN ARRAY ARRAY['f'::"char",'r'::"char",'S'::"char"] LOOP
      IF EXISTS (SELECT FROM pg_catalog.aclexplode(COALESCE(
        (SELECT defaclacl FROM pg_catalog.pg_default_acl WHERE defaclrole=v_role::regrole AND defaclnamespace=0 AND defaclobjtype=v_kind),
        pg_catalog.acldefault(v_kind,v_role::regrole))) a WHERE a.grantee<>v_role::regrole)
        OR EXISTS (SELECT FROM pg_catalog.pg_default_acl d CROSS JOIN LATERAL pg_catalog.aclexplode(d.defaclacl) a
          WHERE d.defaclrole=v_role::regrole AND d.defaclobjtype=v_kind
          AND d.defaclnamespace IN ('erp_private'::regnamespace,'erp_api'::regnamespace) AND a.grantee<>v_role::regrole) THEN
        RAISE EXCEPTION 'M1 non-owner default ACL: % %; stop for separately approved remediation',v_role,v_kind;
      END IF;
    END LOOP;
  END LOOP;
END;
$final_foundations$;
COMMIT;

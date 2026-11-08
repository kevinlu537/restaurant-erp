import { createInventoryHandler, createPostgresConnector } from "./handler.ts";
export { createInventoryHandler, createPostgresConnector } from "./handler.ts";

// No connection string is read and no database client is created at startup.
// Configure these names through server secrets only; never use browser config.
  const handler = createInventoryHandler({
    frontendOrigin: Deno.env.get("ERP_FRONTEND_ORIGIN"),
    projectUrl: Deno.env.get("ERP_PROJECT_URL"),
    publishableKey: Deno.env.get("ERP_PUBLISHABLE_KEY"),
    allowedUserIds: Deno.env.get("ERP_ALLOWED_USER_IDS"),
    writesEnabled: Deno.env.get("ERP_WRITES_ENABLED")
  }, createPostgresConnector(() => ({
    databaseUrl: Deno.env.get("ERP_CALLER_DATABASE_URL"),
    approvedHost: Deno.env.get("ERP_APPROVED_POOLER_HOST"),
    projectRef: Deno.env.get("ERP_PROJECT_REF"),
    caCert: Deno.env.get("ERP_DATABASE_CA_CERT")
  })));
  Deno.serve(handler);

import postgres from "postgres";

// Authenticated inventory writes. Driver is pinned in this function's deno.json.
export function createInventoryHandler(config, connect, verifyFetch = fetch) {
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
  const units = new Set([1,2,3,4].map(n => "10000000-0000-4000-8000-00000000000" + n));
  let origin, project, users;
  try {
    origin = new URL(config.frontendOrigin);
    project = new URL(config.projectUrl);
    users = JSON.parse(config.allowedUserIds);
    if (origin.protocol !== "https:" || origin.origin !== config.frontendOrigin ||
        project.protocol !== "https:" || project.origin !== config.projectUrl ||
        !/^[a-z0-9-]+\.supabase\.co$/.test(project.hostname) ||
        !/^sb_publishable_[A-Za-z0-9_-]+$/.test(config.publishableKey) ||
        !Array.isArray(users) || !users.length || users.some(id => typeof id !== "string" || !uuid.test(id)) ||
        new Set(users).size !== users.length) throw new Error("Invalid server configuration.");
  } catch { origin = null; }
  return async function handler(request) {
    const approvedOrigin = origin && request.headers.get("origin") === origin.origin;
    const headers = { "Content-Type": "application/json", "Cache-Control": "no-store", Vary: "Origin" };
    if (approvedOrigin) Object.assign(headers, { "Access-Control-Allow-Origin": origin.origin,
      "Access-Control-Allow-Methods": "POST, OPTIONS", "Access-Control-Allow-Headers": "authorization, apikey, content-type" });
    const reply = (status, outcome, message, result?: unknown) => new Response(JSON.stringify({ ok: status === 200,
      outcome, message, ...(result ? { result } : {}) }), { status, headers });
    if (!origin) return reply(503, "REJECTED", "Write service is not configured.");
    if (!approvedOrigin) return reply(403, "REJECTED", "Origin not allowed.");
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers });
    if (request.method !== "POST") return reply(405, "REJECTED", "Method not allowed.");
    const authorization = request.headers.get("authorization") || "";
    if (!/^Bearer [A-Za-z0-9_.-]+$/.test(authorization) || authorization.length > 8192)
      return reply(401, "REJECTED", "Sign in required.");
    const controller = new AbortController();
    const authTimer = setTimeout(() => controller.abort(), 10000);
    try {
      const response = await verifyFetch(project.origin + "/auth/v1/user", { method: "GET", redirect: "error",
        credentials: "omit", signal: controller.signal,
        headers: { apikey: config.publishableKey, Authorization: authorization } });
      if (!response.ok) return reply(401, "REJECTED", "Session not accepted.");
      const user = await response.json();
      if (typeof user.id !== "string" || !users.includes(user.id)) return reply(403, "REJECTED", "Operator not authorized.");
    } catch { return reply(401, "REJECTED", "Session verification unavailable."); }
    finally { clearTimeout(authTimer); }
    // Only the exact server-configured string enables writes; HTTP input is ignored.
    if (config.writesEnabled !== "true") return reply(503, "REJECTED", "Inventory writes are disabled.");
    let payload;
    try {
      if (!(request.headers.get("content-type") || "").toLowerCase().startsWith("application/json")) throw new Error();
      const reader = request.body?.getReader();
      if (!reader) throw new Error();
      const chunks = []; let size = 0;
      const bodyTimer = setTimeout(() => { reader.cancel().catch(() => {}); }, 5000);
      try {
        while (true) { const part = await reader.read(); if (part.done) break;
          size += part.value.byteLength; if (size > 8192) { await reader.cancel(); throw new Error(); } chunks.push(part.value); }
      } finally { clearTimeout(bodyTimer); reader.releaseLock(); }
      const bytes = new Uint8Array(size); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
      payload = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
      if (!payload || Array.isArray(payload) || typeof payload !== "object") throw new Error();
    } catch { return reply(400, "REJECTED", "Invalid request body."); }
    const action = payload.action;
    let sql, args, fields;
    const string = (value, max) => typeof value === "string" && value.length > 0 && value.length <= max;
    if (action === "add_ingredient") {
      fields = ["action","name","category","unit_id"];
      if (!string(payload.name,200) || !string(payload.category,200) || !units.has(payload.unit_id))
        return reply(400,"REJECTED","Check ingredient fields.");
      sql = "SELECT erp_private.create_ingredient($1::text,$2::text,$3::uuid)::text AS ingredient_id";
      args = [payload.name,payload.category,payload.unit_id];
    } else if (action === "receive_stock" || action === "consume_stock") {
      fields = ["action","ingredient_id","quantity","date"];
      if (!uuid.test(payload.ingredient_id) || !string(payload.quantity,128) ||
          !/^\d+(?:\.\d{1,2})?$/.test(payload.quantity) || !/^\d{4}-\d{2}-\d{2}$/.test(payload.date))
        return reply(400,"REJECTED","Check transaction fields.");
      sql = "SELECT transaction_id::text,ledger_sequence_text FROM erp_private.record_inventory_transaction($1::uuid,$2::text,$3::text,$4::date,$5::uuid)";
      args = [payload.ingredient_id,action === "receive_stock" ? "INCOMING" : "CONSUMPTION",payload.quantity,payload.date,null];
    } else if (action === "deactivate_ingredient") {
      fields = ["action","ingredient_id"];
      if (!uuid.test(payload.ingredient_id)) return reply(400,"REJECTED","Choose an ingredient.");
      sql = "SELECT erp_private.deactivate_ingredient($1::uuid)"; args = [payload.ingredient_id];
    } else return reply(400,"REJECTED","Action not supported.");
    if (Object.keys(payload).some(key => !fields.includes(key)) || fields.some(key => !Object.hasOwn(payload,key)))
      return reply(400,"REJECTED","Unexpected request fields.");
    if (typeof connect !== "function") return reply(503,"REJECTED","Database connector is not available.");
    let db, began = false, committing = false;
    try {
      db = await connect();
      await db.query("BEGIN ISOLATION LEVEL READ COMMITTED", []); began = true;
      await db.query("SET LOCAL statement_timeout = '5s'", []);
      const identity = await db.query("SELECT session_user::text AS session_identity,current_user::text AS effective_identity", []);
      if (identity.rows.length !== 1 || identity.rows[0].session_identity !== "erp_admin_caller" ||
          identity.rows[0].effective_identity !== "erp_admin_caller") throw new Error("Restricted identity required.");
      const output = await db.query(sql,args);
      if (output.rows.length !== 1) throw new Error("Unexpected result count.");
      let result = {};
      if (action === "add_ingredient") {
        if (!uuid.test(output.rows[0].ingredient_id)) throw new Error("Invalid return.");
        result = { ingredient_id: output.rows[0].ingredient_id };
      } else if (action !== "deactivate_ingredient") {
        const item = output.rows[0];
        if (!uuid.test(item.transaction_id) || typeof item.ledger_sequence_text !== "string" || !/^[1-9]\d*$/.test(item.ledger_sequence_text)) throw new Error("Invalid return.");
        result = { transaction_id: item.transaction_id, ledger_sequence_text: item.ledger_sequence_text };
      }
      committing = true;
      await db.query("COMMIT", []);
      return reply(200,"COMMITTED","Inventory change confirmed.",result);
    } catch (error) {
      let rolledBack = false;
      if (db && began) { try { await db.query("ROLLBACK", []); rolledBack = true; } catch { /* Outcome stays unknown. */ } }
      if (committing || !rolledBack && began) return reply(503,"UNKNOWN","Outcome unknown. Reconcile before retry.");
      if (!began) return reply(503,"REJECTED","Write connection unavailable.");
      const business = ["22023","23514","23505","22007","22008"].includes(error?.code);
      return reply(business ? 409 : 503,"ROLLED_BACK",business ? "Change violates an inventory rule." : "Write failed and was rolled back.");
    } finally { if (db) { try { await db.close(); } catch { /* Never leak connection details. */ } } }
  };
}

// One active write per Edge isolate; clients are created only after authorization.
// Supabase npm dependencies: https://supabase.com/docs/guides/functions/dependencies
// Driver API: https://github.com/porsager/postgres/tree/v3.4.7#reserving-connections
export function createPostgresConnector(getConnectionConfig, driver = postgres) {
  let busy = false;
  return async function connect() {
    if (busy) throw new Error("Write connection busy.");
    busy = true;
    let client, reserved, ended, broken = false, closed = false;
    const end = () => {
      if (!ended) ended = client ? client.end({ timeout: 0 }) : Promise.resolve();
      return ended;
    };
    try {
      // Independent Dashboard-derived server configuration, never request fields.
      const { databaseUrl, approvedHost, projectRef, caCert } = getConnectionConfig();
      const normalizeHost = (host) => {
        if (typeof host !== "string" || host.length > 253 ||
            !host.split(".").every(label => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label)))
          throw new Error("Invalid approved session-pooler host.");
        const normalized = host.toLowerCase();
        // Domain restriction is not approval: exact equality is required below.
        if (!normalized.endsWith(".pooler.supabase.com") || normalized.split(".").includes("localhost"))
          throw new Error("Invalid approved session-pooler host.");
        return normalized;
      };
      const trustedHost = normalizeHost(approvedHost);
      if (typeof projectRef !== "string" || !/^[a-z0-9]{1,63}$/.test(projectRef) ||
          typeof databaseUrl !== "string" || /[\u0000-\u0020\u007f]/.test(databaseUrl))
        throw new Error("Invalid restricted connection configuration.");
      const url = new URL(databaseUrl);
      const user = decodeURIComponent(url.username);
      const password = decodeURIComponent(url.password);
      if (!["postgres:", "postgresql:"].includes(url.protocol) || !password ||
          normalizeHost(url.hostname) !== trustedHost || url.port !== "5432" ||
          user !== "erp_admin_caller." + projectRef || url.pathname !== "/postgres" ||
          url.search || url.hash) throw new Error("Approved session-pooler connection required.");
      // Omitted CA uses runtime trust roots. A supplied bundle must be PEM only;
      // the TLS implementation validates certificates, trust, expiry and hostname.
      if (caCert !== undefined && (typeof caCert !== "string" || caCert.length > 65536 ||
          !/^(?:\s*-----BEGIN CERTIFICATE-----\s+[A-Za-z0-9+/=\s]+\s+-----END CERTIFICATE-----\s*)+$/.test(caCert)))
        throw new Error("Invalid database CA configuration.");
      client = driver(databaseUrl, {
        max: 1, prepare: false,
        ssl: { rejectUnauthorized: true, servername: trustedHost,
          ...(caCert === undefined ? {} : { ca: caCert }) },
        connect_timeout: 5,
        idle_timeout: 5, max_lifetime: 30, debug: false, onnotice: () => {},
        onclose: () => { broken = true; }
      });
      reserved = await client.reserve();
      return {
        async query(text, parameters) {
          if (closed || broken) throw new Error("Write connection unavailable.");
          let timer;
          try {
            const deadline = new Promise((_, reject) => {
              timer = setTimeout(() => {
                broken = true;
                end().catch(() => {});
                reject(new Error("Write query outcome unavailable."));
              }, 10000);
            });
            // Only fixed handler SQL reaches this internal adapter. Values stay separate.
            const rows = await Promise.race([reserved.unsafe(text, parameters), deadline]);
            if (broken) throw new Error("Write connection interrupted.");
            return { rows };
          } finally { clearTimeout(timer); }
        },
        async close() {
          if (closed) return;
          closed = true;
          try { await reserved.release(); }
          finally { try { await end(); } finally { busy = false; } }
        }
      };
    } catch {
      try { if (reserved) await reserved.release(); }
      finally { try { await end(); } finally { busy = false; } }
      throw new Error("Restricted write connection unavailable.");
    }
  };
}


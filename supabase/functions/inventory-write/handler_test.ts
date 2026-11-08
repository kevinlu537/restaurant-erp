import { createInventoryHandler, createPostgresConnector } from "./handler.ts";

// All identities and endpoints are synthetic. Deno tests run without network/env access.
function assert(value: unknown, message = "Assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
function equal(actual: unknown, expected: unknown) {
  assert(JSON.stringify(actual) === JSON.stringify(expected), "Values differ");
}
const operator = "11111111-1111-4111-8111-111111111111";
const ingredient = "22222222-2222-4222-8222-222222222222";
const unit = "10000000-0000-4000-8000-000000000004";
const origin = "https://frontend.invalid";
const baseConfig = { frontendOrigin: origin, projectUrl: "https://synthetic.supabase.co",
  publishableKey: "sb_publishable_synthetic", allowedUserIds: JSON.stringify([operator]), writesEnabled: "true" };
const connectionConfig = { approvedHost: "synthetic.pooler.supabase.com", projectRef: "synthetic",
  databaseUrl: "postgresql://erp_admin_caller.synthetic:fake-only@synthetic.pooler.supabase.com:5432/postgres" };
const payloads = [
  { action: "add_ingredient", name: "Fictional'); not SQL", category: "Test", unit_id: unit },
  { action: "receive_stock", ingredient_id: ingredient, quantity: "12.50", date: "2026-01-02" },
  { action: "consume_stock", ingredient_id: ingredient, quantity: "3", date: "2026-01-02" },
  { action: "deactivate_ingredient", ingredient_id: ingredient }
];
function request(body: unknown = payloads[3], overrides: Record<string, string> = {}, method = "POST") {
  return new Request("https://function.invalid/inventory-write", { method,
    headers: { origin, authorization: "Bearer synthetic.token", "content-type": "application/json", ...overrides },
    ...(method === "POST" ? { body: JSON.stringify(body) } : {}) });
}
function harness(options: Record<string, any> = {}) {
  const state = { connected: 0, reserved: 0, released: 0, ended: 0,
    auth: 0, configReads: 0, statements: [] as { text: string; args: any[] }[], driverOptions: null as any };
  const driver = (_url, driverOptions) => {
    state.connected++; state.driverOptions = driverOptions;
    return {
      reserve: async () => {
        state.reserved++;
        if (options.reserveFailure) throw new Error("fake-only connection failure");
        return {
          unsafe: async (text, args) => {
            state.statements.push({ text, args });
            if (text.startsWith("SELECT session_user")) return [{ session_identity: options.identity || "erp_admin_caller", effective_identity: "erp_admin_caller" }];
            if (text === "COMMIT" && options.commitFailure) throw new Error("fake-only commit failure");
            if (text === "ROLLBACK" && options.rollbackFailure) throw new Error("fake-only rollback failure");
            if (text.includes("erp_private.")) {
              if (options.businessFailure) throw Object.assign(new Error("fake-only internal query/token/password"), { code: "23514" });
              if (text.includes("create_ingredient")) return [{ ingredient_id: ingredient }];
              if (text.includes("record_inventory_transaction")) return [{ transaction_id: ingredient,
                ledger_sequence_text: options.numericSequence ? 9007199254740992 : "9007199254740993" }];
              return [{}];
            }
            return [];
          },
          release: async () => { state.released++; }
        };
      },
      end: async () => { state.ended++; }
    };
  };
  const connect = createPostgresConnector(() => {
    state.configReads++;
    return { ...connectionConfig, ...options.connection };
  // This mock implements only the driver instance surface exercised by the adapter.
  }, driver as unknown as Parameters<typeof createPostgresConnector>[1]);
  const verify = async (url, init) => {
    state.auth++;
    equal(url, baseConfig.projectUrl + "/auth/v1/user");
    equal(init.method, "GET");
    equal(init.headers.apikey, baseConfig.publishableKey);
    equal(init.headers.Authorization, "Bearer synthetic.token");
    if (options.authFailure) return new Response("{}", { status: 401 });
    return new Response(JSON.stringify({ id: options.user || operator }));
  };
  const handler = createInventoryHandler({ ...baseConfig, ...options.config }, connect, verify);
  return { handler, state, connect };
}
function noDatabase(state) {
  equal(state.configReads, 0); equal(state.connected, 0); equal(state.statements, []);
}
Deno.test("missing token rejected before database", async () => {
  const h = harness(); equal((await h.handler(request(payloads[3], { authorization: "" }))).status, 401); noDatabase(h.state);
});
Deno.test("invalid token rejected before database", async () => {
  const h = harness({ authFailure: true }); equal((await h.handler(request())).status, 401); noDatabase(h.state);
});
Deno.test("non-allowlisted verified user rejected before database", async () => {
  const h = harness({ user: ingredient }); equal((await h.handler(request())).status, 403); noDatabase(h.state);
});
for (const list of [undefined, "[]", "not-json", JSON.stringify(["invalid-id"])]) {
  Deno.test("invalid allowlist fails closed: " + String(list), async () => {
    const h = harness({ config: { allowedUserIds: list } }); equal((await h.handler(request())).status, 503); noDatabase(h.state);
  });
}
Deno.test("approved CORS preflight has no Auth or database effects", async () => {
  const h = harness(); const response = await h.handler(request(payloads[3], {}, "OPTIONS"));
  equal(response.status, 204); equal(response.headers.get("access-control-allow-origin"), origin);
  equal(h.state.auth, 0); noDatabase(h.state);
});
Deno.test("unapproved origin rejected", async () => {
  const h = harness(); const response = await h.handler(request(payloads[3], { origin: "https://other.invalid" }));
  equal(response.status, 403); equal(response.headers.get("access-control-allow-origin"), null); noDatabase(h.state);
});
Deno.test("CORS approval is not authentication", async () => {
  const h = harness(); equal((await h.handler(request(payloads[3], { authorization: "" }))).status, 401); noDatabase(h.state);
});
for (const [actionIndex, routine] of [[0,"create_ingredient"],[1,"record_inventory_transaction"],[2,"record_inventory_transaction"],[3,"deactivate_ingredient"]] as const) {
  Deno.test("fixed action and transaction: " + payloads[actionIndex].action, async () => {
    const h = harness(); const response = await h.handler(request(payloads[actionIndex]));
    equal(response.status, 200); const body = await response.json(); equal(body.outcome, "COMMITTED");
    equal(h.state.connected, 1); equal(h.state.reserved, 1); equal(h.state.released, 1); equal(h.state.ended, 1);
    const statements = h.state.statements;
    equal(statements[0].text, "BEGIN ISOLATION LEVEL READ COMMITTED");
    equal(statements[1].text, "SET LOCAL statement_timeout = '5s'");
    assert(statements[2].text.startsWith("SELECT session_user"));
    const call = statements[3]; assert(call.text.includes("erp_private." + routine + "("));
    assert(call.text.startsWith("SELECT ")); assert(!/INSERT|UPDATE|DELETE|TRUNCATE/.test(call.text));
    equal(statements[4].text, "COMMIT"); equal(statements.length, 5);
    if (actionIndex === 0) {
      equal(call.text, "SELECT erp_private.create_ingredient($1::text,$2::text,$3::uuid)::text AS ingredient_id");
      equal(call.args, [payloads[0].name,"Test",unit]); assert(!call.text.includes(payloads[0].name));
    } else if (actionIndex === 1 || actionIndex === 2) {
      equal(call.text, "SELECT transaction_id::text,ledger_sequence_text FROM erp_private.record_inventory_transaction($1::uuid,$2::text,$3::text,$4::date,$5::uuid)");
      equal(call.args, [ingredient,actionIndex===1?"INCOMING":"CONSUMPTION",actionIndex===1?"12.50":"3","2026-01-02",null]);
      equal(body.result.ledger_sequence_text, "9007199254740993");
    } else equal(call.text, "SELECT erp_private.deactivate_ingredient($1::uuid)");
    equal(h.state.driverOptions.max,1); equal(h.state.driverOptions.prepare,false);
    equal(h.state.driverOptions.ssl, { rejectUnauthorized: true, servername: connectionConfig.approvedHost });
  });
}
for (const [name, patch] of [
  ["missing URL", { databaseUrl: undefined }],
  ["missing approved host", { approvedHost: undefined }],
  ["unapproved host", { databaseUrl: connectionConfig.databaseUrl.replace("@synthetic.","@different.") }],
  ["transaction port", { databaseUrl: connectionConfig.databaseUrl.replace(":5432",":6543") }],
  ["wrong pooled username", { databaseUrl: connectionConfig.databaseUrl.replace("erp_admin_caller.","postgres.") }],
  ["missing password", { databaseUrl: connectionConfig.databaseUrl.replace(":fake-only","") }]
] as const) {
  Deno.test("connection guard: " + name, async () => {
    const h = harness({ connection: patch }); const response = await h.handler(request());
    equal(response.status,503); equal((await response.json()).outcome,"REJECTED");
    equal(h.state.connected,0); equal(h.state.statements,[]);
  });
}
for (const [name, body] of [
  ["unknown action", { action: "arbitrary_sql" }],
  ["numeric quantity", { ...payloads[1], quantity: 0.1 }],
  ["malformed quantity", { ...payloads[1], quantity: "1e3" }],
  ["client user ID", { ...payloads[3], user_id: operator }],
  ["invalid ingredient ID", { ...payloads[3], ingredient_id: "invalid" }]
] as const) {
  Deno.test("invalid input: " + name, async () => {
    const h = harness(); equal((await h.handler(request(body as any))).status,400); noDatabase(h.state);
  });
}
Deno.test("bounded body rejects oversized input", async () => {
  const h = harness(); equal((await h.handler(request({ ...payloads[0], name: "x".repeat(9000) }))).status,400); noDatabase(h.state);
});
Deno.test("unsupported HTTP method", async () => {
  const h = harness(); equal((await h.handler(request(payloads[3],{},"GET"))).status,405); noDatabase(h.state);
});
Deno.test("business failure rolls back, closes and hides details", async () => {
  const h = harness({ businessFailure: true }); const response = await h.handler(request());
  equal(response.status,409); const body = await response.text(); assert(body.includes("ROLLED_BACK"));
  assert(!body.includes("fake-only") && !body.includes("erp_private") && !body.includes("password"));
  equal(h.state.statements.at(-1).text,"ROLLBACK"); equal(h.state.released,1); equal(h.state.ended,1);
});
Deno.test("wrong SQL identity rejected before M3", async () => {
  const h = harness({ identity: "postgres" }); const response = await h.handler(request());
  equal(response.status,503); equal((await response.json()).outcome,"ROLLED_BACK");
  assert(!h.state.statements.some(q => q.text.includes("erp_private."))); equal(h.state.ended,1);
});
Deno.test("ambiguous commit is UNKNOWN and never replayed", async () => {
  const h = harness({ commitFailure: true }); const response = await h.handler(request());
  equal(response.status,503); equal((await response.json()).outcome,"UNKNOWN");
  equal(h.state.statements.filter(q => q.text==="COMMIT").length,1);
  equal(h.state.statements.filter(q => q.text.includes("erp_private.")).length,1); equal(h.state.ended,1);
});
Deno.test("failed rollback remains UNKNOWN", async () => {
  const h = harness({ businessFailure: true, rollbackFailure: true });
  equal((await (await h.handler(request())).json()).outcome,"UNKNOWN"); equal(h.state.ended,1);
});
Deno.test("numeric sequence return rejected instead of rounded", async () => {
  const h = harness({ numericSequence: true }); const response = await h.handler(request(payloads[1]));
  equal((await response.json()).outcome,"ROLLED_BACK"); equal(h.state.statements.at(-1).text,"ROLLBACK");
});
Deno.test("failed reserve ends client without queries", async () => {
  const h = harness({ reserveFailure: true }); equal((await h.handler(request())).status,503);
  equal(h.state.ended,1); equal(h.state.statements,[]);
});
Deno.test("connector limits concurrent clients and closes idempotently", async () => {
  const h = harness(); const adapter = await h.connect(); let rejected = false;
  try { await h.connect(); } catch { rejected = true; }
  assert(rejected); equal(h.state.connected,1);
  await adapter.close(); await adapter.close(); equal(h.state.released,1); equal(h.state.ended,1);
});

for (const payload of payloads) {
  Deno.test("missing server write flag denies: " + payload.action, async () => {
    const h = harness({ config: { writesEnabled: undefined } });
    const response = await h.handler(request(payload));
    equal(response.status, 503); equal((await response.json()).outcome, "REJECTED");
    equal(h.state.auth, 1); noDatabase(h.state);
  });
}
for (const flag of ["false", "", "TRUE", " true", "true ", "1", "unexpected", true, null]) {
  Deno.test("non-exact server write flag denies: " + JSON.stringify(flag), async () => {
    const h = harness({ config: { writesEnabled: flag } });
    const response = await h.handler(request());
    equal(response.status, 503); equal((await response.json()).message, "Inventory writes are disabled.");
    noDatabase(h.state);
  });
}
Deno.test("HTTP input cannot override disabled server writes", async () => {
  const h = harness({ config: { writesEnabled: "false" } });
  const original = request({ ...payloads[3], writesEnabled: "true", ERP_WRITES_ENABLED: "true" },
    { "ERP_WRITES_ENABLED": "true", "writesEnabled": "true" });
  const response = await h.handler(new Request(original.url + "?ERP_WRITES_ENABLED=true&writesEnabled=true", original));
  equal(response.status, 503); noDatabase(h.state);
});
for (const [name, options, headers, status] of [
  ["missing token", {}, { authorization: "" }, 401],
  ["invalid token", { authFailure: true }, {}, 401],
  ["unapproved operator", { user: ingredient }, {}, 403]
] as const) {
  Deno.test("disabled writes preserve rejection: " + name, async () => {
    const h = harness({ ...options, config: { writesEnabled: undefined } });
    equal((await h.handler(request(payloads[3], headers))).status, status); noDatabase(h.state);
  });
}
Deno.test("publishable key alone is not user authorization", async () => {
  const h = harness();
  equal((await h.handler(request(payloads[3], { authorization: "", apikey: baseConfig.publishableKey }))).status, 401);
  equal(h.state.auth, 0); noDatabase(h.state);
});
for (const caCert of ["", "not a certificate", "-----BEGIN PRIVATE KEY-----", false]) {
  Deno.test("invalid server CA configuration fails closed: " + JSON.stringify(caCert), async () => {
    const h = harness({ connection: { caCert } });
    equal((await h.handler(request())).status, 503);
    equal(h.state.connected, 0); equal(h.state.statements, []);
  });
}
Deno.test("client TLS settings cannot reach the driver", async () => {
  const h = harness();
  equal((await h.handler(request({ ...payloads[3], ssl: false, caCert: "untrusted" }))).status, 400);
  noDatabase(h.state);
});
Deno.test("TLS reserve failure cleans up without SQL or insecure retry", async () => {
  const h = harness({ reserveFailure: true });
  const response = await h.handler(request());
  equal(response.status, 503); equal((await response.json()).outcome, "REJECTED");
  equal(h.state.connected, 1); equal(h.state.ended, 1); equal(h.state.statements, []);
  equal(h.state.driverOptions.ssl.rejectUnauthorized, true);
  equal(h.state.driverOptions.ssl.servername, connectionConfig.approvedHost);
});

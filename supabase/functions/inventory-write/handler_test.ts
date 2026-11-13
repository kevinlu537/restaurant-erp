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

// Edge validation parity only: the mocked database does not execute PostgreSQL.
for (const name of ["Potato", "POTATO", "  Potato  ", "Pot\tato", "Pot\nato",
  "Pot\rato", "Pot\u000bato", "Pot\u000cato", "Pot\u001bato", "Pot\u007fato",
  "\u00a0Potato\u00a0", "\u00a0", " \t\r\n ", "x".repeat(200), "\u{1f954}".repeat(100)]) {
  Deno.test("reactivation forwards Add-compatible name: " + JSON.stringify(name), async () => {
    const add = harness();
    equal((await add.handler(request({ ...payloads[0], name }))).status, 200);
    const h = harness();
    const response = await h.handler(request({ action: "reactivate_ingredient", name }));
    equal(response.status, 200);
    equal((await response.json()).result.ingredient_id, ingredient);
    const call = h.state.statements.find(item => item.text.includes("erp_private.reactivate_ingredient("));
    equal(call?.text, "SELECT erp_private.reactivate_ingredient($1::text)::text AS ingredient_id");
    equal(call?.args, [name]);
  });
}
for (const name of ["", null, 42, "x".repeat(201), "\u{1f954}".repeat(101)]) {
  Deno.test("reactivation rejects invalid Edge name: " + JSON.stringify(name), async () => {
    for (const body of [{ ...payloads[0], name }, { action: "reactivate_ingredient", name }]) {
      const h = harness();
      equal((await h.handler(request(body))).status, 400);
      noDatabase(h.state);
    }
  });
}
// Whitespace passes Add's Edge check; SQL is responsible for trimmed-empty rejection.
Deno.test("reactivation propagates mocked SQL name rejection without success", async () => {
  const h = harness({ businessFailure: true });
  const response = await h.handler(request({ action: "reactivate_ingredient", name: " \t\r\n " }));
  equal(response.status, 409);
  equal((await response.json()).outcome, "ROLLED_BACK");
});
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
              if (options.businessFailure) throw Object.assign(new Error("fake-only internal query/token/password"), { code: options.businessCode || "23514" });
              if (text.includes("list_receipt_expirations")) return [{ page_json: JSON.stringify(options.receiptPage || { total: "0", rows: [] }) }];
              if (text.includes("create_ingredient") || text.includes("reactivate_ingredient")) return [{ ingredient_id: ingredient }];
              if (text.includes("record_inventory_transaction") || text.includes("record_waste") || text.includes("record_receipt_v1")) return [{ transaction_id: ingredient,
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
const wastePayload = { action: "record_waste", ingredient_id: ingredient, quantity: "1.25", reason: "spoiled" };
const expiryReceipt = { ...payloads[1], expires_on: "2026-01-09" };
for (const expires_on of ["2026-01-09", "2026-01-02", null]) {
  Deno.test("Expiry E02 E03 E21 E22 atomic routing: " + expires_on, async () => {
    const h = harness(); const response = await h.handler(request({ ...expiryReceipt, expires_on }));
    equal(response.status,200); equal((await response.json()).outcome,"COMMITTED");
    const calls=h.state.statements.filter(s=>s.text.includes("erp_private."));
    equal(calls.length,1);assert(calls[0].text.includes("record_receipt_v1"));
    equal(calls[0].args,[ingredient,"12.50","2026-01-02",expires_on]);
  });
}
for (const patch of [{ expires_on:"2026-02-30" },{ expires_on:"2026-01-01" },{ expires_on:"infinity" },
  { expires_on:"2026-01-09T00:00:00Z" },{ ingredient_id:"bad" },{ quantity:"0" },{ quantity:"-1" },
  { quantity:"1.001" },{ quantity:"10000000000" },{ recorded_by:operator }]) {
  Deno.test("Expiry E04-E08 invalid input: " + JSON.stringify(patch), async () => {
    const h=harness();equal((await h.handler(request({...expiryReceipt,...patch}))).status,400);noDatabase(h.state);
  });
}
for (const offset of [0,500,49500]) {
  Deno.test("Expiry E14 E17 protected read with writes disabled: " + offset, async () => {
    const h=harness({config:{writesEnabled:"false"}});
    const response=await h.handler(request({action:"list_receipt_expirations",offset}));
    equal(response.status,200);equal((await response.json()).outcome,"READ");
    equal(h.state.statements[0].text,"BEGIN ISOLATION LEVEL READ COMMITTED READ ONLY");
    equal(h.state.statements[3].args,[offset]);
    assert(h.state.statements[3].text.includes("list_receipt_expirations"));
  });
}
for (const offset of [-1,1,50000,"0",null,0.5]) {
  Deno.test("Expiry E18 rejects page: " + JSON.stringify(offset), async () => {
    const h=harness({config:{writesEnabled:"false"}});
    equal((await h.handler(request({action:"list_receipt_expirations",offset}))).status,400);noDatabase(h.state);
  });
}
for (const [name,options,status,outcome] of [
  ["E09 fractional each",{businessFailure:true,businessCode:"22023"},409,"ROLLED_BACK"],
  ["E10 disabled receipt",{config:{writesEnabled:"false"}},503,"REJECTED"],
  ["E11 auth",{authFailure:true},401,"REJECTED"],
  ["E12 operator",{user:ingredient},403,"REJECTED"],
  ["E19 SQL",{businessFailure:true,businessCode:"XX000"},503,"ROLLED_BACK"],
  ["E20 ambiguity",{commitFailure:true},503,"UNKNOWN"]
] as const) {
  Deno.test("Expiry receipt boundary " + name, async () => {
    const h=harness(options);const response=await h.handler(request(expiryReceipt));
    equal(response.status,status);equal((await response.json()).outcome,outcome);
  });
}
for (const [name,options,status] of [
  ["E13 Auth",{authFailure:true},401],["E15 operator",{user:ingredient},403],
  ["E16 caller",{identity:"postgres"},503],["E19 read SQL",{businessFailure:true},503],
  ["read COMMIT failure",{commitFailure:true},503]
] as const) {
  Deno.test("Expiry read boundary " + name, async () => {
    const h=harness({...options,config:{writesEnabled:"false"}});
    const response=await h.handler(request({action:"list_receipt_expirations",offset:0}));
    equal(response.status,status);assert((await response.json()).outcome!=="UNKNOWN");
    if(status===401||status===403)noDatabase(h.state);
  });
}
Deno.test("Expiry read strips accidental private fields",async()=>{
  const h=harness({receiptPage:{total:"1",rows:[{receipt_id:ingredient,recorded_by:operator,email:"private@example.invalid"}]}});
  const body=await (await h.handler(request({action:"list_receipt_expirations",offset:0}))).json();
  assert(!JSON.stringify(body).includes(operator));assert(!JSON.stringify(body).includes("private@example.invalid"));
});
for (const reason of ["spoiled", "damaged", "other"]) {
  Deno.test("E01 E02 E21 E23 E24 waste dispatch: " + reason, async () => {
    const h = harness(); const response = await h.handler(request({ ...wastePayload, reason }));
    equal(response.status,200); const data = await response.json();
    equal(data.result.transaction_id,ingredient); equal(data.result.ledger_sequence_text,"9007199254740993");
    const calls = h.state.statements.filter(s => s.text.includes("erp_private."));
    equal(calls.length,1);
    equal(calls[0].text,"SELECT transaction_id::text,ledger_sequence_text FROM erp_private.record_waste($1::uuid,$2::text,$3::text,$4::uuid)");
    equal(calls[0].args,[ingredient,"1.25",reason,operator]);
  });
}
for (const [name, patch] of [
  ["E03 invalid reason", { reason: "Spoiled" }], ["E04 missing reason", { reason: undefined }],
  ["E05 zero", { quantity: "0.00" }], ["E06 negative", { quantity: "-1" }],
  ["E07 maximum", { quantity: "10000000000" }], ["E08 precision", { quantity: "1.001" }],
  ["E09 missing ingredient", { ingredient_id: undefined }], ["E10 malformed UUID", { ingredient_id: "bad" }],
  ["E11 actor", { recorded_by: operator }], ["E11 user", { user_id: operator }],
  ["E12 date", { date: "2026-01-01" }], ["E12 timestamp", { timestamp: "2026-01-01" }],
  ["E13 unit", { unit: "lb" }], ["E13 supplier", { supplier_id: ingredient }],
  ["missing quantity", { quantity: undefined }], ["numeric quantity", { quantity: 1 }],
  ["Infinity", { quantity: "Infinity" }], ["unknown action", { action: "waste_sql" }]
] as const) {
  Deno.test("Waste input " + name, async () => {
    const h = harness(); equal((await h.handler(request({ ...wastePayload, ...patch }))).status,400); noDatabase(h.state);
  });
}
for (const [name, options, status, outcome] of [
  ["E14 unauthenticated", { authFailure: true },401,"REJECTED"],
  ["E15 non-operator", { user: ingredient },403,"REJECTED"],
  ["E16 disabled", { config: { writesEnabled: "false" } },503,"REJECTED"],
  ["E17 database error", { businessFailure: true, businessCode: "XX000" },503,"ROLLED_BACK"],
  ["E18 insufficient", { businessFailure: true },409,"ROLLED_BACK"],
  ["E19 inactive", { businessFailure: true, businessCode: "22023" },409,"ROLLED_BACK"],
  ["unknown ingredient", { businessFailure: true, businessCode: "22023" },409,"ROLLED_BACK"],
  ["fractional each", { businessFailure: true, businessCode: "22023" },409,"ROLLED_BACK"],
  ["E20 ambiguous commit", { commitFailure: true },503,"UNKNOWN"],
  ["E22 identity", { identity: "postgres" },503,"ROLLED_BACK"]
] as const) {
  Deno.test("Waste boundary " + name, async () => {
    const h = harness(options); const response = await h.handler(request(wastePayload));
    equal(response.status,status); equal((await response.json()).outcome,outcome);
    if ([401,403].includes(status) || name === "E16 disabled") noDatabase(h.state);
    if (name === "E22 identity") assert(!h.state.statements.some(s => s.text.includes("record_waste")));
    if (name === "E20 ambiguous commit") equal(h.state.statements.filter(s => s.text.includes("record_waste")).length,1);
  });
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

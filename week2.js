"use strict";

(() => {
  const config = window.restaurantWeek2Config || {};
  const element = (id) => document.getElementById(id);
  const refresh = element("refresh");
  let projectUrl = null;
  try {
    const url = new URL(config.projectUrl);
    if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash ||
        !["", "/"].includes(url.pathname) ||
        !/^[a-z0-9-]+\.supabase\.co$/.test(url.hostname) || url.port) throw new Error("Invalid project URL.");
    projectUrl = url.origin;
  } catch { /* Invalid or absent public configuration stays disconnected. */ }
  const available = config.liveEnabled === true && projectUrl !== null &&
    typeof config.publishableKey === "string" && /^sb_publishable_[A-Za-z0-9_-]+$/.test(config.publishableKey);
  let loading = false;
  let inventoryOptions = [];
  let historyRows = [];
  let writeBusy = false;
  let accessToken = null;
  let thresholdUserId = null;
  let thresholdOverrides = new Map();
  let thresholdNotice = "";
  let expiresAt = 0;
  let unknownWrite = false;
  let authorizationDenied = false;
  let expiryTimer = null;
  const writesAvailable = available && config.writeEnabled === true;
  let appState = "LOGGED_OUT";
  let restaurantSelected = false;
  let readGeneration = 0;
  let activeReadController = null;
  let expirationRows = null;
  let expirationController = null;
  let expirationPromise = null;

  function expirationStatus(expiresOn, today) {
    if (!validBusinessDate(today) || expiresOn !== null && !validBusinessDate(expiresOn)) return "Unavailable";
    if (expiresOn === null) return "Not Configured";
    if (expiresOn < today) return "Expired";
    if (expiresOn === today) return "Expires Today";
    const [y,m,d] = today.split("-").map(Number);
    const horizon = new Date(0);
    horizon.setUTCFullYear(y,m-1,d);
    horizon.setUTCHours(0,0,0,0);
    horizon.setUTCDate(horizon.getUTCDate()+7);
    return expiresOn <= horizon.toISOString().slice(0,10) ? "Expiring Soon" : "Normal";
  }

  function clearExpirations(message) {
    expirationRows = null;
    element("expiration-summary").textContent = "Unavailable — " + message;
    element("expiration-body").replaceChildren();
    row(element("expiration-body"), ["Unavailable"], 7);
  }

  function renderExpirations() {
    if (!canReadInventory() || expirationRows === null) return;
    const today = new Date(Date.now()).toISOString().slice(0,10);
    const statuses = expirationRows.map(item => expirationStatus(item.expires_on,today));
    element("expiration-summary").textContent = "UTC reference date: " + today +
      " · Expired receipt records: " + statuses.filter(s=>s==="Expired").length +
      " · Expires Today: " + statuses.filter(s=>s==="Expires Today").length +
      " · Expiring-soon receipt records: " + statuses.filter(s=>s==="Expiring Soon").length +
      " · Unknown-expiry receipt records: " + statuses.filter(s=>s==="Not Configured").length;
    element("expiration-body").replaceChildren();
    expirationRows.forEach((item,index) => {
      row(element("expiration-body"), [item.receipt_id.slice(0,8)+"…",item.ingredient_name,
        decimal(item.original_quantity,true),item.unit_code,item.transaction_date,item.expires_on ?? "Not Configured",statuses[index]]);
      element("expiration-body").lastElementChild.firstElementChild.title = item.receipt_id;
    });
    if (!expirationRows.length) row(element("expiration-body"), ["No receipt records available."], 7);
  }

  function loadExpirations() {
    checkSessionExpiry();
    if (!canReadInventory()) return Promise.resolve();
    if (expirationPromise) return expirationPromise;
    const generation = readGeneration, controller = new AbortController(), token = accessToken;
    expirationController = controller;
    const current = () => generation===readGeneration && canReadInventory() && token===accessToken;
    const pending = (async () => {
      clearExpirations("loading protected receipt records.");
      element("refresh-expirations").disabled = true;
      const timer = setTimeout(()=>controller.abort(),20000);
      const receipts=[], ids=new Set(), sequences=new Set();
      let total=null, previous=0n;
      try {
        for (let page=0; page<100; page++) {
          if (!current() || controller.signal.aborted) return;
          const response = await fetch(projectUrl+"/functions/v1/inventory-write", {
            method:"POST",credentials:"omit",cache:"no-store",redirect:"error",signal:controller.signal,
            headers:{apikey:config.publishableKey,Authorization:"Bearer "+token,"Content-Type":"application/json"},
            body:JSON.stringify({action:"list_receipt_expirations",offset:receipts.length})
          });
          if (!current()) return;
          if (response.status===401) { clearSession("Your session was rejected. Sign in again."); return; }
          if (response.status!==200) throw new Error();
          if (!/^application\/json(?:;|$)/i.test(response.headers.get("content-type") || "")) throw new Error();
          const data=decodeExactJson(await response.text());
          if (!current()) return;
          const result=data?.result;
          if (data?.ok!==true || data.outcome!=="READ" || typeof result?.total!=="string" || !/^\d+$/.test(result.total) ||
              Number(result.total)>50000 || !Array.isArray(result.rows)) throw new Error();
          const count=Number(result.total);
          if (total!==null && total!==count || result.rows.length!==Math.min(500,count-receipts.length)) throw new Error();
          total=count;
          for (const item of result.rows) {
            const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
            if (!uuid.test(item.receipt_id) || !uuid.test(item.ingredient_id) || ids.has(item.receipt_id) ||
                typeof item.ledger_sequence!=="string" || !/^[1-9]\d*$/.test(item.ledger_sequence) ||
                sequences.has(item.ledger_sequence) || BigInt(item.ledger_sequence)<=previous ||
                !["lb","pt","fl oz","each"].includes(item.unit_code) || !validBusinessDate(item.transaction_date) ||
                item.expires_on!==null && (!validBusinessDate(item.expires_on) || item.expires_on<item.transaction_date)) throw new Error();
            text(item.ingredient_name);
            const quantity=stockHundredths(item.original_quantity,item.unit_code);
            if (quantity===null || quantity<=0n || quantity>999999999999n) throw new Error();
            ids.add(item.receipt_id);sequences.add(item.ledger_sequence);previous=BigInt(item.ledger_sequence);
            receipts.push(item);
          }
          if (receipts.length===total) {
            if (current()) { expirationRows=receipts;renderExpirations(); }
            return;
          }
        }
        throw new Error();
      } catch {
        if (current()) clearExpirations("protected receipt records could not be loaded or validated. Inventory remains separate.");
      } finally {
        clearTimeout(timer);
        if (current()) { expirationController=null;element("refresh-expirations").disabled=false; }
      }
    })().finally(()=>{if(expirationPromise===pending) expirationPromise=null;});
    expirationPromise=pending;
    return pending;
  }
  // Read-only demo values in the seed ingredients' units, not production policy.
  // Names/units bootstrap UUID bindings; all subsequent lookups use ingredient_id.
  const demoThresholdTemplates = Object.freeze([
    { name: "Beef", unit: "lb", quantity: "5.00" },
    { name: "Chicken", unit: "lb", quantity: "10.00" },
    { name: "Salmon", unit: "lb", quantity: "4.00" },
    { name: "Milk", unit: "pt", quantity: "3.00" },
    { name: "Cooking Oil", unit: "fl oz", quantity: "16.00" },
    { name: "Eggs", unit: "each", quantity: "20" }
  ].map(Object.freeze));
  const demoThresholdsById = new Map();

  function thresholdKey(item) { return item.ingredient_id + "|" + item.unit_code; }
  function thresholdStorageKey() {
    return thresholdUserId ? "gateway.thresholds.v1:" + projectUrl + ":gateway-demo:" + thresholdUserId : null;
  }
  function validThreshold(value, unit) {
    return value === null || typeof value === "string" && value.length <= 128 && stockHundredths(value, unit) !== null;
  }
  function loadThresholdSettings() {
    thresholdOverrides = new Map();
    thresholdNotice = "";
    const key = thresholdStorageKey();
    if (!key) {
      thresholdNotice = "User identity unavailable. Threshold changes can only be applied for this session.";
      return;
    }
    try {
      const source = localStorage.getItem(key);
      if (source === null) return;
      if (source.length > 2000000) throw new Error();
      const data = JSON.parse(source);
      if (data?.version !== 1 || !Array.isArray(data.entries) || data.entries.length > 50000) throw new Error();
      const loaded = new Map();
      for (const entry of data.entries) {
        if (!entry || typeof entry.ingredient_id !== "string" ||
            !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(entry.ingredient_id) ||
            !["lb", "pt", "fl oz", "each"].includes(entry.unit_code) ||
            !validThreshold(entry.value, entry.unit_code) || loaded.has(thresholdKey(entry))) throw new Error();
        loaded.set(thresholdKey(entry), { ingredient_id: entry.ingredient_id, unit_code: entry.unit_code, value: entry.value });
      }
      thresholdOverrides = loaded;
    } catch {
      thresholdNotice = "Saved thresholds could not be read or were invalid. Demo defaults are shown; nothing was overwritten.";
    }
  }

  function saveThresholdSettings(reset = false) {
    checkSessionExpiry();
    if (!canReadInventory() || loading || element(reset ? "reset-thresholds" : "save-thresholds").disabled) return;
    const next = reset ? new Map() : new Map(thresholdOverrides);
    if (!reset) {
      for (const item of inventoryOptions) {
        const input = element("threshold-" + item.ingredient_id);
        const value = input.value;
        if (value !== "" && !validThreshold(value, item.unit_code)) {
          input.setAttribute("aria-invalid", "true");
          input.focus();
          element("threshold-message").textContent = "Invalid threshold for " + item.ingredient_name +
            ": use a nonnegative decimal with up to two decimal places (whole numbers for each). Nothing was saved.";
          return;
        }
        input.removeAttribute("aria-invalid");
        next.set(thresholdKey(item), { ingredient_id: item.ingredient_id, unit_code: item.unit_code,
          value: value === "" ? null : value });
      }
    }
    const key = thresholdStorageKey();
    if (key) {
      try {
        const source = JSON.stringify({ version: 1, entries: [...next.values()] });
        if (source.length > 2000000) throw new Error();
        localStorage.setItem(key, source);
      } catch {
        element("threshold-message").textContent = "Thresholds could not be saved to this browser. Previous settings remain active; drafts were not saved.";
        return;
      }
    }
    thresholdOverrides = next;
    if (reset) demoThresholdsById.clear();
    thresholdNotice = key ? (reset ? "Reset to demo defaults in this browser." : "Thresholds saved in this browser only.")
      : "Thresholds applied for this session only. User identity unavailable; nothing was persisted.";
    renderStockAlerts(inventoryOptions);
  }

  function stockHundredths(value, unit) {
    if (typeof value !== "string" || !/^\d+(?:\.\d{1,2})?$/.test(value)) return null;
    const [whole, fraction = ""] = value.split(".");
    const amount = BigInt(whole) * 100n + BigInt(fraction.padEnd(2, "0"));
    return unit === "each" && amount % 100n !== 0n ? null : amount;
  }

  function stockAlert(item, threshold) {
    const amount = stockHundredths(item.current_balance, item.unit_code);
    if (amount === null) return { status: "Unavailable", threshold: "Unavailable" };
    const limit = threshold && threshold.unit === item.unit_code
      ? stockHundredths(threshold.quantity, item.unit_code) : null;
    if (limit === null) return { status: "Not Configured", threshold: "Not Configured" };
    return { status: amount <= limit ? "Low Stock" : "Normal",
      threshold: decimal(threshold.quantity) };
  }

  function clearStockAlerts(message) {
    element("save-thresholds").disabled = true;
    element("reset-thresholds").disabled = true;
    element("threshold-message").textContent = "";
    element("stock-summary").textContent = "Unavailable — " + message;
    element("stock-alert-body").replaceChildren();
    row(element("stock-alert-body"), ["Unavailable"], 5);
  }

  function renderStockAlerts(inventory) {
    if (!canReadInventory()) return;
    const alerts = inventory.map(item => {
      if (!demoThresholdsById.has(item.ingredient_id)) {
        const template = demoThresholdTemplates.find(t => t.name === item.ingredient_name && t.unit === item.unit_code);
        if (template) demoThresholdsById.set(item.ingredient_id, template);
      }
      const override = thresholdOverrides.get(thresholdKey(item));
      const threshold = override ? (override.value === null ? null : { unit: item.unit_code, quantity: override.value })
        : demoThresholdsById.get(item.ingredient_id);
      return { item, draft: threshold?.quantity ?? "", ...stockAlert(item, threshold) };
    });
    if (alerts.some(alert => alert.status === "Unavailable")) {
      clearStockAlerts("inventory quantities could not be validated.");
      return;
    }
    element("stock-summary").textContent = "Active Ingredients: " + alerts.length +
      " · Low Stock: " + alerts.filter(a => a.status === "Low Stock").length +
      " · Thresholds Not Configured: " + alerts.filter(a => a.status === "Not Configured").length;
    element("stock-alert-body").replaceChildren();
    for (const alert of alerts) {
      row(element("stock-alert-body"), [alert.item.ingredient_name, decimal(alert.item.current_balance),
        alert.item.unit_code, alert.threshold, alert.status]);
      const cell = element("stock-alert-body").lastElementChild.children[3];
      const input = document.createElement("input");
      input.id = "threshold-" + alert.item.ingredient_id;
      input.type = "text";
      input.inputMode = "decimal";
      input.maxLength = 128;
      input.value = alert.draft;
      input.placeholder = "Not Configured";
      input.setAttribute("aria-label", "Low stock threshold for " + alert.item.ingredient_name + " in " + alert.item.unit_code);
      cell.replaceChildren(input);
      if (alert.status === "Low Stock") element("stock-alert-body").lastElementChild.lastElementChild.classList.add("stock-low");
    }
    if (!alerts.length) row(element("stock-alert-body"), ["No active ingredients available."], 5);
    element("save-thresholds").disabled = !alerts.length;
    element("reset-thresholds").disabled = false;
    element("threshold-message").textContent = thresholdNotice;
  }

  function canReadInventory() {
    return available && !!accessToken && Date.now() < expiresAt &&
      restaurantSelected && appState === "DASHBOARD";
  }

  function showScreen(state, focus = true) {
    appState = state;
    element("login-screen").hidden = state !== "LOGGED_OUT";
    element("restaurant-screen").hidden = state !== "RESTAURANT_SELECTION";
    element("dashboard-screen").hidden = state !== "DASHBOARD";
    element("signed-in-controls").hidden = state === "LOGGED_OUT";
    if (focus) element(state === "DASHBOARD" ? "dashboard-title" :
      state === "RESTAURANT_SELECTION" ? "restaurant-title" : "login-title").focus();
  }

  function clearBusinessData() {
    readGeneration++;
    expirationController?.abort();
    expirationController=null;
    expirationPromise=null;
    clearExpirations("sign in and select the demo restaurant.");
    element("refresh-expirations").disabled=true;
    activeReadController?.abort();
    activeReadController = null;
    readPromise = null;
    loading = false;
    inventoryOptions = [];
    demoThresholdsById.clear();
    thresholdOverrides.clear();
    thresholdNotice = "";
    thresholdUserId = null;
    clearStockAlerts("sign in and select the demo restaurant.");
    resetHistoryFilter();
    updateIngredientOptions();
    clearTables("Sign in and select the demo restaurant to load inventory.");
    for (const id of ["add-ingredient", "receive-stock", "consume-stock", "deactivate-ingredient", "reactivate-ingredient", "record-waste"]) element(id).reset();
    element("record-waste").hidden = true;
    element("toggle-waste").setAttribute("aria-expanded", "false");
    updateWasteUnit();
    element("write-message").textContent = "";
    element("connection-status").textContent = "Not Connected";
    element("connection-detail").textContent = "No inventory loaded.";
    element("connection-error").textContent = "";
    element("connection-error").hidden = true;
    refresh.disabled = true;
    for (const id of ["stock-section", "history-section"]) element(id).setAttribute("aria-busy", "false");
  }

  function row(body, values, span) {
    const entry = document.createElement("tr");
    for (const value of values) {
      const cell = document.createElement("td");
      cell.textContent = value;
      if (span) cell.colSpan = span;
      entry.appendChild(cell);
    }
    body.appendChild(entry);
  }

  function clearTables(message) {
    for (const [id, span] of [["stock-body", 4], ["history-body", 7]]) {
      const body = element(id);
      body.replaceChildren();
      row(body, [message], span);
    }
  }

  function resetHistoryFilter() {
    historyRows = [];
    const select = element("history-ingredient");
    select.replaceChildren();
    const all = document.createElement("option");
    all.value = "";
    all.textContent = "All Ingredients";
    select.appendChild(all);
    select.value = "";
    select.disabled = true;
  }

  function populateHistoryFilter(inventory, selected) {
    const select = element("history-ingredient");
    const names = new Set([...inventory.map(item => item[0]), ...historyRows.map(item => item.cells[1])]);
    for (const name of [...names].sort()) {
      const option = document.createElement("option");
      option.value = name;
      option.textContent = name;
      select.appendChild(option);
    }
    select.value = names.has(selected) ? selected : "";
    select.disabled = false;
  }

  function renderHistory() {
    if (!canReadInventory() || loading) return;
    const selected = element("history-ingredient").value;
    const filtered = historyRows.filter(item => !selected || item.cells[1] === selected);
    element("history-body").replaceChildren();
    for (const item of filtered) row(element("history-body"), item.cells);
    if (!filtered.length) row(element("history-body"), [selected
      ? "No transactions recorded for this ingredient." : "No inventory transactions recorded."], 7);
  }

  function text(value) {
    if (typeof value !== "string" || !value.trim()) throw new Error("Invalid text field.");
    return value;
  }

  function decimal(value, positive = false) {
    // Require losslessly decoded decimal strings, never converted JSON Numbers.
    if (typeof value !== "string" || !/^\d+(?:\.\d{1,2})?$/.test(value) ||
        (positive && !/[1-9]/.test(value))) throw new Error("Invalid quantity field.");
    const [whole, fraction = ""] = value.split(".");
    return whole + "." + fraction.padEnd(2, "0");
  }

  function validate(data) {
    if (!data || !Array.isArray(data.inventory) || !Array.isArray(data.history)) throw new Error("Invalid inventory response.");
    const ingredientIds = new Set();
    const inventory = data.inventory.map((item) => {
      const id = text(item.ingredient_id);
      if (ingredientIds.has(id)) throw new Error("Duplicate ingredient.");
      ingredientIds.add(id);
      return [text(item.ingredient_name), text(item.category), decimal(item.current_balance), text(item.unit_code)];
    });
    const sequences = new Set();
    const history = data.history.map((item) => {
      const sequence = text(item.ledger_sequence);
      if (!/^[1-9]\d*$/.test(sequence) || sequences.has(sequence)) throw new Error("Invalid ledger sequence.");
      sequences.add(sequence);
      if (!["INCOMING", "CONSUMPTION", "WASTE"].includes(item.transaction_type)) throw new Error("Invalid transaction type.");
      const reasons = { spoiled: "Spoiled", damaged: "Damaged", other: "Other" };
      if (item.transaction_type === "WASTE" ? !Object.hasOwn(reasons, item.waste_reason)
          : item.waste_reason !== null && item.waste_reason !== undefined) throw new Error("Invalid waste reason.");
      return { sequence, cells: [sequence, text(item.ingredient_name),
        item.transaction_type === "INCOMING" ? "Incoming stock" : item.transaction_type === "WASTE" ? "Waste" : "Consumption",
        decimal(item.quantity, true), text(item.unit_code), text(item.transaction_date),
        item.transaction_type === "WASTE" ? reasons[item.waste_reason] : "—"] };
    });
    history.sort((a, b) => BigInt(a.sequence) < BigInt(b.sequence) ? -1 : BigInt(a.sequence) > BigInt(b.sequence) ? 1 : 0);
    return { inventory, history };
  }


  // Parse JSON numeric tokens as their original strings, before any Number conversion.
  function decodeExactJson(source) {
    if (source.length > 5000000) throw new Error("Response too large.");
    let position = 0;
    const whitespace = () => { while (/[\t\n\r ]/.test(source[position] || "x")) position++; };
    function string() {
      const start = position++;
      while (position < source.length) {
        if (source[position] === "\\") { position += 2; continue; }
        if (source[position++] === '"') return JSON.parse(source.slice(start, position));
      }
      throw new Error("Unterminated JSON string.");
    }
    function value(depth = 0) {
      if (depth > 64) throw new Error("Response nesting too deep.");
      whitespace();
      const token = source[position];
      if (token === '"') return string();
      if (token === "[" || token === "{") {
        const array = token === "[";
        const result = array ? [] : Object.create(null);
        const end = array ? "]" : "}";
        position++;
        whitespace();
        if (source[position] === end) { position++; return result; }
        while (position < source.length) {
          if (array) result.push(value(depth + 1));
          else {
            whitespace();
            if (source[position] !== '"') throw new Error("Invalid JSON key.");
            const key = string();
            if (Object.hasOwn(result, key)) throw new Error("Duplicate JSON key.");
            whitespace();
            if (source[position++] !== ":") throw new Error("Invalid JSON object.");
            result[key] = value(depth + 1);
          }
          whitespace();
          const delimiter = source[position++];
          if (delimiter === end) return result;
          if (delimiter !== ",") throw new Error("Invalid JSON delimiter.");
        }
        throw new Error("Unterminated JSON container.");
      }
      for (const [literal, decoded] of [["true", true], ["false", false], ["null", null]]) {
        if (source.startsWith(literal, position)) { position += literal.length; return decoded; }
      }
      const number = source.slice(position).match(/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/);
      if (!number) throw new Error("Invalid JSON value.");
      position += number[0].length;
      return number[0];
    }
    const decoded = value();
    whitespace();
    if (position !== source.length) throw new Error("Unexpected JSON content.");
    return decoded;
  }

  async function readView(view, columns, order, signal, generation) {
    const current = () => generation === readGeneration && canReadInventory() && !signal.aborted;
    const all = [];
    let total = null;
    for (let page = 0; page < 100; page++) {
      if (!current()) throw new Error("Inventory read cancelled.");
      const url = new URL(projectUrl + "/rest/v1/" + view);
      url.search = new URLSearchParams({ select: columns, order, limit: "500", offset: String(all.length) }).toString();
      const response = await fetch(url, {
        method: "GET", credentials: "omit", cache: "no-store", redirect: "error", signal,
        headers: { apikey: config.publishableKey, "Accept-Profile": "erp_api",
          Accept: "application/json", Prefer: "count=exact" }
      });
      if (!current()) throw new Error("Inventory read cancelled.");
      if (!response.ok || ![200, 206].includes(response.status)) throw new Error("Read failed.");
      if (!/^application\/json(?:;|$)/i.test(response.headers.get("content-type") || "")) throw new Error("Invalid response type.");
      const source = await response.text();
      if (!current()) throw new Error("Inventory read cancelled.");
      const rows = decodeExactJson(source);
      if (!Array.isArray(rows) || rows.length > 500) throw new Error("Invalid page.");
      const range = response.headers.get("content-range") || "";
      if (range === "*/0" && all.length === 0 && rows.length === 0) return [];
      const match = range.match(/^(\d+)-(\d+)\/(\d+)$/);
      if (!match) throw new Error("Exact page count unavailable.");
      const [start, end, count] = match.slice(1).map(Number);
      if (![start, end, count].every(Number.isSafeInteger) || count > 50000 ||
          start !== all.length || end !== start + rows.length - 1 || !rows.length || end >= count ||
          (total !== null && total !== count)) throw new Error("Incomplete or changing inventory response.");
      total = count;
      all.push(...rows);
      if (all.length === total) return all;
    }
    throw new Error("Inventory exceeds the supported read limit.");
  }

  async function readInventory(controller, generation) {
    const timeout = setTimeout(() => controller.abort(), 20000);
    try {
      const [inventory, history] = await Promise.all([
        readView("inventory_balances", "ingredient_id,ingredient_name,category,unit_code,current_balance", "ingredient_id.asc", controller.signal, generation),
        readView("inventory_history", "*", "ledger_sequence.asc", controller.signal, generation)
      ]);
      return { inventory, history };
    } finally {
      controller.abort();
      clearTimeout(timeout);
    }
  }

  let readPromise = null;
  function load() {
    checkSessionExpiry();
    if (!canReadInventory()) return Promise.resolve();
    if (!readPromise) {
      const pending = loadNow().finally(() => { if (readPromise === pending) readPromise = null; });
      readPromise = pending;
    }
    return readPromise;
  }

  async function loadNow() {
    if (!canReadInventory() || loading) return;
    const generation = readGeneration;
    const controller = new AbortController();
    activeReadController = controller;
    const current = () => generation === readGeneration && canReadInventory();
    loading = true;
    const selectedHistory = element("history-ingredient").value;
    resetHistoryFilter();
    refresh.disabled = true;
    clearStockAlerts("inventory is loading.");
    element("connection-error").hidden = true;
    element("connection-status").textContent = "Loading · Data source: Connection pending";
    element("connection-detail").textContent = "Loading current inventory and history from Supabase.";
    for (const id of ["stock-section", "history-section"]) element(id).setAttribute("aria-busy", "true");
    inventoryOptions = [];
    updateIngredientOptions();
    clearTables("Loading…");
    try {
      const raw = await readInventory(controller, generation);
      if (!current()) return;
      const result = validate(raw);
      renderStockAlerts(raw.inventory);
      inventoryOptions = raw.inventory;
      updateIngredientOptions();
      element("stock-body").replaceChildren();
      for (const values of result.inventory) row(element("stock-body"), values);
      historyRows = result.history;
      populateHistoryFilter(result.inventory, selectedHistory);
      if (!result.inventory.length) row(element("stock-body"), ["No ingredients available."], 4);
      element("connection-status").textContent = "Connected — Supabase Live";
      element("connection-detail").textContent = "Read-only inventory and history loaded. Quantities are displayed with two decimal places.";
    } catch {
      if (!current()) return;
      clearTables("Data unavailable. Refresh to try again.");
      clearStockAlerts("inventory is unavailable. Refresh to try again.");
      element("connection-status").textContent = "Connection unavailable · Data source: Unavailable";
      element("connection-detail").textContent = "No current data is displayed.";
      element("connection-error").textContent = "Inventory could not be loaded or validated. Check the approved connection and try again.";
      element("connection-error").hidden = false;
    } finally {
      if (current()) {
        activeReadController = null;
        loading = false;
        if (!element("history-ingredient").disabled) renderHistory();
        refresh.disabled = false;
        for (const id of ["stock-section", "history-section"]) element(id).setAttribute("aria-busy", "false");
      }
    }
  }


  function updateIngredientOptions() {
    for (const id of ["receive-stock-ingredient", "consume-stock-ingredient", "deactivate-ingredient-ingredient", "record-waste-ingredient"]) {
      const select = element(id);
      const selected = select.value;
      select.replaceChildren();
      const placeholder = document.createElement("option");
      placeholder.value = "";
      placeholder.textContent = id === "deactivate-ingredient-ingredient"
        ? "Select an active ingredient (zero stock required)" : "Select an active ingredient";
      select.appendChild(placeholder);
      for (const item of inventoryOptions) {
        const option = document.createElement("option");
        option.value = item.ingredient_id;
        option.textContent = item.ingredient_name + " (" + item.unit_code + ")";
        select.appendChild(option);
      }
      select.value = inventoryOptions.some(item => item.ingredient_id === selected) ? selected : "";
    }
    updateWasteUnit();
  }

  function updateWasteUnit() {
    const item = inventoryOptions.find(item => item.ingredient_id === element("record-waste-ingredient").value);
    element("waste-unit").textContent = "Unit: " + (item ? item.unit_code : "Select an ingredient");
  }

  function updateWriteControls() {
    const signedIn = !!accessToken && Date.now() < expiresAt;
    element("write-controls").disabled = !writesAvailable || !canReadInventory() || writeBusy || unknownWrite || authorizationDenied;
    element("sign-in-button").disabled = !available || writeBusy || signedIn;
    element("sign-out").disabled = !signedIn || writeBusy;
  }

  function clearSession(message) {
    clearTimeout(expiryTimer);
    expiryTimer = null;
    accessToken = null;
    expiresAt = 0;
    authorizationDenied = false;
    restaurantSelected = false;
    clearBusinessData();
    element("operator-password").value = "";
    showScreen("LOGGED_OUT");
    if (message) element("auth-status").textContent = message;
    // Session changes never reconcile or clear an UNKNOWN write outcome.
    updateWriteControls();
  }

  function checkSessionExpiry() {
    if (accessToken && Date.now() >= expiresAt) clearSession("Your session expired. Sign in again.");
  }

  function quantityHundredths(value) {
    if (typeof value !== "string" || value.length > 128 || !/^\d+(?:\.\d{1,2})?$/.test(value))
      throw new Error("Use unsigned quantity text with at most two decimal places.");
    const [whole, fraction = ""] = value.split(".");
    return BigInt(whole) * 100n + BigInt(fraction.padEnd(2, "0"));
  }

  function validBusinessDate(value) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
    const [year, month, day] = value.split("-").map(Number);
    const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
    return year >= 1 && month >= 1 && month <= 12 && day >= 1 &&
      day <= [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1];
  }

  function validatedWrite(id, form) {
    const get = (name) => form.elements.namedItem(name)?.value || "";
    const actions = { "add-ingredient": "add_ingredient", "receive-stock": "receive_stock",
      "consume-stock": "consume_stock", "deactivate-ingredient": "deactivate_ingredient", "record-waste": "record_waste" };
    const action = actions[id];
    if (id === "reactivate-ingredient") {
      const name = get("name").trim();
      if (!name || name.length > 200)
        throw new Error("Enter an existing ingredient name of at most 200 characters.");
      return { payload: { action: "reactivate_ingredient", name }, advisory: "Reactivation changes status only; no stock is added. " };
    }
    if (action === "add_ingredient") {
      const name = get("name").trim(), category = get("category").trim(), unit = get("unit_id");
      if (!name || !category || name.length > 200 || category.length > 200)
        throw new Error("Name and category are required and must contain at most 200 characters each.");
      if (![1, 2, 3, 4].some(n => unit === "10000000-0000-4000-8000-00000000000" + n))
        throw new Error("Choose a supported ingredient unit.");
      return { payload: { action, name, category, unit_id: unit }, advisory: "" };
    }
    const ingredientId = get("ingredient_id");
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(ingredientId))
      throw new Error("Choose an ingredient with a valid lowercase UUID.");
    const ingredient = inventoryOptions.find(item => item.ingredient_id === ingredientId);
    if (!ingredient) throw new Error("Refresh inventory and select an active ingredient.");
    if (action === "deactivate_ingredient") return {
      payload: { action, ingredient_id: ingredientId },
      advisory: "Deactivation requires zero stock; the server will verify the current balance. "
    };
    if (action === "record_waste") {
      const quantity = get("quantity"), reason = get("reason"), amount = quantityHundredths(quantity);
      if (amount <= 0n || amount > 999999999999n) throw new Error("Waste quantity must be greater than zero and at most 9999999999.99.");
      if (ingredient.unit_code === "each" && amount % 100n !== 0n) throw new Error("Quantities for each must be whole numbers.");
      if (!["spoiled", "damaged", "other"].includes(reason)) throw new Error("Select a valid waste reason.");
      return { payload: { action, ingredient_id: ingredientId, quantity, reason }, advisory: "Waste is recorded using the server UTC date. " };
    }
    const quantity = get("quantity"), date = get("date");
    const amount = quantityHundredths(quantity);
    if (amount <= 0n || amount > 999999999999n)
      throw new Error("Quantity must be greater than zero and at most 9999999999.99.");
    if (ingredient.unit_code === "each" && amount % 100n !== 0n)
      throw new Error("Quantities for each must be whole numbers.");
    if (!validBusinessDate(date)) throw new Error("Enter a valid calendar date in YYYY-MM-DD format.");
    let advisory = "";
    if (action === "consume_stock" && amount > quantityHundredths(ingredient.current_balance))
      advisory = "Requested consumption exceeds displayed stock; the server will verify the current balance. ";
    const payload = { action, ingredient_id: ingredientId, quantity, date };
    if (action === "receive_stock" && get("expires_on") !== "") {
      const expiry = get("expires_on");
      if (!validBusinessDate(expiry) || expiry < date) throw new Error("Expiration date must be a valid date on or after the receipt date.");
      payload.expires_on = expiry;
    }
    return { payload, advisory };
  }

  async function boundedFetch(url, options, allowEmpty = false) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 20000);
    try {
      const response = await fetch(url, { ...options, credentials: "omit", cache: "no-store", redirect: "error", signal: controller.signal });
      try {
        const body = await response.text();
        if (body.length > 65536) throw new Error("Response unavailable.");
        return { response, data: allowEmpty && !body ? null : decodeExactJson(body) };
      } catch (error) {
        // These protected-route statuses are pre-execution auth rejections,
        // including gateway responses without the handler's outcome envelope.
        if ([401, 403].includes(response.status)) return { response, data: null };
        throw error;
      }
    } finally { clearTimeout(timeout); }
  }

  element("sign-in").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!available || writeBusy || (accessToken && Date.now() < expiresAt)) return;
    const email = element("operator-email").value.trim();
    const password = element("operator-password").value;
    clearSession();
    element("operator-password").value = "";
    if (!email || !password) { element("auth-status").textContent = "Enter your operator email and password."; return; }
    writeBusy = true;
    updateWriteControls();
    element("auth-status").textContent = "Signing in…";
    const loginStartedAt = Date.now();
    try {
      const { response, data } = await boundedFetch(projectUrl + "/auth/v1/token?grant_type=password", {
        method: "POST", headers: { apikey: config.publishableKey, "Content-Type": "application/json" },
        body: JSON.stringify({ email, password })
      });
      if (!response.ok || typeof data?.access_token !== "string" || !/^\d+$/.test(data.expires_in)) throw new Error("Sign-in failed.");
      const lifetime = Number(data.expires_in);
      if (!Number.isSafeInteger(lifetime) || lifetime <= 0 || lifetime > 86400 ||
          loginStartedAt + lifetime * 1000 <= Date.now()) throw new Error("Invalid session.");
      accessToken = data.access_token;
      thresholdUserId = typeof data.user?.id === "string" &&
        /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(data.user.id) ? data.user.id : null;
      loadThresholdSettings();
      expiresAt = loginStartedAt + lifetime * 1000;
      expiryTimer = setTimeout(checkSessionExpiry, expiresAt - Date.now());
      showScreen("RESTAURANT_SELECTION");
      element("auth-status").textContent = writesAvailable
        ? "Signed in. Every inventory action still requires server authorization."
        : "Signed in for authentication testing. Frontend inventory writes remain disabled.";
    } catch {
      clearSession("Sign-in failed. Check your account or connection.");
    } finally {
      element("operator-password").value = "";
      writeBusy = false;
      updateWriteControls();
    }
  });

  element("select-restaurant").addEventListener("click", () => {
    checkSessionExpiry();
    if (!accessToken || Date.now() >= expiresAt || appState !== "RESTAURANT_SELECTION") return;
    restaurantSelected = true;
    showScreen("DASHBOARD");
    if (unknownWrite) element("write-message").textContent = "Outcome unknown. Writes remain blocked. Reconcile history before any retry; signing in again does not reconcile an earlier request.";
    updateWriteControls();
    load();
    loadExpirations();
  });

  element("sign-out").addEventListener("click", async () => {
    if (writeBusy) return;
    const token = accessToken;
    clearSession();
    writeBusy = true;
    updateWriteControls();
    try {
      if (token) await boundedFetch(projectUrl + "/auth/v1/logout?scope=local", {
        method: "POST", headers: { apikey: config.publishableKey, Authorization: "Bearer " + token }
      }, true);
    } catch { /* Local session is cleared even when remote logout is unavailable. */ }
    finally {
      element("auth-status").textContent = "Signed out locally. If remote logout failed, the server token expires normally.";
      writeBusy = false;
      updateWriteControls();
    }
  });

  for (const id of ["add-ingredient", "receive-stock", "consume-stock", "deactivate-ingredient", "reactivate-ingredient", "record-waste"]) {
    const form = element(id);
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      if (!writesAvailable || writeBusy || unknownWrite || authorizationDenied) return;
      if (!accessToken || Date.now() >= expiresAt) {
        clearSession("Your session expired. Sign in again.");
        return;
      }
      if (!canReadInventory()) return;
      const generation = readGeneration;
      let payload, advisory;
      try { ({ payload, advisory } = validatedWrite(id, form)); }
      catch (error) { element("write-message").textContent = error.message; return; }
      writeBusy = true;
      updateWriteControls();
      element("write-message").textContent = advisory + "Submitting inventory change…";
      let confirmed = false;
      try {
        const { response, data } = await boundedFetch(projectUrl + "/functions/v1/inventory-write", {
          method: "POST", headers: { apikey: config.publishableKey, Authorization: "Bearer " + accessToken, "Content-Type": "application/json" },
          body: JSON.stringify(payload)
        });
        if (response.status === 401) {
          clearSession("Your session was rejected. Sign in again.");
          if (data?.outcome && data.outcome !== "REJECTED") throw new Error("Inconsistent authentication response.");
          element("write-message").textContent = "Sign-in is required. The request was not replayed.";
          return;
        }
        if (response.status === 403) {
          authorizationDenied = true;
          element("auth-status").textContent = "Operator authorization denied. Sign out before attempting a new session.";
          if (data?.outcome && data.outcome !== "REJECTED") throw new Error("Inconsistent authorization response.");
          element("write-message").textContent = "You are not authorized for this request. Further submissions are blocked.";
          return;
        }
        if (response.status === 200 && data?.ok === true && data.outcome === "COMMITTED") confirmed = true;
        else if ([409, 503].includes(response.status) && data?.outcome === "ROLLED_BACK") {
          if (id === "reactivate-ingredient" && response.status === 409 &&
              ["Ingredient not found.", "Ingredient is already active.",
                "Inactive ingredient has nonzero stock. Reactivation rejected."].includes(data.message)) {
            element("write-message").textContent = data.message + " No change was committed.";
            return;
          }
          element("write-message").textContent = response.status === 409
            ? "Change rejected by an inventory business rule. No change was committed; check stock and ingredient status."
            : "Change failed and was rolled back. Check service availability before another submission.";
          return;
        } else if ([400, 503].includes(response.status) && data?.outcome === "REJECTED") {
          element("write-message").textContent = response.status === 400
            ? "Request rejected. Check the form fields. No change was made."
            : data.message === "Inventory writes are disabled."
              ? "Server-side inventory writes are disabled. No change was made."
              : data.message === "Write service is not configured."
                ? "Write service is not configured. No change was made."
                : "Write service is unavailable. The request was rejected; no change was made.";
          return;
        } else throw new Error("Unknown write outcome.");
      } catch {
        unknownWrite = true;
        element("write-message").textContent = "Outcome unknown. Writes are blocked; ask the operator to reconcile history before any retry. Do not resubmit. Refresh, sign-in and page reload are not proof of reconciliation.";
      } finally {
        writeBusy = false;
        updateWriteControls();
      }
      if (confirmed && generation === readGeneration && canReadInventory()) {
        element("write-message").textContent = "Inventory change confirmed. Refreshing live inventory and history…";
        if (readPromise) await readPromise;
        if (generation !== readGeneration || !canReadInventory()) return;
        await load();
        if (payload.action === "receive_stock" && generation===readGeneration && canReadInventory()) {
          if (expirationPromise) await expirationPromise;
          if (generation===readGeneration && canReadInventory()) await loadExpirations();
        }
        if (generation !== readGeneration || !canReadInventory()) return;
        element("write-message").textContent = "Inventory change confirmed. Check the read connection status for refresh results.";
      }
    });
  }
  showScreen("LOGGED_OUT", false);
  clearBusinessData();
  updateWriteControls();
  if (available) element("auth-status").textContent = writesAvailable
    ? "Sign in with the approved operator account. Server authorization is required for every write."
    : "Authentication testing is available. Frontend inventory writes remain disabled.";
  window.addEventListener("focus", checkSessionExpiry);
  document.addEventListener("visibilitychange", checkSessionExpiry);

  refresh.addEventListener("click", () => { load(); loadExpirations(); });
  element("refresh-expirations").addEventListener("click", loadExpirations);
  window.addEventListener("focus", renderExpirations);
  element("toggle-waste").addEventListener("click", () => {
    checkSessionExpiry();
    if (!canReadInventory() || element("write-controls").disabled) return;
    const form = element("record-waste");
    form.hidden = !form.hidden;
    element("toggle-waste").setAttribute("aria-expanded", String(!form.hidden));
    if (!form.hidden) element("record-waste-ingredient").focus();
  });
  element("record-waste-ingredient").addEventListener("change", updateWasteUnit);
  element("save-thresholds").addEventListener("click", () => saveThresholdSettings());
  element("reset-thresholds").addEventListener("click", () => saveThresholdSettings(true));
  element("history-ingredient").addEventListener("change", () => {
    checkSessionExpiry();
    renderHistory();
  });
  if (!available) {
    element("auth-status").textContent = "Sign-in is unavailable. Check the public connection configuration.";
    clearTables("Not Connected — no Supabase data has been loaded.");
    element("connection-status").textContent = "Not Connected · Data source: Connection unavailable";
    element("connection-detail").textContent = "Live access is disabled or public project configuration is missing or invalid. Configure week2-config.js and reload.";
    refresh.disabled = true;
  }
})();

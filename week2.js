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
  let writeBusy = false;
  let accessToken = null;
  let expiresAt = 0;
  let unknownWrite = false;
  let authorizationDenied = false;
  let expiryTimer = null;
  const writesAvailable = available && config.writeEnabled === true;

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
    for (const [id, span] of [["stock-body", 4], ["history-body", 6]]) {
      const body = element(id);
      body.replaceChildren();
      row(body, [message], span);
    }
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
      if (!["INCOMING", "CONSUMPTION"].includes(item.transaction_type)) throw new Error("Invalid transaction type.");
      return { sequence, cells: [sequence, text(item.ingredient_name),
        item.transaction_type === "INCOMING" ? "Incoming stock" : "Consumption",
        decimal(item.quantity, true), text(item.unit_code), text(item.transaction_date)] };
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

  async function readView(view, columns, order, signal) {
    const all = [];
    let total = null;
    for (let page = 0; page < 100; page++) {
      const url = new URL(projectUrl + "/rest/v1/" + view);
      url.search = new URLSearchParams({ select: columns, order, limit: "500", offset: String(all.length) }).toString();
      const response = await fetch(url, {
        method: "GET", credentials: "omit", cache: "no-store", redirect: "error", signal,
        headers: { apikey: config.publishableKey, "Accept-Profile": "erp_api",
          Accept: "application/json", Prefer: "count=exact" }
      });
      if (!response.ok || ![200, 206].includes(response.status)) throw new Error("Read failed.");
      if (!/^application\/json(?:;|$)/i.test(response.headers.get("content-type") || "")) throw new Error("Invalid response type.");
      const rows = decodeExactJson(await response.text());
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

  async function readInventory() {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 20000);
    try {
      const [inventory, history] = await Promise.all([
        readView("inventory_balances", "ingredient_id,ingredient_name,category,unit_code,current_balance", "ingredient_id.asc", controller.signal),
        readView("inventory_history", "ledger_sequence,ingredient_name,transaction_type,quantity,unit_code,transaction_date,created_at", "ledger_sequence.asc", controller.signal)
      ]);
      return { inventory, history };
    } finally {
      controller.abort();
      clearTimeout(timeout);
    }
  }

  let readPromise = null;
  function load() {
    if (!available) return Promise.resolve();
    if (!readPromise) readPromise = loadNow().finally(() => { readPromise = null; });
    return readPromise;
  }

  async function loadNow() {
    if (!available || loading) return;
    loading = true;
    refresh.disabled = true;
    element("connection-error").hidden = true;
    element("connection-status").textContent = "Loading · Data source: Connection pending";
    element("connection-detail").textContent = "Loading current inventory and history from Supabase.";
    for (const id of ["stock-section", "history-section"]) element(id).setAttribute("aria-busy", "true");
    inventoryOptions = [];
    updateIngredientOptions();
    clearTables("Loading…");
    try {
      const raw = await readInventory();
      const result = validate(raw);
      inventoryOptions = raw.inventory;
      updateIngredientOptions();
      element("stock-body").replaceChildren();
      element("history-body").replaceChildren();
      for (const values of result.inventory) row(element("stock-body"), values);
      for (const item of result.history) row(element("history-body"), item.cells);
      if (!result.inventory.length) row(element("stock-body"), ["No ingredients available."], 4);
      if (!result.history.length) row(element("history-body"), ["No inventory transactions recorded."], 6);
      element("connection-status").textContent = "Connected — Supabase Live";
      element("connection-detail").textContent = "Read-only inventory and history loaded. Quantities are displayed with two decimal places.";
    } catch {
      clearTables("Data unavailable. Refresh to try again.");
      element("connection-status").textContent = "Connection unavailable · Data source: Unavailable";
      element("connection-detail").textContent = "No current data is displayed.";
      element("connection-error").textContent = "Inventory could not be loaded or validated. Check the approved connection and try again.";
      element("connection-error").hidden = false;
    } finally {
      loading = false;
      refresh.disabled = false;
      for (const id of ["stock-section", "history-section"]) element(id).setAttribute("aria-busy", "false");
    }
  }


  function updateIngredientOptions() {
    for (const id of ["receive-stock-ingredient", "consume-stock-ingredient", "deactivate-ingredient-ingredient"]) {
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
  }

  function updateWriteControls() {
    const signedIn = !!accessToken && Date.now() < expiresAt;
    element("write-controls").disabled = !writesAvailable || !signedIn || writeBusy || unknownWrite || authorizationDenied;
    element("sign-in-button").disabled = !available || writeBusy || signedIn;
    element("sign-out").disabled = !signedIn || writeBusy;
  }

  function clearSession(message) {
    clearTimeout(expiryTimer);
    expiryTimer = null;
    accessToken = null;
    expiresAt = 0;
    authorizationDenied = false;
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
      "consume-stock": "consume_stock", "deactivate-ingredient": "deactivate_ingredient" };
    const action = actions[id];
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
    return { payload: { action, ingredient_id: ingredientId, quantity, date }, advisory };
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
    clearSession();
    const email = element("operator-email").value.trim();
    const password = element("operator-password").value;
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
      expiresAt = loginStartedAt + lifetime * 1000;
      expiryTimer = setTimeout(checkSessionExpiry, expiresAt - Date.now());
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

  for (const id of ["add-ingredient", "receive-stock", "consume-stock", "deactivate-ingredient"]) {
    const form = element(id);
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      if (!writesAvailable || writeBusy || unknownWrite || authorizationDenied) return;
      if (!accessToken || Date.now() >= expiresAt) {
        clearSession("Your session expired. Sign in again.");
        return;
      }
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
      if (confirmed) {
        element("write-message").textContent = "Inventory change confirmed. Refreshing live inventory and history…";
        if (readPromise) await readPromise;
        await load();
        element("write-message").textContent = "Inventory change confirmed. Check the read connection status for refresh results.";
      }
    });
  }
  updateWriteControls();
  if (available) element("auth-status").textContent = writesAvailable
    ? "Sign in with the approved operator account. Server authorization is required for every write."
    : "Authentication testing is available. Frontend inventory writes remain disabled.";
  window.addEventListener("focus", checkSessionExpiry);
  document.addEventListener("visibilitychange", checkSessionExpiry);

  refresh.addEventListener("click", load);
  if (available) {
    load();
  } else {
    clearTables("Not Connected — no Supabase data has been loaded.");
    element("connection-status").textContent = "Not Connected · Data source: Connection unavailable";
    element("connection-detail").textContent = "Live access is disabled or public project configuration is missing or invalid. Configure week2-config.js and reload.";
    refresh.disabled = true;
  }
})();

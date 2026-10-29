"use strict";

(() => {
  const storageKey = "restaurantInventory.v1";
  let state = { version: 1, stock: 0, transactions: [] };
  let storageBlocked = false;
  const getElement = (id) => document.getElementById(id);
  const formatQuantity = (value) => `${Math.floor(value / 100)}.${String(value % 100).padStart(2, "0")}`;

  function validDate(value) {
    if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value) || value.startsWith("0000")) return false;
    const date = new Date(`${value}T00:00:00Z`);
    return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value;
  }

  function parseQuantity(value) {
    if (!/^\d+(?:\.\d{1,2})?$/.test(value)) throw new Error("Enter a positive quantity with no more than two decimal places.");
    const [whole, fraction = ""] = value.split(".");
    const amount = Number(whole) * 100 + Number(fraction.padEnd(2, "0"));
    if (!Number.isSafeInteger(amount) || amount <= 0) throw new Error("Enter a positive quantity within the supported range.");
    return amount;
  }

  function validateState(value) {
    if (!value || value.version !== 1 || !Number.isSafeInteger(value.stock) || value.stock < 0 || !Array.isArray(value.transactions)) throw new Error("Invalid saved inventory.");
    let balance = 0;
    for (const transaction of value.transactions) {
      if (!transaction || transaction.ingredient !== "beef" || transaction.unit !== "kg" || !validDate(transaction.date) || !["incoming", "consumption"].includes(transaction.type) || !Number.isSafeInteger(transaction.quantity) || transaction.quantity <= 0) throw new Error("Invalid saved transaction.");
      balance += transaction.type === "incoming" ? transaction.quantity : -transaction.quantity;
      if (!Number.isSafeInteger(balance) || balance < 0 || transaction.remainingStock !== balance) throw new Error("Inconsistent saved balances.");
    }
    if (balance !== value.stock) throw new Error("Inconsistent saved inventory.");
    return value;
  }

  function blockStorage(message) {
    storageBlocked = true;
    getElement("storage-error").textContent = message;
    getElement("storage-error").hidden = false;
    for (const id of ["incoming-form", "consumption-form"]) {
      for (const control of getElement(id).elements) control.disabled = true;
    }
  }

  function addRow(body, values) {
    const row = document.createElement("tr");
    for (const value of values) {
      const cell = document.createElement("td");
      cell.textContent = value;
      row.appendChild(cell);
    }
    body.appendChild(row);
  }

  function render() {
    const inventory = getElement("inventory-body");
    const history = getElement("history-body");
    inventory.replaceChildren();
    history.replaceChildren();
    if (storageBlocked) {
      addRow(inventory, ["Unavailable", "Saved data could not be loaded", "—"]);
      addRow(history, ["Transaction history is unavailable."]);
      return;
    }
    addRow(inventory, ["Beef", formatQuantity(state.stock), "kg"]);
    if (!state.transactions.length) addRow(history, ["No transactions recorded."]);
    for (const transaction of state.transactions) addRow(history, [transaction.date, "Beef", transaction.type === "incoming" ? "Incoming Stock" : "Consumption", formatQuantity(transaction.quantity), "kg", formatQuantity(transaction.remainingStock)]);
  }

  try {
    const saved = localStorage.getItem(storageKey);
    if (saved !== null) state = validateState(JSON.parse(saved));
  } catch {
    blockStorage("Saved inventory could not be loaded or validated. Existing data has not been overwritten. Transactions are disabled. Preserve the browser data and seek assistance before continuing.");
  }

  const today = new Date();
  const defaultDate = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, "0")}-${String(today.getDate()).padStart(2, "0")}`;
  for (const type of ["incoming", "consumption"]) {
    const form = getElement(`${type}-form`);
    getElement(`${type}-date`).value = defaultDate;
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      const message = getElement(`${type}-message`);
      message.textContent = "";
      message.className = "message";
      try {
        if (storageBlocked) throw new Error("Transactions are disabled because saved data is unavailable.");
        if (getElement(`${type}-ingredient`).value !== "beef") throw new Error("Select an existing ingredient.");
        const quantity = parseQuantity(getElement(`${type}-quantity`).value.trim());
        const date = getElement(`${type}-date`).value;
        if (!validDate(date)) throw new Error("Choose a valid transaction date.");
        if (type === "consumption" && quantity > state.stock) throw new Error("Consumption cannot exceed the available stock.");
        const remainingStock = state.stock + (type === "incoming" ? quantity : -quantity);
        if (!Number.isSafeInteger(remainingStock)) throw new Error("The resulting stock exceeds the supported range.");
        const nextState = { version: 1, stock: remainingStock, transactions: [...state.transactions, { date, ingredient: "beef", type, quantity, unit: "kg", remainingStock }] };
        try {
          const saved = localStorage.getItem(storageKey);
          if (saved !== null) validateState(JSON.parse(saved));
          const expected = state.transactions.length ? JSON.stringify(state) : null;
          if (saved !== expected && saved !== JSON.stringify(state)) throw new Error("Storage changed.");
        } catch {
          blockStorage("Browser data changed or became unavailable. No transaction was saved. Reload the page to validate the saved data before continuing.");
          throw new Error("No transaction was saved. Reload the page before continuing.");
        }
        try { localStorage.setItem(storageKey, JSON.stringify(nextState)); }
        catch { throw new Error("Unable to save to browser storage. No inventory or history changes were made."); }
        state = nextState;
        render();
        getElement(`${type}-quantity`).value = "";
        message.textContent = "Transaction recorded successfully.";
      } catch (error) {
        message.className = "message error";
        message.textContent = error.message;
      }
    });
  }
  render();
})();

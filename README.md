# Restaurant Inventory Management

A lightweight, English-only inventory website prototype for restaurant owners, developed as the first working part of the Restaurant ERP System internship project.

## Implemented Features

- View the current ingredient quantity and unit in an inventory table.
- Start with Beef, a fixed unit of kg, zero stock, and no transactions when no saved data exists.
- Record incoming stock and consumption with a quantity and transaction date.
- Reject consumption exceeding available stock and quantities that are nonpositive, have more than two decimal places, or exceed the supported numeric range.
- Calculate quantities in integer hundredths to avoid floating-point balance errors.
- View transaction history in insertion order, including the date, ingredient, transaction type, quantity, unit, and remaining stock.
- Save inventory and history in browser localStorage and restore them on reload.
- Validate saved data and preserve invalid data without silently overwriting it.
- Use a responsive single-page interface with accessible form labels.

Transaction dates are record labels. They do not recalculate historical balances or provide backdated inventory accounting. Failed transactions do not change inventory or history.

## Technology Stack

- HTML
- CSS
- Vanilla JavaScript
- Browser localStorage

No frontend framework, npm packages, external dependencies, backend, or database integration is used.

## Run Locally

1. Download the project files into one folder. Extract the archive first if downloading a ZIP.
2. Open `index.html` in a modern browser with JavaScript and localStorage enabled.
3. Use **Record Incoming Stock** or **Record Consumption** to enter transactions.

No installation or build step is required. Keep `index.html`, `styles.css`, and `app.js` together. Browser support for storage on local file URLs varies. If storage cannot be accessed or validated, the page displays an error and disables transactions.

## Current Limitations

- Only Beef is supported. Adding, editing, and deleting ingredients are not implemented.
- Data is stored only in the current browser and origin. There is no shared database or synchronization across users, browsers, or devices.
- Clearing browser storage can remove records. Moving to a hosted URL does not automatically transfer locally saved records.
- Storage capacity is limited, and saving can fail if storage is disabled or full.
- Simultaneous writes from multiple tabs are not guaranteed to be safe.
- Saved data can be modified through browser tools; there is no server-side validation.
- Invalid saved data is preserved and transactions are disabled; no in-app recovery workflow is provided.
- Large transaction histories can slow validation, saving, and rendering.
- Native date picker language may depend on browser or operating system settings.

## Prototype and Future ERP Scope

The implemented prototype covers inventory, incoming stock, consumption, transaction history, and browser persistence only.

The longer-term ERP plan includes a backend database, PDF invoice uploads with AI extraction into the database, business metrics, and forecasting. These features are **not implemented** and are not automatically part of the first-week deliverable. Future development requires explicit approval.

Authentication, supplier management, dashboards, and external API integration are outside the approved prototype scope. Final first-week acceptance criteria, submission format, and deadline remain unconfirmed.

## Validation Status

The user reported successful real-browser testing: six transactions resulted in a Beef balance of 15.00 kg, records persisted after refresh, excessive consumption was rejected, and quantities with more than two decimal places were rejected. Codex did not independently rerun those browser acceptance tests. The reported balance is a test outcome, not seeded data.

See `REQUIREMENTS.md` for approved business rules and limitations, and `AGENTS.md` for project working rules.

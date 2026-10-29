# Restaurant ERP System Requirements

## Mandatory Language Requirement (High Priority)
- The Restaurant ERP System must be an English-only website.
- All user-facing content must be in English, including navigation, page titles, buttons, tables, forms, validation messages, notifications, and error messages.
- All code identifiers, comments, database fields, and project documentation must also use English.
- Do not add Chinese text or multilingual functionality to the website unless explicitly approved by the user.

## Current Project State
Step 3 implementation of the first approved inventory website prototype is complete. Browser acceptance testing is complete as reported by the user. Step 4 requirements gap analysis is complete. No internship supervisor approval is established by these records.

## Overall Project Direction
The planned system manages restaurant ingredient quantities, daily incoming stock, daily consumption, and remaining stock. The overall plan includes a frontend website, backend database, PDF invoice uploads with AI extraction into the database, business metrics, and forecasting. These future plans are not first-week implementation requirements.

## Implemented Prototype Technology
- Plain HTML, CSS, and vanilla JavaScript; no framework, npm packages, or external dependencies.
- Browser localStorage for prototype persistence; no backend or database integration.
- Files: index.html, styles.css, app.js, AGENTS.md, and REQUIREMENTS.md.

## Implemented Prototype Features and Approved Business Rules
- A responsive, navigation-free single page titled "Restaurant Inventory Management" with readable tables and accessible form labels.
- Inventory columns: Ingredient, Quantity, Unit. Quantity is current remaining stock.
- Beef is the only initial ingredient, with fixed unit kg. A fresh installation starts with zero stock and no transactions; saved transactions are restored on reload. No ingredient creation, editing, or deletion.
- "Record Incoming Stock" and "Record Consumption" forms select the existing ingredient, accept a quantity and transaction date, and update remaining stock immediately after successful saving.
- Reject consumption above available stock. Quantities must be positive, have at most two decimal places, and use integer hundredths for arithmetic. Reject values beyond the safe integer range.
- Failed transactions must not change inventory or history.
- History columns: Date, Ingredient, Transaction Type, Quantity, Unit, Remaining Stock. Preserve insertion order.
- Dates are record labels, not instructions to recalculate historical balances. No backdated inventory accounting.
- Save inventory and history together in localStorage and restore them on reload.
- Validate saved structure, quantities, dates, transaction types, ingredient, unit, and sequential balances. Preserve corrupted data and disable transactions with an English error instead of silently overwriting it.
- Handle unavailable storage and failed writes without committing inventory changes.
- All website content and implementation identifiers and comments are English.

## Approved Prototype Exclusions
No dashboards, analytics pages, forecasting, PDF invoice scanning, authentication, supplier management, external APIs, additional business features, dependencies, or deployment.

## User-Reported Browser Acceptance Results
The following results were reported by the user from testing in a real browser. Codex did not independently rerun these browser tests.
- PASS (user-reported): Six inventory transactions produce a final Beef balance of 15.00 kg.
- PASS (user-reported): Inventory and transaction history persist after refresh.
- PASS (user-reported): Excessive consumption is rejected.
- PASS (user-reported): Quantities with more than two decimal places are rejected.
- Additional user-reported confirmations: inventory calculations are correct, transaction history displays correctly, and the website interface is in English.

The six transaction details were not supplied here and are not invented. The 15.00 kg result is a test outcome, not the initial stock or seeded history. These results do not establish internship supervisor approval or final first-week acceptance.

## Local Use and Limitations
Open index.html in a browser with JavaScript and localStorage enabled. File URL storage support varies by browser; if storage is unavailable, the page reports an error and disables transactions. Data belongs to the current browser and origin; clearing browser data can remove it. This prototype does not provide shared storage, backend validation, or database integration.

Additional known limitations:
- localStorage has finite capacity, and disabled storage or failed writes can prevent saving.
- Records are not shared across devices or browsers and have no server-side trust guarantees.
- Pre-save change checks do not guarantee safe simultaneous writes from multiple tabs.
- The complete history is validated, serialized, and rendered during transactions, which may slow down as records grow.
- Corrupted records are preserved and transactions are disabled; there is no approved in-app recovery workflow.
- Native date picker language may follow browser or operating system settings despite the English page language.

## Decisions Requiring Future Approval
- Any additional feature, ingredient management, backend, database, dependency, framework, or deployment.
- First-week final acceptance criteria, submission format, and deadline remain unconfirmed.
- Details of future invoice extraction, metrics, and forecasting remain unconfirmed.

## Next-Step Authorization
The approved prototype implementation and requirements gap analysis are complete. Future development must be authorized one small step at a time. Do not expand the prototype to full ERP scope without explicit approval. Test and report future code changes, then stop and wait for approval before proceeding.


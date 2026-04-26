### Cosmos DB `status` Field Addition — Ripley

**Date:** 2025-07-25 | **Status:** Implemented

**Change:** Added `"status": "classified"` field to the Cosmos DB document body in `Create_or_Update_Cosmos_Document` action.

**Rationale:** By the time the Logic App writes the document to Cosmos DB, the email has been through the full processing pipeline — attachments extracted, Content Understanding analyzed (if PDF), and classification completed (or skipped). The `status` field captures this final state explicitly. Currently static (`"classified"`), but opens the door for future states (e.g., `"pending"`, `"error"`) if the pipeline becomes more complex.

**Impact:**
- **Lambert:** Cosmos documents now include a `status` field (string). Could be used for UI filtering/display.
- **Kane:** Test fixtures should include `status: "classified"` in mock email documents.
- **Schema:** No Cosmos container changes needed — schemaless NoSQL, field is additive.

**Files Modified:**
- `logic-app/workflow.json` — added field at line 288

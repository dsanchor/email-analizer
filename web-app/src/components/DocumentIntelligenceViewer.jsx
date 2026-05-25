import { useState } from "react";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function formatFieldName(name) {
  if (!name) return "";
  return name
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2")
    .replace(/_/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

// Document Intelligence field → primitive display value (or null when nested)
function extractDIValue(field) {
  if (!field) return null;
  if (field.content != null && typeof field.content === "string" && !field.valueObject && !field.valueArray) {
    // Prefer the raw extracted content text when it's a leaf field
    if (
      field.valueString == null &&
      field.valueDate == null &&
      field.valueNumber == null &&
      field.valueInteger == null &&
      field.valueCountryRegion == null &&
      field.valuePhoneNumber == null &&
      field.valueSelectionMark == null
    ) {
      return field.content;
    }
  }
  if (field.valueString != null) return field.valueString;
  if (field.valueDate != null) return field.valueDate;
  if (field.valueNumber != null) return field.valueNumber;
  if (field.valueInteger != null) return field.valueInteger;
  if (field.valueCountryRegion != null) return field.valueCountryRegion;
  if (field.valuePhoneNumber != null) return field.valuePhoneNumber;
  if (field.valueSelectionMark != null) return field.valueSelectionMark;
  if (field.valueBoolean != null) return String(field.valueBoolean);
  if (field.valueAddress) {
    // Flatten address object to a single readable line
    const a = field.valueAddress;
    return [a.streetAddress, a.city, a.state, a.postalCode, a.countryRegion]
      .filter(Boolean)
      .join(", ");
  }
  if (field.content != null) return field.content;
  return null;
}

function formatValue(val) {
  if (val == null || val === "") return "\u2014";
  if (typeof val === "boolean") return val ? "Yes" : "No";
  return String(val);
}

function isObjectField(field) {
  return field && field.type === "object" && field.valueObject;
}

function isArrayField(field) {
  return field && field.type === "array" && field.valueArray;
}

// ---------------------------------------------------------------------------
// Sub-components (reuse the CU CSS namespace for consistent look & feel)
// ---------------------------------------------------------------------------

function ConfidenceDot({ confidence }) {
  if (confidence == null) return null;
  const pct = Math.round(confidence * 100);
  const color = pct >= 90 ? "#34c759" : pct >= 70 ? "#ff9f0a" : "#ff3b30";
  return (
    <span className="cu-confidence" title={`${pct}% confidence`}>
      <span className="cu-confidence__dot" style={{ background: color }} />
      <span className="cu-confidence__pct">{pct}%</span>
    </span>
  );
}

function SimpleFieldRow({ name, field, indent = 0 }) {
  const val = extractDIValue(field);
  return (
    <tr className="cu-field-row">
      <td className="cu-field-name" style={{ paddingLeft: `${16 + indent * 20}px` }}>
        {formatFieldName(name)}
      </td>
      <td className="cu-field-value">
        <code>{formatValue(val)}</code>
        <ConfidenceDot confidence={field.confidence} />
      </td>
    </tr>
  );
}

function ObjectFieldRows({ name, field, indent = 0 }) {
  const entries = Object.entries(field.valueObject || {});
  return (
    <>
      <tr className="cu-field-row cu-field-row--group">
        <td
          className="cu-field-name cu-field-name--group"
          colSpan={2}
          style={{ paddingLeft: `${16 + indent * 20}px` }}
        >
          {formatFieldName(name)}
        </td>
      </tr>
      {entries.map(([subKey, subField]) => (
        <FieldRows key={subKey} name={subKey} field={subField} indent={indent + 1} />
      ))}
    </>
  );
}

function ArrayFieldRows({ name, field, indent = 0 }) {
  const arr = field.valueArray || [];
  if (arr.length === 0) {
    return (
      <tr className="cu-field-row">
        <td className="cu-field-name" style={{ paddingLeft: `${16 + indent * 20}px` }}>
          {formatFieldName(name)}
        </td>
        <td className="cu-field-value"><code>{"\u2014"}</code></td>
      </tr>
    );
  }
  return (
    <>
      <tr className="cu-field-row cu-field-row--group">
        <td
          className="cu-field-name cu-field-name--group"
          colSpan={2}
          style={{ paddingLeft: `${16 + indent * 20}px` }}
        >
          {formatFieldName(name)}
          <span className="cu-field-count">{arr.length}</span>
        </td>
      </tr>
      {arr.map((item, idx) => (
        <FieldRows
          key={idx}
          name={`#${idx + 1}`}
          field={item}
          indent={indent + 1}
        />
      ))}
    </>
  );
}

function FieldRows({ name, field, indent = 0 }) {
  if (isArrayField(field)) {
    return <ArrayFieldRows name={name} field={field} indent={indent} />;
  }
  if (isObjectField(field)) {
    return <ObjectFieldRows name={name} field={field} indent={indent} />;
  }
  return <SimpleFieldRow name={name} field={field} indent={indent} />;
}

// ---------------------------------------------------------------------------
// Document Section
// ---------------------------------------------------------------------------

function DocumentSection({ doc, defaultOpen }) {
  const [open, setOpen] = useState(defaultOpen);
  const fields = doc.fields || {};
  const fieldCount = Object.keys(fields).length;
  if (fieldCount === 0) return null;
  return (
    <div className={`cu-segment ${open ? "cu-segment--open" : ""}`}>
      <button
        className="cu-segment__header"
        onClick={() => setOpen((o) => !o)}
        type="button"
      >
        <svg
          className="cu-segment__chevron"
          width="10"
          height="10"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2.5"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <polyline points="9,6 15,12 9,18" />
        </svg>
        <span className="cu-segment__category">
          {formatFieldName(doc.docType || "Document")}
        </span>
        <ConfidenceDot confidence={doc.confidence} />
        <span className="cu-segment__field-count">{fieldCount} fields</span>
      </button>
      {open && (
        <div className="cu-segment__body">
          <table className="cu-fields-table">
            <thead>
              <tr>
                <th className="cu-fields-table__th">Field</th>
                <th className="cu-fields-table__th">Value</th>
              </tr>
            </thead>
            <tbody>
              {Object.entries(fields).map(([key, field]) => (
                <FieldRows key={key} name={key} field={field} indent={0} />
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

export default function DocumentIntelligenceViewer({ data }) {
  const [showRaw, setShowRaw] = useState(false);
  if (!data || !data.analyzeResult) return null;

  const documents = data.analyzeResult.documents || [];
  const modelId = data.analyzeResult.modelId || "document-intelligence";
  const status = data.status || "";
  const succeeded = status.toLowerCase() === "succeeded";

  return (
    <div className="cu-viewer">
      <div className="cu-viewer__header">
        <svg
          className="cu-viewer__icon"
          width="14"
          height="14"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <rect x="4" y="3" width="16" height="18" rx="2" />
          <path d="M8 7h8M8 11h8M8 15h5" />
        </svg>
        <span className="cu-viewer__title">ID Document Analysis</span>
        <span className="cu-segment__analyzer">{modelId}</span>
        <span className={`cu-viewer__status ${succeeded ? "cu-viewer__status--ok" : ""}`}>
          {status}
        </span>
        <button
          className="cu-viewer__toggle"
          onClick={() => setShowRaw((v) => !v)}
          type="button"
        >
          {showRaw ? "Structured" : "Raw JSON"}
        </button>
      </div>
      {showRaw ? (
        <pre className="cu-viewer__raw">{JSON.stringify(data, null, 2)}</pre>
      ) : documents.length === 0 ? (
        <div className="cu-viewer__segments">
          <div className="cu-segment">
            <div className="cu-segment__body">
              <p style={{ padding: "12px 16px", margin: 0, opacity: 0.7 }}>
                No structured documents were detected.
              </p>
            </div>
          </div>
        </div>
      ) : (
        <div className="cu-viewer__segments">
          {documents.map((doc, i) => (
            <DocumentSection key={i} doc={doc} defaultOpen={i === 0} />
          ))}
        </div>
      )}
    </div>
  );
}

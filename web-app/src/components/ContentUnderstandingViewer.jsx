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

function extractValue(field) {
  if (!field) return null;
  if (field.valueString != null) return field.valueString;
  if (field.valueInteger != null) return field.valueInteger;
  if (field.valueNumber != null) return field.valueNumber;
  if (field.valueDate != null) return field.valueDate;
  if (field.valueBoolean != null) return String(field.valueBoolean);
  return null;
}

function formatValue(val) {
  if (val == null) return "\u2014";
  if (typeof val === "boolean") return val ? "Yes" : "No";
  return String(val);
}

function isObjectField(field) {
  return field && field.type === "object" && field.valueObject;
}

function isArrayField(field) {
  return field && field.type === "array" && field.valueArray;
}

function isArrayOfObjects(arr) {
  return arr.length > 0 && arr.every((item) => item.type === "object" && item.valueObject);
}

function getArrayColumnKeys(arr) {
  const keys = new Set();
  arr.forEach((item) => {
    if (item.valueObject) {
      Object.keys(item.valueObject).forEach((k) => keys.add(k));
    }
  });
  return [...keys];
}

// ---------------------------------------------------------------------------
// Sub-components
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
  const val = extractValue(field);
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
  const entries = Object.entries(field.valueObject);
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
  const arr = field.valueArray;

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

  if (isArrayOfObjects(arr)) {
    const cols = getArrayColumnKeys(arr);
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
        <tr className="cu-field-row">
          <td colSpan={2} style={{ padding: `0 ${16 + indent * 20}px 0` }}>
            <div className="cu-array-table-wrap">
              <table className="cu-array-table">
                <thead>
                  <tr>
                    {cols.map((col) => (
                      <th key={col} className="cu-array-table__th">
                        {formatFieldName(col)}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {arr.map((item, idx) => (
                    <tr key={idx} className="cu-array-table__row">
                      {cols.map((col) => {
                        const cellField = item.valueObject[col];
                        const val = cellField ? extractValue(cellField) : null;
                        return (
                          <td key={col} className="cu-array-table__td">
                            <code>{formatValue(val)}</code>
                          </td>
                        );
                      })}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </td>
        </tr>
      </>
    );
  }

  // Simple array — comma-separated
  const values = arr.map((item) => formatValue(extractValue(item))).join(", ");
  return (
    <tr className="cu-field-row">
      <td className="cu-field-name" style={{ paddingLeft: `${16 + indent * 20}px` }}>
        {formatFieldName(name)}
      </td>
      <td className="cu-field-value"><code>{values}</code></td>
    </tr>
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
// Segment
// ---------------------------------------------------------------------------

function SegmentSection({ content }) {
  const [open, setOpen] = useState(false);
  const { category, analyzerId, fields } = content;

  if (!fields || Object.keys(fields).length === 0) return null;

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
        <span className="cu-segment__category">{formatFieldName(category)}</span>
        {analyzerId && (
          <span className="cu-segment__analyzer">{analyzerId}</span>
        )}
        <span className="cu-segment__field-count">
          {Object.keys(fields).length} fields
        </span>
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

export default function ContentUnderstandingViewer({ data }) {
  const [showRaw, setShowRaw] = useState(false);

  if (!data || !data.result || !data.result.contents) return null;

  const segments = data.result.contents.filter(
    (c) => c.fields && Object.keys(c.fields).length > 0
  );

  if (segments.length === 0) return null;

  const succeeded = data.status === "Succeeded";

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
          <circle cx="11" cy="11" r="8" />
          <path d="M21 21l-4.35-4.35" />
          <path d="M11 8v6" />
          <path d="M8 11h6" />
        </svg>
        <span className="cu-viewer__title">Analysis Results</span>
        <span className={`cu-viewer__status ${succeeded ? "cu-viewer__status--ok" : ""}`}>
          {data.status}
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
      ) : (
        <div className="cu-viewer__segments">
          {segments.map((seg, i) => (
            <SegmentSection key={seg.path || i} content={seg} />
          ))}
        </div>
      )}
    </div>
  );
}

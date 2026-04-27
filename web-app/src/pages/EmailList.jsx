import { useState, useEffect, useCallback, useMemo } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function getLatestStatus(email) {
  if (email.statusHistory && email.statusHistory.length > 0) {
    return email.statusHistory[email.statusHistory.length - 1].status;
  }
  if (email.status) return email.status;
  return null;
}

function statusBadgeClass(status) {
  if (!status) return "status-badge status-badge--empty";
  const s = status.toLowerCase();
  if (s.includes("classified")) return "status-badge status-badge--classified";
  if (s.includes("attachment") || s.includes("processed")) return "status-badge status-badge--processed";
  return "status-badge status-badge--received";
}

function extractFromDisplay(value) {
  if (value && typeof value === "object") {
    const ea = value.emailAddress || {};
    return ea.name || ea.address || "Unknown";
  }
  if (typeof value === "string") return value || "Unknown";
  return "Unknown";
}

function formatDate(value) {
  if (!value) return "";
  try {
    const dt = new Date(value);
    return dt.toLocaleDateString("en-US", {
      month: "short",
      day: "numeric",
      year: "numeric",
      hour: "numeric",
      minute: "2-digit",
    });
  } catch {
    return value;
  }
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------
export default function EmailList() {
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const q = searchParams.get("q") || "";

  const [emails, setEmails] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [sortCol, setSortCol] = useState("date");
  const [sortAsc, setSortAsc] = useState(false);
  const [searchInput, setSearchInput] = useState(q);

  // Fetch emails
  useEffect(() => {
    setLoading(true);
    setError(null);
    const url = q ? `/api/emails?q=${encodeURIComponent(q)}` : "/api/emails";
    fetch(url)
      .then((res) => {
        if (!res.ok) throw new Error("Failed to load emails");
        return res.json();
      })
      .then((data) => {
        setEmails(data);
        setLoading(false);
      })
      .catch((err) => {
        setError(err.message);
        setLoading(false);
      });
  }, [q]);

  // Sort
  const sorted = useMemo(() => {
    const arr = [...emails];
    arr.sort((a, b) => {
      let aVal, bVal;
      if (sortCol === "date") {
        aVal = a.receivedDateTime || "";
        bVal = b.receivedDateTime || "";
      } else if (sortCol === "from") {
        aVal = extractFromDisplay(a.from).toLowerCase();
        bVal = extractFromDisplay(b.from).toLowerCase();
      } else if (sortCol === "type") {
        aVal = (a.classification?.type || "").toLowerCase();
        bVal = (b.classification?.type || "").toLowerCase();
      } else if (sortCol === "score") {
        aVal = a.classification?.score ?? -1;
        bVal = b.classification?.score ?? -1;
      } else if (sortCol === "status") {
        aVal = (getLatestStatus(a) || "").toLowerCase();
        bVal = (getLatestStatus(b) || "").toLowerCase();
      } else {
        aVal = (a.subject || "").toLowerCase();
        bVal = (b.subject || "").toLowerCase();
      }
      if (aVal < bVal) return sortAsc ? -1 : 1;
      if (aVal > bVal) return sortAsc ? 1 : -1;
      return 0;
    });
    return arr;
  }, [emails, sortCol, sortAsc]);

  const handleSort = useCallback(
    (col) => {
      if (col === sortCol) {
        setSortAsc((prev) => !prev);
      } else {
        setSortCol(col);
        setSortAsc(true);
      }
    },
    [sortCol]
  );

  const handleSearch = (e) => {
    e.preventDefault();
    const trimmed = searchInput.trim();
    if (trimmed) {
      setSearchParams({ q: trimmed });
    } else {
      setSearchParams({});
    }
  };

  const handleDelete = async (id) => {
    if (!window.confirm("Are you sure you want to remove this email?")) return;
    try {
      const res = await fetch(`/api/emails/${encodeURIComponent(id)}`, { method: "DELETE" });
      if (!res.ok) throw new Error("Failed to delete");
      setEmails((prev) => prev.filter((e) => e.id !== id));
    } catch (err) {
      alert("Could not remove email. Please try again.");
    }
  };

  const clearSearch = () => {
    setSearchInput("");
    setSearchParams({});
  };

  function SortArrow({ col }) {
    const active = sortCol === col;
    return (
      <span className={`sort-arrow${active ? " sort-arrow--active" : ""}`}>
        {active ? (sortAsc ? "▲" : "▼") : ""}
      </span>
    );
  }

  if (error) {
    return (
      <div className="error">
        <div className="container">
          <div className="error__code">503</div>
          <div className="error__label">Service Unavailable</div>
          <p className="error__message">{error}</p>
          <div className="error__actions">
            <button className="btn" onClick={() => window.location.reload()}>
              Try again
            </button>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="inbox">
      <div className="container">
        <div className="inbox__header">
          <div className="inbox__title-row">
            <h1 className="inbox__title">Inbox</h1>
            {!loading && (
              <span className="inbox__count">
                {emails.length} email{emails.length !== 1 ? "s" : ""}
                {q ? ` matching "${q}"` : ""}
              </span>
            )}
          </div>
          <form className="inbox__search" onSubmit={handleSearch}>
            <svg
              className="inbox__search-icon"
              width="16"
              height="16"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
              aria-hidden="true"
            >
              <circle cx="11" cy="11" r="8" />
              <line x1="21" y1="21" x2="16.65" y2="16.65" />
            </svg>
            <input
              type="text"
              className="inbox__search-input"
              placeholder="Filter emails…"
              value={searchInput}
              onChange={(e) => setSearchInput(e.target.value)}
              aria-label="Filter emails"
            />
            {q && (
              <button
                type="button"
                className="inbox__search-clear"
                onClick={clearSearch}
                aria-label="Clear filter"
              >
                ×
              </button>
            )}
          </form>
        </div>

        {loading ? (
          <div className="empty">
            <p className="empty__title">Loading…</p>
          </div>
        ) : sorted.length > 0 ? (
          <div className="table-wrap">
            <table className="email-table" id="emailTable">
              <thead>
                <tr>
                  <th
                    className="email-table__th email-table__th--date sortable"
                    onClick={() => handleSort("date")}
                  >
                    Date <SortArrow col="date" />
                  </th>
                  <th
                    className="email-table__th email-table__th--from sortable"
                    onClick={() => handleSort("from")}
                  >
                    From <SortArrow col="from" />
                  </th>
                  <th
                    className="email-table__th email-table__th--subject sortable"
                    onClick={() => handleSort("subject")}
                  >
                    Subject <SortArrow col="subject" />
                  </th>
                  <th
                    className="email-table__th email-table__th--type sortable"
                    onClick={() => handleSort("type")}
                  >
                    Type <SortArrow col="type" />
                  </th>
                  <th
                    className="email-table__th email-table__th--score sortable"
                    onClick={() => handleSort("score")}
                  >
                    Score <SortArrow col="score" />
                  </th>
                  <th
                    className="email-table__th email-table__th--status sortable"
                    onClick={() => handleSort("status")}
                  >
                    Status <SortArrow col="status" />
                  </th>
                  <th className="email-table__th email-table__th--actions"></th>
                </tr>
              </thead>
              <tbody>
                {sorted.map((email) => (
                  <tr
                    key={email.id}
                    className="email-table__row"
                    onClick={() => navigate(`/emails/${email.id}`)}
                    role="link"
                    tabIndex={0}
                    onKeyDown={(e) => {
                      if (e.key === "Enter") navigate(`/emails/${email.id}`);
                    }}
                  >
                    <td
                      className="email-table__td email-table__td--date"
                      data-sort={email.receivedDateTime || ""}
                    >
                      {formatDate(email.receivedDateTime)}
                    </td>
                    <td className="email-table__td email-table__td--from">
                      {extractFromDisplay(email.from)}
                    </td>
                    <td className="email-table__td email-table__td--subject">
                      <span className="email-table__subject-text">
                        {email.subject}
                      </span>
                      {email.hasAttachments && (
                        <svg
                          className="email-table__clip"
                          width="14"
                          height="14"
                          viewBox="0 0 24 24"
                          fill="none"
                          stroke="currentColor"
                          strokeWidth="2"
                          strokeLinecap="round"
                          strokeLinejoin="round"
                          aria-label="Has attachments"
                        >
                          <path d="M21.44,11.05l-9.19,9.19a6,6,0,0,1-8.49-8.49l9.19-9.19a4,4,0,0,1,5.66,5.66l-9.2,9.19a2,2,0,0,1-2.83-2.83l8.49-8.48" />
                        </svg>
                      )}
                    </td>
                    <td className="email-table__td email-table__td--type">
                      {email.classification ? (
                        <span
                          className={`classification-badge${
                            email.classification.type === "unknown"
                              ? " classification-badge--unknown"
                              : ""
                          }`}
                        >
                          {email.classification.type}
                        </span>
                      ) : (
                        <span className="classification-badge classification-badge--empty">
                          —
                        </span>
                      )}
                    </td>
                    <td className="email-table__td email-table__td--score">
                      {email.classification ? email.classification.score : "—"}
                    </td>
                    <td className="email-table__td email-table__td--status">
                      {(() => {
                        const latest = getLatestStatus(email);
                        return latest ? (
                          <span className={statusBadgeClass(latest)}>{latest}</span>
                        ) : (
                          <span className="status-badge status-badge--empty">—</span>
                        );
                      })()}
                    </td>
                    <td className="email-table__td email-table__td--actions">
                      <button
                        className="btn-delete"
                        onClick={(e) => {
                          e.stopPropagation();
                          handleDelete(email.id);
                        }}
                        aria-label={`Delete email: ${email.subject}`}
                        title="Remove"
                      >
                        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                          <polyline points="3 6 5 6 21 6" />
                          <path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6" />
                          <path d="M10 11v6" />
                          <path d="M14 11v6" />
                          <path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2" />
                        </svg>
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <div className="empty">
            <p className="empty__title">
              {q ? "No emails match your filter" : "No emails yet"}
            </p>
            <p className="empty__text">
              {q
                ? "Try a different search term"
                : "Emails will appear here when they arrive"}
            </p>
            {q && (
              <button className="btn" onClick={clearSearch}>
                Clear filter
              </button>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

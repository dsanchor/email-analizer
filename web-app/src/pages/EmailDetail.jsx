import { useState, useEffect } from "react";
import { useParams, Link, useSearchParams } from "react-router-dom";
import DOMPurify from "dompurify";
import ContentUnderstandingViewer from "../components/ContentUnderstandingViewer";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function extractFrom(value) {
  if (value && typeof value === "object") {
    const ea = value.emailAddress || {};
    return { name: ea.name || "", address: ea.address || "" };
  }
  if (typeof value === "string") return { name: "", address: value };
  return { name: "", address: "Unknown" };
}

function extractRecipients(value) {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) {
    const names = value
      .map((item) => {
        if (typeof item === "object") {
          const ea = item.emailAddress || {};
          return ea.name || ea.address || "";
        }
        if (typeof item === "string") return item;
        return "";
      })
      .filter(Boolean);
    return names.join(", ") || "Unknown";
  }
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

function humanSize(sizeBytes) {
  if (sizeBytes == null) return "";
  let size = Number(sizeBytes);
  for (const unit of ["B", "KB", "MB", "GB"]) {
    if (size < 1024) {
      return unit === "B" ? `${Math.round(size)} ${unit}` : `${size.toFixed(1)} ${unit}`;
    }
    size /= 1024;
  }
  return `${size.toFixed(1)} TB`;
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------
export default function EmailDetail() {
  const { id } = useParams();
  const [searchParams] = useSearchParams();
  const [email, setEmail] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    setLoading(true);
    setError(null);
    fetch(`/api/emails/${encodeURIComponent(id)}`)
      .then((res) => {
        if (res.status === 404) throw new Error("Email not found");
        if (!res.ok) throw new Error("Failed to load email");
        return res.json();
      })
      .then((data) => {
        setEmail(data);
        setLoading(false);
      })
      .catch((err) => {
        setError(err.message);
        setLoading(false);
      });
  }, [id]);

  if (loading) {
    return (
      <div className="empty">
        <p className="empty__title">Loading…</p>
      </div>
    );
  }

  if (error) {
    const code = error === "Email not found" ? 404 : 503;
    return (
      <div className="error">
        <div className="container">
          <div className="error__code">{code}</div>
          <div className="error__label">
            {code === 404 ? "Not Found" : "Service Unavailable"}
          </div>
          <p className="error__message">{error}</p>
          <div className="error__actions">
            <button className="btn" onClick={() => window.location.reload()}>
              Try again
            </button>
            <Link to="/emails" className="btn btn--outline">
              Back to Inbox
            </Link>
          </div>
        </div>
      </div>
    );
  }

  const fromInfo = extractFrom(email.from);
  const recipients = extractRecipients(email.toRecipients);
  const backQuery = searchParams.get("q");
  const backUrl = backQuery ? `/emails?q=${encodeURIComponent(backQuery)}` : "/emails";

  // Body is already sanitized server-side; DOMPurify as defense-in-depth
  const safeBody = DOMPurify.sanitize(email.body || "<p>No content</p>");

  return (
    <div className="detail">
      <div className="container">
        <Link to={backUrl} className="detail__back">
          <svg
            width="12"
            height="12"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2.5"
            strokeLinecap="round"
            strokeLinejoin="round"
            aria-hidden="true"
          >
            <polyline points="15,18 9,12 15,6" />
          </svg>
          Back to Inbox
        </Link>

        <header className="detail__header">
          <h1 className="detail__subject">{email.subject}</h1>
          <div className="detail__meta">
            <div className="detail__meta-row">
              <span className="detail__label">From</span>
              <span className="detail__value">
                {fromInfo.name ? (
                  <>
                    {fromInfo.name}{" "}
                    <span className="detail__secondary">
                      &lt;{fromInfo.address}&gt;
                    </span>
                  </>
                ) : (
                  fromInfo.address || "Unknown"
                )}
              </span>
            </div>
            <div className="detail__meta-row">
              <span className="detail__label">To</span>
              <span className="detail__value">{recipients}</span>
            </div>
            <div className="detail__meta-row">
              <span className="detail__label">Date</span>
              <span className="detail__value">
                {formatDate(email.receivedDateTime)}
              </span>
            </div>
          </div>
        </header>

        <div
          className="detail__body"
          dangerouslySetInnerHTML={{ __html: safeBody }}
        />

        {email.attachments && email.attachments.length > 0 && (
          <div className="detail__attachments">
            <h2 className="detail__attachments-title">
              Attachments
              <span className="detail__attachments-count">
                {email.attachments.length}
              </span>
            </h2>
            <div className="attachment-list">
              {email.attachments.map((att) => (
                <div key={att.name} className="attachment-item">
                  <a
                    href={`/api/emails/${email.id}/attachments/${encodeURIComponent(att.name)}`}
                    className="attachment"
                  >
                    <svg
                      className="attachment__icon"
                      width="18"
                      height="18"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      strokeWidth="1.5"
                      strokeLinecap="round"
                      strokeLinejoin="round"
                      aria-hidden="true"
                    >
                      <path d="M14,2 L6,2 C4.9,2 4,2.9 4,4 L4,20 C4,21.1 4.9,22 6,22 L18,22 C19.1,22 20,21.1 20,20 L20,8 Z" />
                      <polyline points="14,2 14,8 20,8" />
                    </svg>
                    <span className="attachment__name">{att.name}</span>
                    <span className="attachment__size">
                      {humanSize(att.size)}
                    </span>
                    <span className="attachment__download">Download</span>
                  </a>
                  {att.contentUnderstanding && (
                    <ContentUnderstandingViewer data={att.contentUnderstanding} />
                  )}
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

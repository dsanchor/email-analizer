import { Link } from "react-router-dom";

export default function ErrorPage({ code = 404, message = "Something went wrong" }) {
  const label =
    code === 404
      ? "Page Not Found"
      : code === 500
      ? "Server Error"
      : code === 503
      ? "Service Unavailable"
      : "Something went wrong";

  return (
    <div className="error">
      <div className="container">
        <div className="error__code">{code}</div>
        <div className="error__label">{label}</div>
        <p className="error__message">{message}</p>
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

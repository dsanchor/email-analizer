import { Outlet, Link } from "react-router-dom";

export default function Layout() {
  return (
    <>
      <nav className="nav" role="navigation" aria-label="Main navigation">
        <div className="nav__inner">
          <Link to="/emails" className="nav__brand" aria-label="Inbox Home">
            Inbox
          </Link>
        </div>
      </nav>

      <main className="main">
        <Outlet />
      </main>

      <footer className="footer"></footer>
    </>
  );
}

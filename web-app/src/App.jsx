import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";
import Layout from "./components/Layout";
import EmailList from "./pages/EmailList";
import EmailDetail from "./pages/EmailDetail";
import ErrorPage from "./pages/ErrorPage";

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route element={<Layout />}>
          <Route path="/" element={<Navigate to="/emails" replace />} />
          <Route path="/emails" element={<EmailList />} />
          <Route path="/emails/:id" element={<EmailDetail />} />
          <Route path="*" element={<ErrorPage code={404} message="Not Found" />} />
        </Route>
      </Routes>
    </BrowserRouter>
  );
}

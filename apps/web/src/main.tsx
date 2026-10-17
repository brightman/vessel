import { DialogsProvider } from "./components/dialogs";
import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import "./styles.css";
import "./console.css";
import "./ui.css";

createRoot(document.getElementById("root")!).render(<React.StrictMode><DialogsProvider><App /></DialogsProvider></React.StrictMode>);

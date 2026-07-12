import "./styles.css";
import { setupPairingCode } from "./shared/pairing-code";
import type { RuntimeRequest } from "./shared/types";

const connection = element("connection");
const status = element("status");
const pairingCode = setupPairingCode(element("pair-code"));

element("pair-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  status.textContent = "Pairing…";
  try {
    const code = pairingCode.value();
    await send({ type: "pair", code });
    connection.textContent = "Connected to Refman.";
    status.textContent = "Extension paired successfully.";
  } catch (error) {
    status.classList.add("error");
    status.textContent = error instanceof Error ? error.message : "Pairing failed.";
  }
});

void send<{ available: boolean; paired: boolean }>({ type: "connection" })
  .then((value) => {
    connection.textContent = !value.available
      ? "Refman is not running."
      : value.paired ? "Connected to Refman." : "Refman is running but not paired.";
  })
  .catch(() => { connection.textContent = "Refman is not running."; });

async function send<T = unknown>(request: RuntimeRequest): Promise<T> {
  const response = await chrome.runtime.sendMessage(request) as T & { error?: string };
  if (response?.error) throw new Error(response.error);
  return response;
}

function element<T extends HTMLElement = HTMLElement>(id: string): T {
  const value = document.getElementById(id);
  if (!value) throw new Error(`Missing element ${id}`);
  return value as T;
}

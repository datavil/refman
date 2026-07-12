import "./styles.css";
import { setupPairingCode } from "./shared/pairing-code";
import type { Collection, Detection, ImportResult, RuntimeRequest } from "./shared/types";

const pairing = element("pairing");
const capture = element("capture");
const result = element("result");
const status = element("status");
const saveButton = element<HTMLButtonElement>("save");
const collection = element<HTMLSelectElement>("collection");
const pairingCode = setupPairingCode(element("pair-code"));
let detection: Detection | undefined;
let resultUUID: string | undefined;

element("settings").addEventListener("click", () => chrome.runtime.openOptionsPage());
element("pair-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const code = pairingCode.value();
  await run(async () => {
    await send({ type: "pair", code });
    pairing.classList.add("hidden");
    await loadCapture();
  }, "Pairing…");
});

saveButton.addEventListener("click", async () => {
  const current = detection;
  if (!current) return;
  await run(async () => {
    const pdfURL = current.metadata?.pdfURL ?? (current.kind === "pdf" ? current.url : undefined);
    if (pdfURL) {
      const origin = `${new URL(pdfURL).origin}/*`;
      const granted = await chrome.permissions.request({ origins: [origin] });
      if (!granted) throw new Error("Allow access to this PDF to save it.");
    }
    const collectionId = collection.value ? Number(collection.value) : undefined;
    const imported = await send<ImportResult>({ type: "save", detection: current, collectionId });
    showResult(imported);
  }, "Saving to Refman…");
});

element("open").addEventListener("click", async () => {
  if (!resultUUID) return;
  await run(() => send({ type: "open", uuid: resultUUID! }), "Opening Refman…");
});

void initialize();

async function initialize(): Promise<void> {
  try {
    const connection = await send<{ available: boolean; paired: boolean }>({ type: "connection" });
    if (!connection.paired) {
      status.textContent = connection.available ? "Refman is ready to pair." : "Open Refman to pair.";
      pairing.classList.remove("hidden");
      return;
    }
    await loadCapture();
  } catch (error) {
    fail(error);
    pairing.classList.remove("hidden");
  }
}

async function loadCapture(): Promise<void> {
  status.textContent = "Reading this page…";
  const [found, collections] = await Promise.all([
    send<Detection>({ type: "detect" }),
    send<Collection[]>({ type: "collections" })
  ]);
  detection = found;
  element("source-type").textContent = found.label;
  element("pdf-available").classList.toggle(
    "hidden", found.kind !== "pdf" && !found.metadata?.pdfURL);
  element("title").textContent = found.metadata?.title || found.fileName || "Current page";
  element("authors").textContent = found.metadata?.authors.map((author) =>
    [author.given, author.family].filter(Boolean).join(" ")).join(", ") ?? "";
  for (const item of collections) {
    const option = document.createElement("option");
    option.value = String(item.id);
    option.textContent = item.name;
    collection.append(option);
  }
  const supported = found.kind !== "unsupported";
  saveButton.disabled = !supported;
  saveButton.textContent = found.kind === "pdf"
    ? "Save PDF to Refman"
    : found.metadata?.pdfURL ? "Save Article" : "Save to Refman";
  capture.classList.remove("hidden");
  status.textContent = supported ? "" : found.label;
}

function showResult(imported: ImportResult): void {
  resultUUID = imported.documentUUID;
  capture.classList.add("hidden");
  result.classList.remove("hidden");
  element("result-title").textContent = imported.status === "duplicate" ? "Already saved" : "Saved";
  element("result-message").textContent = imported.title || imported.message;
  element("result-icon").classList.toggle("duplicate", imported.status === "duplicate");
  element("result-icon").textContent = imported.status === "duplicate" ? "=" : "✓";
  element<HTMLButtonElement>("open").disabled = !imported.documentUUID;
  status.textContent = imported.message;
}

async function run(action: () => Promise<unknown>, message: string): Promise<void> {
  status.classList.remove("error");
  status.textContent = message;
  saveButton.disabled = true;
  try {
    await action();
    if (!resultUUID) status.textContent = "";
  } catch (error) {
    fail(error);
  } finally {
    saveButton.disabled = detection?.kind === "unsupported";
  }
}

function fail(error: unknown): void {
  status.classList.add("error");
  status.textContent = error instanceof Error ? error.message : "Something went wrong.";
}

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

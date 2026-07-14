import type { Collection, Detection, ImportResult, PageMetadata, RuntimeRequest } from "./shared/types";
import { pdfStartOffset } from "./shared/pdf";

const bridge = "http://127.0.0.1:51283";
const maximumPDFBytes = 100 * 1_024 * 1_024;

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({ id: "save", title: "Save page to Refman", contexts: ["page", "link"] });
});

chrome.contextMenus.onClicked.addListener(async (_info, tab) => {
  if (!tab?.id) return;
  try {
    const detection = await detectTab(tab);
    await save(detection);
  } catch (error) {
    console.error("Refman save failed", error);
  }
});

chrome.runtime.onMessage.addListener((request: RuntimeRequest, _sender, respond) => {
  handle(request).then(respond).catch((error: Error) => respond({ error: error.message }));
  return true;
});

async function handle(request: RuntimeRequest): Promise<unknown> {
  switch (request.type) {
    case "detect": {
      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
      if (!tab?.id) throw new Error("No active page found.");
      return detectTab(tab);
    }
    case "save": return save(request.detection, request.collectionId);
    case "pair": {
      const response = await bridgeFetch("/v1/pair", {
        method: "POST",
        body: JSON.stringify({ code: request.code })
      }, false);
      const paired = await response.json() as { token: string };
      await chrome.storage.local.set({ bridgeToken: paired.token });
      return { ok: true };
    }
    case "collections": {
      const response = await bridgeFetch("/v1/collections");
      return response.json() as Promise<Collection[]>;
    }
    case "open": {
      await bridgeFetch(`/v1/documents/${encodeURIComponent(request.uuid)}/open`, { method: "POST" });
      return { ok: true };
    }
    case "connection": {
      const status = await bridgeFetch("/v1/status", {}, false);
      const { bridgeToken } = await chrome.storage.local.get("bridgeToken");
      return { available: status.ok, paired: Boolean(bridgeToken) };
    }
  }
}

async function detectTab(tab: chrome.tabs.Tab): Promise<Detection> {
  const url = tab.url ?? "";
  if (!/^https?:/i.test(url)) {
    return { kind: "unsupported", label: "Unsupported page", url };
  }
  if (/\.pdf(?:$|[?#])/i.test(url) || /^https?:\/\/arxiv\.org\/pdf\//i.test(url)) {
    return {
      kind: "pdf",
      label: "PDF document",
      url,
      fileName: fileName(url, tab.title)
    };
  }
  if (!tab.id) throw new Error("No active page found.");
  await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["content.js"] });
  const metadata = await chrome.tabs.sendMessage(tab.id, { type: "extractMetadata" }) as PageMetadata;
  if (metadata.pdfURL) metadata.pdfURL = await verifiedPDFURL(metadata.pdfURL);
  const identifier = metadata.doi ?? metadata.arxivId ?? metadata.pmid;
  if (identifier) return { kind: "identifier", label: identifierLabel(metadata), metadata, identifier, url };
  if (metadata.title && metadata.authors.length) {
    return { kind: "metadata", label: "Article Found", metadata, url };
  }
  return { kind: "unsupported", label: "No Article Found", metadata, url };
}

async function save(detection: Detection, collectionId?: number): Promise<ImportResult> {
  let response: Response | undefined;
  let pdfUnavailable = false;
  if (detection.kind === "pdf" || detection.metadata?.pdfURL) {
    const pdfURL = detection.metadata?.pdfURL ?? detection.url;
    try {
      const bytes = await downloadPDF(pdfURL);
      response = await bridgeFetch("/v1/import/pdf", {
        method: "POST",
        body: JSON.stringify({
          pdfBase64: bytesToBase64(bytes),
          fileName: detection.fileName ?? fileName(pdfURL, detection.metadata?.title),
          sourceURL: detection.url,
          metadata: detection.metadata,
          collectionId
        })
      });
    } catch (error) {
      if (detection.kind === "pdf") throw error;
      pdfUnavailable = true;
    }
  }
  if (!response && detection.kind === "identifier" && detection.identifier) {
    response = await bridgeFetch("/v1/import/identifier", {
      method: "POST",
      body: JSON.stringify({ identifier: detection.identifier, sourceURL: detection.url, collectionId })
    });
  } else if (!response && detection.kind === "metadata" && detection.metadata) {
    response = await bridgeFetch("/v1/import/metadata", {
      method: "POST",
      body: JSON.stringify({ metadata: detection.metadata, collectionId })
    });
  } else if (!response) {
    throw new Error("This page does not contain a supported reference.");
  }
  const result = await response.json() as ImportResult;
  if (pdfUnavailable && result.status !== "failed") {
    result.message = "Article saved. The publisher’s PDF link was unavailable.";
  }
  return result;
}

async function verifiedPDFURL(url: string): Promise<string | undefined> {
  try {
    const response = await fetch(url, {
      credentials: "include",
      headers: { Range: "bytes=0-1023" },
      signal: AbortSignal.timeout(4_000)
    });
    if (!response.ok || !response.body) return undefined;
    const reader = response.body.getReader();
    const chunks: Uint8Array[] = [];
    let length = 0;
    while (length < 1_024) {
      const { value, done } = await reader.read();
      if (done || !value) break;
      chunks.push(value);
      length += value.length;
    }
    await reader.cancel();
    const prefix = new Uint8Array(Math.min(length, 1_024));
    let offset = 0;
    for (const chunk of chunks) {
      const slice = chunk.subarray(0, prefix.length - offset);
      prefix.set(slice, offset);
      offset += slice.length;
      if (offset === prefix.length) break;
    }
    return pdfStartOffset(prefix) >= 0 ? response.url || url : undefined;
  } catch {
    return undefined;
  }
}

async function downloadPDF(url: string): Promise<Uint8Array> {
  const response = await fetch(url, {
    credentials: "include",
    signal: AbortSignal.timeout(30_000)
  });
  if (!response.ok) throw new Error("The publisher’s PDF could not be downloaded.");
  const declaredLength = Number(response.headers.get("Content-Length") ?? "0");
  if (declaredLength > maximumPDFBytes) throw new Error("This PDF is too large to import.");
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.length > maximumPDFBytes) throw new Error("This PDF is too large to import.");
  const start = pdfStartOffset(bytes);
  if (start < 0) throw new Error("The publisher returned a web page instead of a PDF.");
  return bytes.subarray(start);
}

async function bridgeFetch(path: string, init: RequestInit = {}, authenticated = true): Promise<Response> {
  const headers = new Headers(init.headers);
  headers.set("Content-Type", "application/json");
  if (authenticated) {
    const { bridgeToken } = await chrome.storage.local.get("bridgeToken");
    if (!bridgeToken) throw new Error("Pair the extension with Refman first.");
    headers.set("Authorization", `Bearer ${bridgeToken}`);
  }
  let response: Response;
  try {
    response = await fetch(`${bridge}${path}`, { ...init, headers });
  } catch {
    throw new Error("Open Refman and try again.");
  }
  if (!response.ok) {
    const error = await response.json().catch(() => ({ message: "Refman could not complete the request." }));
    throw new Error(error.message);
  }
  return response;
}

function identifierLabel(metadata: PageMetadata): string {
  if (metadata.doi) return `DOI ${metadata.doi}`;
  if (metadata.arxivId) return `arXiv ${metadata.arxivId}`;
  return `PubMed ${metadata.pmid}`;
}

function fileName(url: string, title?: string): string {
  const pathName = new URL(url).pathname.split("/").pop();
  if (pathName?.toLowerCase().endsWith(".pdf")) return decodeURIComponent(pathName);
  return `${title?.replace(/[^a-z0-9]+/gi, "-").replace(/^-|-$/g, "") || "paper"}.pdf`;
}

function bytesToBase64(bytes: Uint8Array): string {
  const size = 0x8000;
  let binary = "";
  for (let index = 0; index < bytes.length; index += size) {
    binary += String.fromCharCode(...bytes.subarray(index, index + size));
  }
  return btoa(binary);
}

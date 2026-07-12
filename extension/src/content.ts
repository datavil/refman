import { extractPageMetadata } from "./shared/metadata";

chrome.runtime.onMessage.addListener((message, _sender, respond) => {
  if (message?.type !== "extractMetadata") return;
  respond(extractPageMetadata(document, location.href));
});

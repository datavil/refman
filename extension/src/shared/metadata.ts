import type { Author, PageMetadata } from "./types";

function meta(document: Document, ...names: string[]): string | undefined {
  const accepted = new Set(names.map((name) => name.toLowerCase()));
  for (const node of document.querySelectorAll<HTMLMetaElement>("meta")) {
    const key = (node.name || node.getAttribute("property") || "").toLowerCase();
    if (accepted.has(key) && node.content.trim()) return node.content.trim();
  }
  return undefined;
}

function metas(document: Document, ...names: string[]): string[] {
  const accepted = new Set(names.map((name) => name.toLowerCase()));
  return [...document.querySelectorAll<HTMLMetaElement>("meta")]
    .filter((node) => accepted.has((node.name || node.getAttribute("property") || "").toLowerCase()))
    .map((node) => node.content.trim())
    .filter(Boolean);
}

function authorFromName(name: string): Author {
  if (name.includes(",")) {
    const [family, ...given] = name.split(",").map((part) => part.trim());
    return { given: given.join(" "), family };
  }
  const parts = name.trim().split(/\s+/);
  return { given: parts.slice(0, -1).join(" "), family: parts.at(-1) ?? name };
}

function jsonLD(document: Document): Record<string, unknown> | undefined {
  for (const script of document.querySelectorAll<HTMLScriptElement>('script[type="application/ld+json"]')) {
    try {
      const parsed = JSON.parse(script.textContent ?? "");
      const candidates = Array.isArray(parsed) ? parsed : parsed?.["@graph"] ?? [parsed];
      const article = candidates.find((item: Record<string, unknown>) =>
        ["ScholarlyArticle", "Article", "MedicalScholarlyArticle"].includes(String(item?.["@type"])))
      if (article) return article;
    } catch {
      // Ignore malformed publisher metadata and continue with meta tags.
    }
  }
  return undefined;
}

function cleanDOI(value?: string): string | undefined {
  const match = value?.match(/10\.\d{4,9}\/[-._;()/:A-Z0-9]+/i)?.[0];
  return match?.replace(/[).,;]+$/, "").toLowerCase();
}

function yearFrom(value?: string): number | undefined {
  const year = Number(value?.match(/(?:19|20)\d{2}/)?.[0]);
  return Number.isInteger(year) ? year : undefined;
}

export function extractPageMetadata(document: Document, url: string): PageMetadata {
  const structured = jsonLD(document);
  const structuredAuthors = Array.isArray(structured?.author)
    ? structured.author
    : structured?.author ? [structured.author] : [];
  const authorNames = metas(document, "citation_author", "dc.creator", "DC.Creator");
  if (!authorNames.length) {
    for (const author of structuredAuthors) {
      const name = typeof author === "string" ? author : (author as Record<string, string>)?.name;
      if (name) authorNames.push(name);
    }
  }

  const pathname = new URL(url).pathname;
  const arxivId = pathname.match(/\/(?:abs|pdf)\/([^/?#]+?)(?:\.pdf)?$/i)?.[1]
    ?? meta(document, "citation_arxiv_id");
  const pmid = new URL(url).hostname.endsWith("pubmed.ncbi.nlm.nih.gov")
    ? pathname.match(/\/(\d+)/)?.[1]
    : meta(document, "citation_pmid");
  const structuredIdentifier = typeof structured?.identifier === "string"
    ? structured.identifier : undefined;
  const doi = cleanDOI(
    meta(document, "citation_doi", "dc.identifier", "DC.Identifier", "prism.doi")
      ?? structuredIdentifier
      ?? document.querySelector<HTMLAnchorElement>('a[href*="doi.org/10."]')?.href
  );
  const title = meta(document, "citation_title", "dc.title", "DC.Title", "og:title")
    ?? (typeof structured?.headline === "string" ? structured.headline : undefined)
    ?? document.title;
  const date = meta(document, "citation_publication_date", "citation_date", "dc.date")
    ?? (typeof structured?.datePublished === "string" ? structured.datePublished : undefined);
  const statedPDF = meta(document, "citation_pdf_url", "eprints.document_url")
    ?? document.querySelector<HTMLLinkElement>('link[type="application/pdf"]')?.href;
  const pdfURL = statedPDF
    ? new URL(statedPDF, url).href
    : arxivId ? new URL(`/pdf/${arxivId}.pdf`, url).href : undefined;

  return {
    title: title.trim(),
    authors: authorNames.map(authorFromName),
    abstract: meta(document, "citation_abstract", "dc.description", "description"),
    year: yearFrom(date),
    venue: meta(document, "citation_journal_title", "citation_conference_title", "dc.source"),
    doi,
    arxivId,
    pmid,
    pdfURL,
    url
  };
}

import { describe, expect, test } from "vitest";
import { extractPageMetadata } from "../src/shared/metadata";

describe("scholarly metadata extraction", () => {
  test("extracts Highwire citation tags", () => {
    document.head.innerHTML = `
      <meta name="citation_title" content="A Useful Paper">
      <meta name="citation_author" content="Ada Lovelace">
      <meta name="citation_author" content="Hopper, Grace">
      <meta name="citation_doi" content="https://doi.org/10.1000/Example.1">
      <meta name="citation_publication_date" content="2025/04/01">
      <meta name="citation_journal_title" content="Journal of Tests">
      <meta name="citation_pdf_url" content="/paper.pdf">
    `;
    const result = extractPageMetadata(document, "https://publisher.example/paper");
    expect(result.title).toBe("A Useful Paper");
    expect(result.authors).toEqual([
      { given: "Ada", family: "Lovelace" },
      { given: "Grace", family: "Hopper" }
    ]);
    expect(result.doi).toBe("10.1000/example.1");
    expect(result.year).toBe(2025);
    expect(result.pdfURL).toBe("https://publisher.example/paper.pdf");
  });

  test("extracts an arXiv identifier from the URL", () => {
    document.head.innerHTML = `
      <meta name="citation_title" content="An arXiv Paper">
      <meta name="citation_author" content="Test Author">
    `;
    const result = extractPageMetadata(document, "https://arxiv.org/abs/2501.12345");
    expect(result.arxivId).toBe("2501.12345");
    expect(result.pdfURL).toBe("https://arxiv.org/pdf/2501.12345.pdf");
  });

  test("uses JSON-LD article metadata", () => {
    document.head.innerHTML = `<script type="application/ld+json">{
      "@type": "ScholarlyArticle",
      "headline": "Structured Paper",
      "author": [{"name": "Katherine Johnson"}],
      "datePublished": "2024-09-10"
    }</script>`;
    const result = extractPageMetadata(document, "https://example.org/article");
    expect(result.title).toBe("Structured Paper");
    expect(result.authors[0]).toEqual({ given: "Katherine", family: "Johnson" });
    expect(result.year).toBe(2024);
  });
});

import { expect, test } from "vitest";
import { pdfStartOffset } from "../src/shared/pdf";

test("recognizes a PDF signature", () => {
  expect(pdfStartOffset(new TextEncoder().encode("%PDF-1.7\n"))).toBe(0);
});

test("allows a small preamble before the PDF signature", () => {
  expect(pdfStartOffset(new TextEncoder().encode("\n\uFEFF%PDF-1.4"))).toBeGreaterThan(0);
});

test("rejects HTML returned by a misleading PDF link", () => {
  expect(pdfStartOffset(new TextEncoder().encode("<!doctype html><title>Sign in</title>"))).toBe(-1);
});

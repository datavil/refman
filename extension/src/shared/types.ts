export interface Author {
  given: string;
  family: string;
}

export interface PageMetadata {
  title: string;
  authors: Author[];
  abstract?: string;
  year?: number;
  venue?: string;
  doi?: string;
  arxivId?: string;
  pmid?: string;
  pdfURL?: string;
  url: string;
}

export interface Detection {
  kind: "identifier" | "pdf" | "metadata" | "unsupported";
  label: string;
  metadata?: PageMetadata;
  identifier?: string;
  url: string;
  fileName?: string;
}

export interface Collection {
  id: number;
  name: string;
}

export interface ImportResult {
  status: "added" | "duplicate" | "failed";
  documentUUID?: string;
  title?: string;
  message: string;
}

export type RuntimeRequest =
  | { type: "detect" }
  | { type: "save"; detection: Detection; collectionId?: number }
  | { type: "pair"; code: string }
  | { type: "collections" }
  | { type: "open"; uuid: string }
  | { type: "connection" };

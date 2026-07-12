const signature = [0x25, 0x50, 0x44, 0x46, 0x2d]; // %PDF-

export function pdfStartOffset(bytes: Uint8Array): number {
  const searchLength = Math.min(bytes.length, 1_024);
  for (let index = 0; index <= searchLength - signature.length; index += 1) {
    if (signature.every((value, offset) => bytes[index + offset] === value)) return index;
  }
  return -1;
}

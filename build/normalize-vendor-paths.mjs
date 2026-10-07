import fs from 'node:fs';
import assert from 'node:assert/strict';
import path from 'node:path';

// Static MFC libraries contain Microsoft's original source paths in diagnostic
// strings. Compiler path mapping cannot change already compiled library objects.
// Replace only those strings in non-executable initialized-data sections, with
// same-length neutral source labels. Do not touch code, offsets or debug records.
const file = process.argv[2];
const bytes = fs.readFileSync(file);
assert.equal(bytes.readUInt16LE(0), 0x5a4d);
const pe = bytes.readUInt32LE(0x3c);
assert.equal(bytes.readUInt32LE(pe), 0x4550);
const optional = pe + 24;
const dirs = optional + (bytes.readUInt16LE(optional) === 0x20b ? 112 : 96);
assert.equal(bytes.readUInt32LE(dirs + 32), 0, 'Do not modify a signed image');
const sections = optional + bytes.readUInt16LE(pe + 20);
let replaced = 0;
for (let i = 0; i < bytes.readUInt16LE(pe + 6); i++) {
  const section = sections + 40 * i;
  const flags = bytes.readUInt32LE(section + 36);
  if ((flags & 0x20000000) || !(flags & 0x40)) continue;
  const offset = bytes.readUInt32LE(section + 20);
  const size = bytes.readUInt32LE(section + 16);
  assert.ok(offset + size <= bytes.length);
  for (const encoding of ['latin1', 'utf16le']) {
    const width = encoding === 'latin1' ? 1 : 2;
    const text = bytes.subarray(offset, offset + size).toString(encoding);
    const paths = /\b[A-Z]:[\\/][\x20-\x21\x23-\x3b\x3d\x3f-\x7e]+/gi;
    for (const match of text.matchAll(paths)) {
      const value = match[0];
      // Only vendor MFC/ATL source diagnostics, never arbitrary user paths.
      if (!/[\\/]atlmfc[\\/]/i.test(value) || !/\.(?:cpp|c|h|hpp)$/i.test(value)) continue;
      const basename = path.win32.basename(value);
      const replacement = 'vendor/mfc/' + '_'.repeat(value.length - basename.length - 12) + '/' + basename;
      assert.equal(replacement.length, value.length);
      const start = offset + match.index * width;
      Buffer.from(replacement, encoding).copy(bytes, start);
      replaced++;
    }
  }
}
fs.writeFileSync(file, bytes);
console.log(JSON.stringify({ file: path.basename(file), normalizedVendorSourcePaths: replaced }));

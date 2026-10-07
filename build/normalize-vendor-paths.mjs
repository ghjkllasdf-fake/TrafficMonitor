import fs from 'node:fs';
import assert from 'node:assert/strict';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');

// Compiler debug suppression and /pathmap are applied first. Static MFC object
// files still contain vendor diagnostic literals. Never search/patch arbitrary
// path fragments: accept only whole, NUL-delimited literals in read-only .rdata.
export function normalizeVendorPaths(input) {
  const bytes = Buffer.from(input);
  const within = (offset, size) => assert.ok(Number.isSafeInteger(offset) && offset >= 0 && size >= 0 && offset + size <= bytes.length, 'Truncated PE');
  within(0, 64);
  assert.equal(bytes.readUInt16LE(0), 0x5a4d);
  const pe = bytes.readUInt32LE(0x3c);
  within(pe, 24);
  assert.equal(bytes.readUInt32LE(pe), 0x4550);
  const optional = pe + 24;
  const optionalSize = bytes.readUInt16LE(pe + 20);
  within(optional, optionalSize);
  const magic = bytes.readUInt16LE(optional);
  assert.ok([0x10b, 0x20b].includes(magic), 'Unknown PE format');
  const directoryOffset = magic === 0x20b ? 112 : 96;
  assert.ok(optionalSize >= directoryOffset + 16 * 8, 'Missing PE directories');
  const dirs = optional + directoryOffset;
  assert.equal(bytes.readUInt32LE(dirs - 4), 16, 'Unexpected directory count');
  assert.equal(bytes.readUInt32LE(dirs + 32), 0, 'Do not modify a signed image');
  assert.equal(bytes.readUInt32LE(dirs + 36), 0, 'Do not modify a signed image');
  assert.equal(bytes.readUInt32LE(optional + 64), 0, 'Do not invalidate a PE checksum');
  const table = optional + optionalSize;
  const count = bytes.readUInt16LE(pe + 6);
  within(table, count * 40);
  const sections = [];
  for (let i = 0; i < count; i++) {
    const entry = table + 40 * i;
    const section = {
      name: bytes.subarray(entry, entry + 8).toString('ascii').replace(/\0.*$/, ''),
      offset: bytes.readUInt32LE(entry + 20), size: bytes.readUInt32LE(entry + 16),
      va: bytes.readUInt32LE(entry + 12), flags: bytes.readUInt32LE(entry + 36),
    };
    within(section.offset, section.size);
    if (section.size) assert.ok(section.offset >= table + count * 40, 'Section overlaps headers');
    for (const other of sections) assert.ok(!section.size || !other.size || section.offset >= other.offset + other.size || other.offset >= section.offset + section.size, 'Overlapping sections');
    sections.push(section);
  }
  const ranges = [];
  for (const section of sections) {
    // IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ; no write/execute/code.
    if (section.name !== '.rdata' || (section.flags & 0xe0000060) !== 0x40000040) continue;
    const data = bytes.subarray(section.offset, section.offset + section.size);
    for (const encoding of ['latin1', 'utf16le']) {
      const width = encoding === 'latin1' ? 1 : 2;
      const text = data.toString(encoding);
      // Names are restricted to the actual MSVC source-tree grammar. Paths in
      // messages, arbitrary strings, resource tables and writable data fail closed.
      const pattern = /(?:^|\0)([A-Z]:\\[A-Za-z0-9_. -]+(?:\\[A-Za-z0-9_. -]+)*\\atlmfc\\(?:src|include)\\(?:[A-Za-z0-9_. -]+\\)*[A-Za-z0-9_.-]+\.(?:cpp|c|h|hpp))(?=\0)/gi;
      for (const match of text.matchAll(pattern)) {
        const value = match[1];
        const start = section.offset + (match.index + match[0].length - value.length) * width;
        const end = start + value.length * width;
        assert.ok(!ranges.some(range => start < range.end && end > range.start), 'Overlapping strings');
        const basename = path.win32.basename(value);
        const replacement = 'vendor/mfc/' + '_'.repeat(value.length - basename.length - 12) + '/' + basename;
        const changed = Buffer.from(replacement, encoding);
        assert.equal(changed.length, end - start);
        assert.ok(input.subarray(start, end).equals(Buffer.from(value, encoding)));
        // Refuse literals overlapping ANY PE directory (including debug/imports).
        const rva = section.va + start - section.offset;
        for (let d = 0; d < 16; d++) {
          const va = bytes.readUInt32LE(dirs + d * 8);
          const size = bytes.readUInt32LE(dirs + d * 8 + 4);
          assert.ok(!size || rva >= va + size || rva + changed.length <= va, 'String overlaps a PE directory');
        }
        changed.copy(bytes, start);
        ranges.push({ start, end, encoding, basename, originalSha256: hash(input.subarray(start, end)) });
      }
    }
  }
  assert.equal(bytes.length, input.length);
  ranges.sort((a, b) => a.start - b.start);
  let cursor = 0;
  for (const range of ranges) {
    assert.ok(bytes.subarray(cursor, range.start).equals(input.subarray(cursor, range.start)), 'Unexpected byte change');
    cursor = range.end;
  }
  assert.ok(bytes.subarray(cursor).equals(input.subarray(cursor)), 'Unexpected trailing change');
  const executableSections = sections.filter(section => section.flags & 0x20000000).map(section => {
    const before = input.subarray(section.offset, section.offset + section.size);
    const after = bytes.subarray(section.offset, section.offset + section.size);
    assert.ok(before.equals(after), 'Executable section changed');
    return { name: section.name, sha256: hash(after) };
  });
  return { bytes, report: { normalizedVendorSourcePaths: ranges.length, lengthUnchanged: true, beforeSha256: hash(input), afterSha256: hash(bytes), executableSections, ranges } };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const file = process.argv[2];
  const { bytes, report } = normalizeVendorPaths(fs.readFileSync(file));
  fs.writeFileSync(file, bytes);
  if (process.argv[3]) fs.writeFileSync(process.argv[3], JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ file: path.basename(file), ...report }));
}

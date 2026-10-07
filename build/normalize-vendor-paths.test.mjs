import assert from 'node:assert/strict';
import { normalizeVendorPaths } from './normalize-vendor-paths.mjs';

function fixture({ encoding = 'latin1', flags = 0x40000040, prefix = '\0', suffix = '\0', magic = 0x20b } = {}) {
  const bytes = Buffer.alloc(2048);
  bytes.writeUInt16LE(0x5a4d); bytes.writeUInt32LE(128, 0x3c); bytes.writeUInt32LE(0x4550, 128);
  bytes.writeUInt16LE(2, 134);
  const optionalSize = magic === 0x20b ? 240 : 224;
  bytes.writeUInt16LE(optionalSize, 148); bytes.writeUInt16LE(magic, 152);
  const dirs = 152 + (magic === 0x20b ? 112 : 96);
  bytes.writeUInt32LE(16, dirs - 4);
  const table = 152 + optionalSize;
  bytes.write('.rdata', table); bytes.writeUInt32LE(1024, table + 8); bytes.writeUInt32LE(4096, table + 12);
  bytes.writeUInt32LE(1024, table + 16); bytes.writeUInt32LE(512, table + 20); bytes.writeUInt32LE(flags >>> 0, table + 36);
  bytes.write('.text', table + 40); bytes.writeUInt32LE(512, table + 48); bytes.writeUInt32LE(8192, table + 52);
  bytes.writeUInt32LE(512, table + 56); bytes.writeUInt32LE(1536, table + 60); bytes.writeUInt32LE(0x60000020, table + 76);
  const literal = Buffer.from(prefix + 'D:' + '\\vendor\\atlmfc\\src\\mfc\\file.cpp' + suffix, encoding);
  literal.copy(bytes, 600); literal.copy(bytes, 1600);
  return { bytes, dirs, table };
}
for (const magic of [0x10b, 0x20b]) {
  for (const encoding of ['latin1', 'utf16le']) {
    const { bytes } = fixture({ magic, encoding });
    const original = Buffer.from(bytes);
    const result = normalizeVendorPaths(bytes);
    assert.equal(result.report.normalizedVendorSourcePaths, 1);
    assert.equal(result.bytes.length, bytes.length);
    assert.ok(bytes.equals(original), 'Input must not mutate');
    assert.ok(result.bytes.subarray(1536).equals(bytes.subarray(1536)), 'Code must not change');
    assert.equal(normalizeVendorPaths(result.bytes).report.normalizedVendorSourcePaths, 0, 'Idempotent');
  }
}
for (const options of [{ flags: 0xc0000040 }, { flags: 0x60000040 }, { prefix: 'message: ' }, { suffix: '\u0001' }]) {
  const { bytes } = fixture(options);
  assert.ok(normalizeVendorPaths(bytes).bytes.equals(bytes));
}
for (const mutation of ['signatureOffset', 'signatureSize', 'checksum', 'debugOverlap', 'unknownMagic', 'badSection', 'overlap']) {
  const { bytes, dirs, table } = fixture();
  if (mutation === 'signatureOffset') bytes.writeUInt32LE(1900, dirs + 32);
  if (mutation === 'signatureSize') bytes.writeUInt32LE(32, dirs + 36);
  if (mutation === 'checksum') bytes.writeUInt32LE(123, 216);
  if (mutation === 'debugOverlap') { bytes.writeUInt32LE(4096 + 88, dirs + 48); bytes.writeUInt32LE(128, dirs + 52); }
  if (mutation === 'unknownMagic') bytes.writeUInt16LE(0, 152);
  if (mutation === 'badSection') bytes.writeUInt32LE(99999, table + 16);
  if (mutation === 'overlap') bytes.writeUInt32LE(512, table + 60);
  assert.throws(() => normalizeVendorPaths(bytes), mutation);
}
assert.throws(() => normalizeVendorPaths(Buffer.alloc(20)));
console.log('PASS: normalization length, exact ranges, code preservation, signed/checksummed/malformed PE rejection, PE32/PE32+, UTF-16 and idempotence.');

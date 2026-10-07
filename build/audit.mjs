import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';

// Reviewed upstream documentation uses literal <username> / Chinese username placeholders.
// Exceptions are rule-specific and exact-content hashes, not directory-wide exclusions.
const upstreamExamples = {
  'Help.md': 'd8d36e5f50bdca57e40a7281921b5e87e43c004843bc5d67e7d9a59bac482639',
  'Help_en-us.md': '23aabd69cb10c627607a4ac22d02c56681a30243e87ea80009feecfad8cc0538',
  'UpdateLog/update_log.md': 'd08907715175859a6327621a9dd05b2d7a52656cfa1009bc042fedcad7286b8a',
};

// Report rule IDs and relative filenames, never matching secret values.
const rules = [
  ['private-key', /-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----/],
  ['github-token', /\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b/],
  ['aws-key', /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/],
  ['credential-url', /https?:\/\/[^\s/@:]+:[^\s/@]+@/i],
  ['private-home', /\b[A-Z]:[\\/](?:Users|Documents and Settings)[\\/][^\s"<>]+|\/(?:home|Users)\/[^\s"<>]+/i],
];
const binaryRules = [
  ['absolute-path', /\b[A-Z]:[\\/](?!\/)[^\x00\r\n"<>]{3,}/i],
  ['pdb-reference', /[\w.-]+\.pdb\b/i],
];
function findings(bytes, binary = false) {
  const text = [bytes.toString('utf8'), bytes.toString('utf16le')];
  return [...rules, ...(binary ? binaryRules : [])]
    .filter(([, re]) => text.some(s => re.test(s))).map(([id]) => id);
}
function debugTypes(bytes) {
  assert.equal(bytes.readUInt16LE(0), 0x5a4d, 'Not a PE image');
  const pe = bytes.readUInt32LE(0x3c);
  assert.equal(bytes.readUInt32LE(pe), 0x4550, 'Invalid PE signature');
  const optional = pe + 24;
  const magic = bytes.readUInt16LE(optional);
  assert.ok([0x10b, 0x20b].includes(magic), 'Unknown PE format');
  const dirs = optional + (magic === 0x20b ? 112 : 96);
  const rva = bytes.readUInt32LE(dirs + 48);
  const size = bytes.readUInt32LE(dirs + 52);
  if (!rva || !size) return [];
  const sectionStart = optional + bytes.readUInt16LE(pe + 20);
  for (let i = 0; i < bytes.readUInt16LE(pe + 6); i++) {
    const section = sectionStart + i * 40;
    const va = bytes.readUInt32LE(section + 12);
    const rawSize = bytes.readUInt32LE(section + 16);
    if (rva >= va && rva + size <= va + rawSize) {
      const offset = bytes.readUInt32LE(section + 20) + rva - va;
      assert.ok(offset + size <= bytes.length && size % 28 === 0, 'Invalid debug directory');
      return Array.from({ length: size / 28 }, (_, j) => bytes.readUInt32LE(offset + j * 28 + 12));
    }
  }
  throw new Error('Unmapped debug directory');
}
function checkBinary(file) {
  const bytes = fs.readFileSync(file);
  const found = findings(bytes, true);
  // IMAGE_DEBUG_TYPE_REPRO (16) has no paths; reject CodeView and embedded PDBs.
  if (debugTypes(bytes).some(type => type !== 16)) found.push('debug-directory');
  return found;
}
function selfTest() {
  assert.deepEqual(findings(Buffer.from('clean source')), []);
  assert.ok(findings(Buffer.from('gh' + 'p_' + 'a'.repeat(36))).includes('github-token'));
  assert.ok(findings(Buffer.from('-----BEGIN ' + 'PRIVATE KEY-----')).includes('private-key'));
  assert.ok(findings(Buffer.from('C:' + '\\Users\\sample\\file', 'utf16le')).includes('private-home'));
  assert.ok(findings(Buffer.from('D:' + '\\build\\app.pdb'), true).includes('pdb-reference'));
  assert.deepEqual(findings(Buffer.from('https://github.com/project'), true), []);
  const pe = Buffer.alloc(1024);
  pe.writeUInt16LE(0x5a4d); pe.writeUInt32LE(128, 0x3c); pe.writeUInt32LE(0x4550, 128);
  pe.writeUInt16LE(1, 134); pe.writeUInt16LE(240, 148); pe.writeUInt16LE(0x20b, 152);
  pe.writeUInt32LE(4096, 312); pe.writeUInt32LE(28, 316);
  pe.writeUInt32LE(4096, 404); pe.writeUInt32LE(512, 408); pe.writeUInt32LE(512, 412);
  pe.writeUInt32LE(2, 524); assert.deepEqual(debugTypes(pe), [2]);
  pe.writeUInt32LE(16, 524); assert.deepEqual(debugTypes(pe), [16]);
  console.log('Audit self-tests passed (UTF-8, UTF-16, secrets, paths, PE debug records).');
}
const [mode, ...args] = process.argv.slice(2);
if (mode === 'self-test') selfTest();
else if (mode === 'binary') {
  let failed = false;
  for (const file of args) {
    const found = checkBinary(file);
    console.log(JSON.stringify({ file: path.basename(file), findings: found }));
    failed ||= found.length > 0;
  }
  process.exitCode = failed ? 1 : 0;
} else if (mode === 'source') {
  const root = path.resolve(import.meta.dirname, '..');
  const git = process.env.GIT_EXE || 'git';
  const files = execFileSync(git, ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], { cwd: root })
    .toString('utf8').split('\0').filter(Boolean);
  const report = [];
  for (const file of files) {
    const bytes = fs.readFileSync(path.join(root, file));
    const reviewed = upstreamExamples[file] === createHash('sha256').update(bytes).digest('hex');
    const found = findings(bytes).filter(id => !(reviewed && id === 'private-home'));
    if (/(?:^|\/)(?:id_rsa|id_ed25519|\.env)(?:$|\.)|\.(?:pem|key|pfx|p12|pdb|log)$/i.test(file)) found.push('sensitive-filename');
    if (found.length) report.push({ file, findings: found });
  }
  console.log(JSON.stringify({ scanned: files.length, findings: report }, null, 2));
  process.exitCode = report.length ? 1 : 0;
} else throw new Error('Usage: node build/audit.mjs self-test | source | binary <files...>');

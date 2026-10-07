import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';

const root = path.resolve(import.meta.dirname, '..');
const git = process.env.GIT_EXE || 'git';
const hashes = {
  'TrafficMonitor/TaskBarDlg.cpp': '4714c4ca4',
  'TrafficMonitor/TaskBarDlg.h': 'bd951ccff',
  'TrafficMonitor/Win11TaskbarDlg.cpp': '36f7abd02',
  'TrafficMonitor/Win11TaskbarDlg.h': '2703f8b00',
};
for (const [file, expected] of Object.entries(hashes)) {
  const hash = execFileSync(git, ['hash-object', '--', file], { cwd: root, encoding: 'utf8' }).trim();
  assert.ok(hash.startsWith(expected), `Original patch changed: ${file}`);
}
const header = fs.readFileSync(path.join(root, 'TrafficMonitor/stdafx.h'), 'utf8');
assert.ok(header.includes('#define VERSION L"1.86.1"'));
const rc = fs.readFileSync(path.join(root, 'TrafficMonitor/TrafficMonitor.rc')).toString('utf16le');
for (const value of ['FILEVERSION 1,86,1,0', 'PRODUCTVERSION 1,86,1,0', 'VALUE "FileVersion", "1.86.1.0"', 'VALUE "ProductVersion", "1.86.1.0"']) assert.ok(rc.includes(value), value);
const workflow = fs.readFileSync(path.join(root, '.github/workflows/main.yml'), 'utf8');
assert.ok(!/pdb|path:.*Bin\//i.test(workflow), 'Debug artifact publication is forbidden');
assert.ok(workflow.includes("github.repository == 'ghjkllasdf-fake/TrafficMonitor'"));
console.log('PASS: four exact patch blobs, all application/PE versions, fork-only CI, zero PDB artifact paths.');

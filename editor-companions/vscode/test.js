const { test } = require('node:test');
const assert = require('node:assert/strict');
const { snapshot } = require('./snapshot');
const editor = text => ({ document: { getText: () => text, fileName: '/private/project/Main.java', languageId: 'java' }, selection: { active: { line: 3 } } });
test('exports unsaved text, basename, cursor and exact diagnostics', () => {
  const result = snapshot(editor('class Main {}'), [{ range: { start: { line: 1 } }, message: 'Missing return' }], new Date('2026-10-03T10:00:00Z'));
  assert.equal(result.text, 'class Main {}'); assert.equal(result.file, 'Main.java');
  assert.equal(result.cursorLine, 4); assert.deepEqual(result.diagnostics, ['Line 2: Missing return']);
  assert.equal(result.capturedAt, '2026-10-03T10:00:00Z');
});
test('rejects large UTF-8 files and bounds diagnostics', () => {
  assert.throws(() => snapshot(editor('x'.repeat(64001)), []));
  assert.throws(() => snapshot(editor('é'.repeat(33000)), []));
  const diagnostics = Array.from({ length: 40 }, () => ({ range: { start: { line: 0 } }, message: 'x'.repeat(2000) }));
  const result = snapshot(editor(''), diagnostics);
  assert.equal(result.diagnostics.length, 30); assert.equal(result.diagnostics[0].length, 1000);
});

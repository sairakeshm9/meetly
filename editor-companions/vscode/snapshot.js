const path = require('node:path');
function snapshot(editor, diagnostics, now = new Date()) {
  const text = editor.document.getText();
  if (Buffer.byteLength(text, 'utf8') > 64000) throw new Error('Active file exceeds 64 KB');
  const clean = s => String(s).replace(/sk-[A-Za-z0-9_-]{10,}/g, '[redacted]');
  return {
    version: 1, editor: 'VS Code', file: path.basename(editor.document.fileName),
    language: editor.document.languageId, text: clean(text),
    cursorLine: editor.selection.active.line + 1,
    diagnostics: diagnostics.slice(0, 30).map(d => clean(`Line ${d.range.start.line + 1}: ${d.message}`).slice(0, 1000)),
    capturedAt: now.toISOString().replace(/\.\d{3}Z$/, 'Z')
  };
}
module.exports = { snapshot };

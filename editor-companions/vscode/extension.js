const vscode = require('vscode');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { snapshot } = require('./snapshot');
const directory = path.join(os.homedir(), 'Library', 'Application Support', 'Meeting Assist', 'editor-bridge');
const target = path.join(directory, 'vscode.json');
let connected = false, timer, pending, status;
function remove() { try { fs.unlinkSync(target); } catch {} }
function publish() {
  if (!connected) return;
  const editor = vscode.window.activeTextEditor;
  if (!editor || !['file', 'untitled'].includes(editor.document.uri.scheme)) { remove(); return; }
  try {
    const payload = snapshot(editor, vscode.languages.getDiagnostics(editor.document.uri));
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    const temp = target + '.tmp';
    fs.writeFileSync(temp, JSON.stringify(payload), { mode: 0o600 });
    fs.renameSync(temp, target);
    status.text = '$(plug) Meetly connected';
  } catch { remove(); status.text = '$(warning) Meetly: file unavailable or too large'; }
}
function schedule() { clearTimeout(pending); pending = setTimeout(publish, 150); }
function disconnect() {
  connected = false; clearInterval(timer); clearTimeout(pending); remove();
  if (status) status.hide();
}
function activate(context) {
  status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 10);
  status.command = 'meetingAssist.disconnect';
  status.tooltip = 'Active code and diagnostics are shared locally with Meetly; coding answers may send them to OpenAI. Click to disconnect.';
  context.subscriptions.push(status,
    vscode.commands.registerCommand('meetingAssist.connect', async () => {
      const answer = await vscode.window.showInformationMessage('Share your active code file with Meetly? Coding answers may send code and diagnostics to OpenAI. Nothing is shared until you connect.', 'Y — Connect', 'N — Cancel');
      if (answer !== 'Y — Connect') return;
      disconnect(); connected = true; status.show(); publish(); timer = setInterval(publish, 2000);
    }),
    vscode.commands.registerCommand('meetingAssist.disconnect', disconnect),
    vscode.workspace.onDidChangeTextDocument(schedule),
    vscode.window.onDidChangeActiveTextEditor(schedule),
    vscode.window.onDidChangeTextEditorSelection(schedule),
    vscode.languages.onDidChangeDiagnostics(schedule),
    { dispose: disconnect });
}
module.exports = { activate, deactivate: disconnect };

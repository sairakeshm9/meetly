package meetingassist;

import com.intellij.openapi.actionSystem.AnAction;
import com.intellij.openapi.actionSystem.AnActionEvent;
import com.intellij.openapi.application.ApplicationManager;
import com.intellij.openapi.fileEditor.FileEditorManager;
import com.intellij.openapi.project.Project;
import com.intellij.openapi.ui.Messages;
import com.intellij.util.Alarm;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.time.Instant;

public class ConnectAction extends AnAction {
    static Alarm alarm;
    static final Path target = Path.of(System.getProperty("user.home"), "Library", "Application Support", "Meeting Assist", "editor-bridge", "intellij.json");
    @Override public void actionPerformed(AnActionEvent event) {
        Project project = event.getProject();
        if (project == null) return;
        if (Messages.showYesNoDialog(project, "Share the active code file locally with Meetly? Coding answers may send it to OpenAI. Use Disconnect Meetly to stop.", "Connect Meetly", "Y — Connect", "N — Cancel", Messages.getQuestionIcon()) != Messages.YES) return;
        disconnect();
        alarm = new Alarm(Alarm.ThreadToUse.SWING_THREAD, project);
        tick(project);
    }
    static void disconnect() {
        if (alarm != null && !alarm.isDisposed()) alarm.cancelAllRequests();
        if (alarm != null) com.intellij.openapi.util.Disposer.dispose(alarm);
        alarm = null;
        try { Files.deleteIfExists(target); } catch (Exception ignored) {}
    }
    static String quote(String text) {
        StringBuilder out = new StringBuilder("\"");
        for (char c : text.toCharArray()) {
            switch (c) {
                case '"': out.append("\\\""); break;
                case '\\': out.append("\\\\"); break;
                case '\n': out.append("\\n"); break;
                case '\r': out.append("\\r"); break;
                case '\t': out.append("\\t"); break;
                default: if (c < 32) out.append(String.format("\\u%04x", (int)c)); else out.append(c);
            }
        }
        return out.append('"').toString();
    }
    static void tick(Project project) {
        if (alarm == null || alarm.isDisposed() || project.isDisposed()) { disconnect(); return; }
        ApplicationManager.getApplication().runReadAction(() -> {
            try {
                var editor = FileEditorManager.getInstance(project).getSelectedTextEditor();
                if (editor == null) { Files.deleteIfExists(target); return; }
                var file = com.intellij.openapi.fileEditor.FileDocumentManager.getInstance().getFile(editor.getDocument());
                if (file == null) { Files.deleteIfExists(target); return; }
                String text = editor.getDocument().getText().replaceAll("sk-[A-Za-z0-9_-]{10,}", "[redacted]");
                if (text.getBytes(StandardCharsets.UTF_8).length > 64000) { Files.deleteIfExists(target); return; }
                String language = file.getExtension() == null ? "text" : file.getExtension().toLowerCase();
                java.util.List<String> diagnostics = new java.util.ArrayList<>();
                com.intellij.codeInsight.daemon.impl.DaemonCodeAnalyzerEx.processHighlights(editor.getDocument(), project, com.intellij.lang.annotation.HighlightSeverity.WARNING, 0, editor.getDocument().getTextLength(), info -> {
                    if (info.getDescription() != null) {
                        String message = "Line " + (editor.getDocument().getLineNumber(Math.max(0, Math.min(info.startOffset, editor.getDocument().getTextLength()))) + 1) + ": " + info.getDescription();
                        diagnostics.add(quote(message.substring(0, Math.min(1000, message.length())).replaceAll("sk-[A-Za-z0-9_-]{10,}", "[redacted]")));
                    }
                    return diagnostics.size() < 30;
                });
                String payload = "{\"version\":1,\"editor\":\"IntelliJ\",\"file\":" + quote(file.getName()) + ",\"language\":" + quote(language) + ",\"text\":" + quote(text) + ",\"cursorLine\":" + (editor.getCaretModel().getLogicalPosition().line + 1) + ",\"diagnostics\":[" + String.join(",", diagnostics) + "],\"capturedAt\":" + quote(Instant.now().toString().replaceAll("\\.\\d+Z$", "Z")) + "}";
                Files.createDirectories(target.getParent());
                Files.setPosixFilePermissions(target.getParent(), PosixFilePermissions.fromString("rwx------"));
                Path temp = target.resolveSibling("intellij.json.tmp");
                Files.writeString(temp, payload);
                Files.setPosixFilePermissions(temp, PosixFilePermissions.fromString("rw-------"));
                Files.move(temp, target, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
            } catch (Exception ignored) { try { Files.deleteIfExists(target); } catch (Exception ignoredAgain) {} }
        });
        if (alarm != null && !alarm.isDisposed()) alarm.addRequest(() -> tick(project), 1000);
    }
}

# Editor companions

Enable **Use connected editor** in Meetly's Coding/Advanced Coding modes. Editor context is optional; Watch screen remains available for any app. Connected code/diagnostics may be sent to OpenAI with coding questions. No network service or API key exists in these extensions.

## VS Code

Extensions → menu → Install from VSIX → `meeting-assist-editor.vsix`. Run **Connect Meetly** from the command palette and choose **Y — Connect**. Disconnect through the status bar or **Disconnect Meetly**. Supports unsaved active-file changes, cursor and diagnostics, including Java when its language extension is installed. Nothing connects automatically after restart.

## IntelliJ / JetBrains

Settings → Plugins → menu → Install Plugin from Disk → `meeting-assist-intellij.zip`, then restart the IDE if requested. Find Action → **Connect Meetly**, choose **Y — Connect**. Find Action → **Disconnect Meetly** stops it. Uses the selected file, unsaved code, cursor and editor highlights. Requires platform build 243+ with Java 21 support; compiled against the installed JetBrains SDK, not certified on every IDE release.

## Data and freshness

Both write only the active file's basename, text (maximum 64 KB), line, diagnostics (maximum 30) and timestamp to a private local file in `~/Library/Application Support/Meeting Assist/editor-bridge`. This short-lived bridge file is plaintext; do not connect secret-bearing files. Common OpenAI key patterns are removed but generic secrets are not reliably detectable. Disconnect deletes the file; abrupt IDE termination can leave it until the next connection/disconnect. Meetly ignores frames older than 12 seconds and never sends editor content in Questions mode. Turn off editor context in Meetly to stop consumption; disconnect in the editor to stop publication.

Java **Compile** and **Run sample** operate on a standalone class snapshot in a temporary folder, under macOS sandbox restrictions with no network/personal-file access. Requires a local JDK and `sandbox-exec`. Compilation uses `-proc:none`. Run executes its `main`; an optional expected output checks that sample only. Package/project dependencies are deliberately handled in your IDE. This is not a complete test suite or proof of correctness.

## Build / test

`node --test editor-companions/vscode/test.js`

`python3 scripts/build-editor-companions.py --intellij-home '/Applications/PyCharm.app/Contents'`

Use an installed IntelliJ/JetBrains `Contents` directory for the platform SDK. Omit `--intellij-home` to package only VS Code. Swift integration tests verify file freshness, bounds and disabled consumption.

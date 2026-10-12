#!/usr/bin/env python3
"""Package VS Code; optionally compile IntelliJ against a locally installed JetBrains IDE."""
import argparse
import os
import pathlib
import shutil
import subprocess
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--intellij-home', default=os.environ.get('INTELLIJ_HOME', ''))
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
output = root / 'dist' / 'Editor Companions'
output.mkdir(parents=True, exist_ok=True)
extension = root / 'editor-companions' / 'vscode'
with zipfile.ZipFile(output / 'meeting-assist-editor.vsix', 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('[Content_Types].xml', '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="json" ContentType="application/json"/><Default Extension="js" ContentType="application/javascript"/><Default Extension="vsixmanifest" ContentType="text/xml"/></Types>')
    archive.writestr('extension.vsixmanifest', '''<?xml version="1.0" encoding="utf-8"?><PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011"><Metadata><Identity Language="en-US" Id="meeting-assist-editor" Version="0.2.0" Publisher="meeting-assist-local"/><DisplayName>Meetly Editor</DisplayName><Description xml:space="preserve">Opt-in active code context for Meetly.</Description><Properties><Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.90.0"/><Property Id="Microsoft.VisualStudio.Code.ExtensionDependencies" Value=""/><Property Id="Microsoft.VisualStudio.Code.ExtensionPack" Value=""/></Properties></Metadata><Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation><Dependencies/><Assets><Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/></Assets></PackageManifest>''')
    for name in ['package.json', 'extension.js', 'snapshot.js']:
        archive.write(extension / name, 'extension/' + name)
shutil.copy(root / 'editor-companions' / 'README.md', output / 'README.md')
print('Packaged VS Code companion.')
if args.intellij_home:
    home = pathlib.Path(args.intellij_home)
    libraries = list((home / 'lib').rglob('*.jar'))
    if not libraries:
        raise SystemExit('JetBrains platform jars not found; use the IDE Contents directory.')
    jdk = pathlib.Path(subprocess.check_output(['/usr/libexec/java_home'], text=True).strip())
    classes = root / '.build' / 'editor-companion-classes'
    shutil.rmtree(classes, ignore_errors=True)
    classes.mkdir(parents=True)
    subprocess.run([str(jdk / 'bin/javac'), '--release', '21', '-proc:none', '-Xlint:deprecation', '-cp', os.pathsep.join(map(str, libraries)), '-d', str(classes), *map(str, (root / 'editor-companions/intellij/src').rglob('*.java'))], check=True)
    jar = output / 'meeting-assist-editor.jar'
    with zipfile.ZipFile(jar, 'w', zipfile.ZIP_DEFLATED) as archive:
        for file in classes.rglob('*.class'):
            archive.write(file, str(file.relative_to(classes)))
        archive.write(root / 'editor-companions/intellij/resources/META-INF/plugin.xml', 'META-INF/plugin.xml')
    with zipfile.ZipFile(output / 'meeting-assist-intellij.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.write(jar, 'meeting-assist-editor/lib/meeting-assist-editor.jar')
    jar.unlink()
    print('Compiled and packaged IntelliJ companion against installed JetBrains platform.')

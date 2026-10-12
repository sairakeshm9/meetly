#!/bin/zsh
set -eu
cd "${0:A:h}/.."
swift test
swift build -c release -Xswiftc -warnings-as-errors
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
python3 scripts/check-secrets.py
node --test editor-companions/vscode/test.js
python3 scripts/build-editor-companions.py

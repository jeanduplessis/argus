#!/usr/bin/env python3
from pathlib import Path

text = Path("Argus/Services/WorkspaceManager.swift").read_text()
if "func hasDuplicateProject(repositoryRoot:" not in text:
    raise SystemExit("FAIL: duplicate project detection should use a named canonical-root helper")
if "hasDuplicateProject(repositoryRoot: repositoryRoot)" not in text:
    raise SystemExit("FAIL: createProject must check duplicates using the canonical repository root")
helper = text.split("func hasDuplicateProject(repositoryRoot:", 1)[1].split("\n    /// Creates a new workspace", 1)[0]
if "!$0.isCatchAll" not in helper:
    raise SystemExit("FAIL: duplicate detection must ignore catch-all")
if "URL(fileURLWithPath: $0.repositoryPath).resolvingSymlinksInPath().path" not in helper:
    raise SystemExit("FAIL: existing project paths must be canonicalized before comparison")

# TermLoom source package

Source: https://github.com/Frank-III/termloom

Upstream revision: `ff6dd74f7daaef393480c24de734c1435719ad46`

This local Swift package contains upstream `Sources/TermLoom` and
`Packages/TermLoomTextArea/Sources/TermLoomTextArea`, plus its MIT license.
Its manifest exposes both modules from one package. Optional upstream syntax
highlighting, test support, demos and their dependencies are not included.

Tatara carries the same runtime changes previously applied to dependency
checkouts:

- `Input.swift` preserves all four SGR wheel directions, including modifiers.
- `Application.swift` and `TerminalSession.swift` provide opt-in, bounded scroll
  presentation batches, preserving every input transition and cancellation.

These changes are committed source, so `swift build` never mutates package
caches and needs no preparation command. `PresentationTests` and
`ScrollPresentationTests`, plus Release PTY wheel and workspace scenarios,
exercise the modified behavior.

When updating, compare against the recorded upstream revision, reevaluate both
changes and preserve the upstream license. Return to a remote dependency when
upstream exposes both products and provides the required input/presentation
behavior. See Git history for the exact local changes.

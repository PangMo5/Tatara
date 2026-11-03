# Localization

English is the source language. Tatara supports English, Korean, Japanese,
Simplified Chinese and Traditional Chinese (Taiwan).

`SharedResources/Localizable.xcstrings` owns all application copy. TermLoom `Text`
displays a literal string, so Tatara resolves translations explicitly. The catalog
is compiled into a Swift table instead of a Foundation resource bundle: a command
line executable must continue to work after local installation or a change to
its launch path. The generator validates all five locales and CI checks freshness.

Language precedence is `--language`, `config.toml`, `LC_ALL`, `LC_MESSAGES`, `LANG`,
then the system preferred language. `C` and unsupported languages select English.
`--language zh-Hant` explicitly selects Taiwan Traditional Chinese.

Use concise action labels and complete, helpful error sentences. Korean uses
해요체 for explanatory copy. Japanese uses familiar conversational terminology.
Traditional Chinese uses Taiwan terms such as 檔案 and 設定. Keep GitHub, Pull
Request/PR, source text, paths, identifiers, tool output and API state names intact.
LEFT/RIGHT mean GitHub's old/new source sides.

Translations are an initial authored set. Native-language editorial review remains
part of release preparation, distinct from catalog completeness and layout tests.

# ContentBlockerConverter

The `ContentBlockerConverter` target of [AdGuard SafariConverterLib](https://github.com/AdguardTeam/SafariConverterLib), copied from tag `v4.3.1` (commit `1cfdcaf042880a5e0027a8fc6f7ebf9ee667acc9`). Licensed under the GNU General Public License v3.0; see `LICENSE`.

Five files differ from upstream:
- `Package.swift` keeps only this target, drops the `GenerateVersion` build plugin and pins swift-psl to exactly 1.1.195.
- `Sources/ContentBlockerConverter/ContentBlockerConverterVersion.swift` holds the version the plugin would have generated.
- `Compiler/Compiler.swift`: `compactDomainCssRules` walks its domains in sorted order, so the same filters always give the same JSON (upstream iterates a Dictionary, whose order changes per run).
- `ContentBlockerConverter.swift`: `convertArray` takes `maxRules`, so Artemis can keep room for its own exceptions under WebKit's 150k ceiling.
- `Compiler/SafariCbBuilder.swift`: over `maxRules`, only blocking groups lose rules, generic CSS first; upstream cut from the end of the list, which holds the exceptions.

AdGuard doesn't evaluate `!#if` preprocessor blocks; the rules inside them are converted unconditionally.

To update, copy `Sources/ContentBlockerConverter` from the new tag over this one, re-apply the `Compiler.swift` sort, the `maxRules` parameter and the `SafariCbBuilder.swift` trim, then bump the tag, commit and versions in `ContentBlockerConverterVersion.swift` and here. Bump `ContentBlocker.converterRevision` for any change that isn't a version bump.

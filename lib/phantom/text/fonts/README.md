# Vendored built-in fonts

These are the default branding fonts for PhantomUI, vendored here so they are always
available (embedded via `@embedFile`) and so the build needs no font download.

## Fonts

| File | Family | Designer |
|------|--------|----------|
| `Neuropol.otf` | Neuropol | Raymond Larabie (Typodermic Fonts) |
| `Mesmerize Rg.otf` | Mesmerize (Regular) | Raymond Larabie (Typodermic Fonts) |
| `Mesmerize Sb.otf` | Mesmerize (Semibold) | Raymond Larabie (Typodermic Fonts) |

All three are CFF-outline OpenType (`.otf`, sfnt tag `OTTO`).

## Source

Extracted from the Typodermic Fonts public-domain release
`typodermic-public-domain-2024-12.zip` (the `OpenType Fonts/` directory), from
https://typodermicfonts.com/public-domain/ .

## License

CC0 1.0 Universal (public domain dedication). Raymond Larabie has waived all
copyright and related rights. See `License.txt` (the release's own dedication) and
https://creativecommons.org/publicdomain/zero/1.0/ . CC0 imposes no attribution
requirement; this citation and `License.txt` are kept for provenance.

## Why vendored (not a build.zig.zon dependency)

Typodermic distributes only a single 22MB, 729-font bundle, with no per-font URL.
Vendoring the three ~40-50KB fonts we need is far smaller and, unlike a fetched
dependency, needs no `zig.fetchDeps` fixed-output derivation: vendored fonts are
plain source files included in the tree.

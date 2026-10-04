# Kotlin Name Hints

## Purpose

Index surviving Kotlin metadata as investigation hints. Shrinkers may remove or
rewrite metadata; original class names and recovery rates are not guaranteed.

## Evidence types

- `@DebugMetadata(c = "com.example.Repository$fetch$1")` associates a coroutine
  class with an outer owner. It does not prove that the coroutine class itself
  should be renamed to `Repository`.
- The first `@Metadata.d2` string can be a self descriptor. Store it separately
  as an unverified candidate. Later descriptors can refer to dependencies;
  never assign them as the containing class's name.
- jadx `renamed from` comments identify a previous name, often an obfuscated
  name. Do not treat those comments as recovered original Kotlin names.

## Usage

Run `bash scripts/recover-kotlin-names.sh <sources> <mapping>` or, on Windows,
`& ./scripts/recover-kotlin-names.ps1 <sources> <mapping>`.

Outputs:

- `mapping.json` and `mapping.tsv`: coroutine owner hints for navigation.
- `evidence.json`: evidence type, file, and confidence for each hint.
- `candidates.json`: unverified metadata self-descriptor candidates, excluded
  from the lookup mapping.
- `by_package/`: generated navigation indexes.

Use `lookup-name.sh` on Bash platforms to search or annotate source hits. On
Windows inspect the JSON/TSV files directly.

## Validate before using

Compare the proposed owner with declaration shape, enclosing classes, fields,
interfaces, and call sites. Do not rename from a hint alone. Missing metadata,
inlining, name rewriting, and decompiler changes can all limit results.

`jadx --deobf` generates readable replacement names; it does not guarantee the
original developer names. An original build mapping file, when available, is
stronger evidence than this heuristic index.

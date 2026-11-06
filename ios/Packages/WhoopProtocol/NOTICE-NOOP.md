# NOTICE — WhoopProtocol is a copy of noop's package

| | |
|---|---|
| Source | <https://github.com/ryanbr/noop> |
| Commit | `e58017508d9731c51d0631fe0eb4bb1d7ea0c582` (`e580175`, 2026-10-10 01:27 +13:00, "fix(today): say what the heart-rate read returned, not why") |
| Path copied | `Packages/WhoopProtocol/` — every file in that tree at the commit (sources, executables, tests, test fixtures, `whoop_protocol.json`) |
| Changes | **None.** Each `.swift` file has one added attribution line (line 1; line 2 in `Package.swift`, whose first line must stay `// swift-tools-version:`). Below that line every file is byte-identical to the git blob at the commit. No `// MG-EDIT:` lines exist. |
| Copied | 2026-10-11 by WP-04 of the overnight build (ARCHITECTURE.md D3, R4) |

## Licence

noop is licensed under the **PolyForm Noncommercial License 1.0.0** —
<https://polyformproject.org/licenses/noncommercial/1.0.0>. This app is for Mo's personal, non-commercial use
(PLAN rule 8), which that licence permits. The licence's notice rule asks that anyone who receives a copy also
gets the licence terms (or the URL above) and the Required Notice line below.

Required Notice: Copyright 2026 NoopApp

noop's LICENSE also states that the protocol facts it documents (UUIDs, frame layouts, CRC parameters, command,
event and packet numbers, byte offsets) are factual and not claimed as anyone's property. noop's third-party
components keep their own licences; this package has none (pure Foundation).

## Checking the copy

The byte-identity check (header line removed → equals `git cat-file blob e580175:<path>`) was run on the
build PC on 2026-10-11; its output is in WP-04's report. `swift test --package-path app/ios/Packages/WhoopProtocol`
runs noop's own tests against the copy (needs a Mac).

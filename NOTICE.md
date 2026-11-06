# NOTICE - third-party material in the MG app

Written 2026-10-11 (WP-25). This is the app-level list; the per-file attribution lines (ARCHITECTURE.md R4) stay in each
copied file. Mo's own code in this folder carries no licence statement here.

## noop - copied and ported code (PolyForm Noncommercial 1.0.0)

Required Notice: Copyright 2026 NoopApp

| | |
|---|---|
| Source | <https://github.com/ryanbr/noop> |
| Commit | `e58017508d9731c51d0631fe0eb4bb1d7ea0c582` (`e580175`), 2026-10-10 |
| Licence | PolyForm Noncommercial License 1.0.0 - <https://polyformproject.org/licenses/noncommercial/1.0.0> (noop's `LICENSE`, which carries the Required Notice line above) |
| Copied | `ios/Packages/WhoopProtocol/` - noop's `Packages/WhoopProtocol`, every file at that commit including its tests and test data, unchanged apart from one attribution line added to each `.swift` file. Details and the byte-identity check: `ios/Packages/WhoopProtocol/NOTICE-NOOP.md`. |
| Ported (re-written, not copied) | The strap connect / history / clock logic in `ios/Packages/MGBLE` follows noop's `BLEManager.swift`, `Backfiller.swift` and `docs/PROTOCOL_*.md`; the code comments cite the noop file and line for each protocol fact. |

This app is for personal, noncommercial use (PLAN rule 8), which the licence permits. The licence does not grant commercial
use. Anyone who receives a copy of any part of this software from you must also receive the licence terms (the URL above)
and the Required Notice line above. noop's `LICENSE` also states that the protocol facts it documents (UUIDs, frame
layouts, CRC parameters, command / event / packet numbers, byte offsets) are factual and not claimed as anyone's property.

## GRDB.swift 6.29.3 - SQLite toolkit (MIT)

Used by `ios/Packages/MGStore`; fetched by Swift Package Manager at build time, pinned exactly (`ios/project.yml`).
<https://github.com/groue/GRDB.swift>

```
Copyright (C) 2015-2024 Gwendal Roué

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

(Text from the `v6.29.3` tag's `LICENSE`, fetched 2026-10-11.)

## adhan-swift 1.5.0 - prayer-time astronomy (MIT), ported

Added 2026-10-11 for the Fajr wake. The Fajr and sunrise calculation in
`ios/Packages/MGContext/Sources/MGContext/Alarms/PrayerTimes.swift` is re-typed from adhan-swift (files and functions listed
in that file's header); it is not linked as a dependency. Its tests use numbers from adhan's own test data.
<https://github.com/batoulapps/adhan-swift> (tag `1.5.0`)

```
The MIT License (MIT)

Copyright (c) 2016 Batoul Apps

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

(Text from the `1.5.0` tag's `LICENSE`, fetched 2026-10-11; the source files' headers say "Copyright © 2018 Batoul Apps".)

## Protocol research - facts only, no code

The WHOOP strap protocol facts used here come from community reverse engineering. Only the facts are used (identifiers,
frame layouts, opcodes, byte offsets); no source code from these projects is in this app. noop's own `NOTICE` and
`ATTRIBUTION.md` name the two it builds on:

- johnmiddleton12/my-whoop - WHOOP 4.0 protocol (<https://github.com/johnmiddleton12/my-whoop>)
- b-nnett/goose - WHOOP 5.0 / MG protocol (<https://github.com/b-nnett/goose>)

Code comments in this app also cite the judes.club write-up, whoomp and Asherlc/dofek where a fact was checked against them.

## Not bundled

No fonts (the app uses the system fonts), no images or icons from other projects (the app icon is a placeholder drawn by a
script), and no other Swift or Rust dependency in the app (the Rust crate planned in ARCHITECTURE.md 7.2 has none; its tests
use serde_json as a dev-dependency, which is never linked into the app). Build tools (Xcode, XcodeGen) and the PC Lab's
Python are used on your own machines and are not shipped in the IPA.

## Not affiliated with WHOOP

This is an independent project for reading a WHOOP strap you own. "WHOOP" is used only to name the hardware it works with.
It is not endorsed by, or connected to, WHOOP, Inc., and it is not a medical device.

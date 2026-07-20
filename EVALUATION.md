# Zig port evaluation

> **Superseded.** This evaluation's recommendation — keep the previous
> implementation as the shipped default — was not adopted. The
> implementation evaluated here replaced the previous one entirely and is
> now the only implementation in this repository. The document is
> preserved unmodified below as the historical benchmark and rationale
> record.

## What was ported

The macOS/AVFoundation path only: full core (decode, A/V sync, color math),
Godot glue (VideoStreamPlayer plumbing, Texture2DRD/RD resource glue), and an
end-to-end smoke test, built with [gdzig](https://github.com/gdzig/gdzig) —
now our own fork, which carries the upstream Zig 0.16 port — Zig 0.16.0,
against Godot 4.6.3-stable. The Windows /
Media Foundation backend was **not** ported; this evaluation covers macOS
only.

Machine: Apple Silicon, 8 performance cores, macOS 27 beta, Apple clang 17.

Correctness bar the port had to clear before any of the numbers below were
trusted:

- 218/218 pure-Zig core tests pass via `zig build test` (the entire C++
  doctest suite was ported, including the one-clock A/V-sync tests).
- The e2e smoke test (real `ResourceLoader` + `VideoStreamPlayer`, plays
  `project/synthetic.mp4`, self-quits) prints `SMOKE: PASS` / `content =
  REAL` with an average pixel value matching the C++ baseline exactly.
- Stability: 46 consecutive clean Debug runs in an earlier pass, plus 3/3
  smoke runs and 7/7 timed runs clean in ReleaseFast this session. The C++
  control had 0/15 crashes over the same kind of run. One rare timing flake
  was observed in the core test suite under heavy parallel load, once in
  roughly 10 full-suite runs — noted here rather than hidden. This machine
  has historically shown occasional shutdown aborts in CoreSpotlight/
  LaunchServices system threads (macOS 27 beta noise, unrelated to the
  extension); none occurred in the 10 release-build runs measured here.

## TL;DR

| Question | Verdict |
|---|---|
| Performance | Parity. Runtime medians differ by ~0.04s wall / ~1 MB RSS, inside run-to-run noise. Both builds are thin wrappers over the same AVFoundation decode + Metal present path, so this was the expected outcome, not a surprise. |
| Binary size | Mixed once compared honestly per architecture. Zig `ReleaseSmall` is clearly smaller than the C++ arm64 slice, stripped or not; Zig `ReleaseFast` stays larger than the C++ arm64 slice in both states — about 25% bigger unstripped, ~8% bigger stripped. |
| Dev experience | Net positive, taxed by gdzig's immaturity. Sub-second warm builds and a core test suite that needs no Godot/scons are real wins; an 8-item bug ledger of gdzig defects ate most of the port's debugging time. |
| Maintainability | Favorable on raw numbers (smaller product LOC, test parity, larger testable-core share), but gated by a single hard risk: gdzig is pre-1.0, unreleased, and pinned to a commit + a specific Zig version. |

---

## 1. Performance

Runtime measured with `/usr/bin/time -l`, 7 timed runs each, medians taken.
Scenario: launch Godot, load the extension, play the clip, verify decoded
content, quit.

| | Zig (ReleaseFast) | C++ (template_release) |
|---|---|---|
| Median wall | 3.20 s | 3.24 s |
| Median user | 0.48 s | 0.51 s |
| Median sys | 0.22 s | 0.22 s |
| Peak RSS | 268,189,696 B (~255.8 MiB) | 269,172,736 B (~256.7 MiB) |
| Wall range across runs | 3.17–3.20 s | 3.20–3.26 s |
| Pass rate | 7/7 | 7/7 (8/8 incl. one excluded warm-up run) |

Deltas (0.04s wall, 0.03s user, ~1 MB RSS) are within run-to-run noise on
this machine. This is the expected result: both builds hand the actual
decode and present work to AVFoundation and Metal, so the extension layer's
language doesn't touch the part of the pipeline that dominates wall time.
Treat this as confirmation that the port didn't regress performance, not as
evidence Zig is faster — the test doesn't exercise a code path where the two
languages could differ.

## 2. Binary size

Raw numbers, `libnative-video` dylib, both languages, various build modes.

| Build | Unstripped | `strip -x` |
|---|---|---|
| C++ `template_release` (universal x86_64+arm64) | 707,120 B | 707,144 B (*larger* — code-signature rewrite outweighs the removed local symbols) |
| C++ `template_debug` (universal) | 723,960 B | — |
| Zig `ReleaseFast` (arm64 only) | 454,552 B | 392,216 B |
| Zig `ReleaseSmall` (arm64 only) | 227,176 B | 176,888 B |
| Zig `Debug` (arm64 only) | 1,985,320 B | 1,536,704 B |

The C++ dylib is a universal binary; the Zig dylib is arm64-only. Comparing
the totals above directly flatters Zig by roughly 2x, because half the C++
number is an x86_64 slice Zig doesn't build at all. Per-architecture slice
sizes, from `lipo -detailed_info` on the C++ `template_release` dylib:

| Architecture | Slice size |
|---|---|
| x86_64 | 335,600 B |
| arm64 | 363,056 B |

(335,600 + 363,056 = 698,656; the remaining 8,464 bytes of the 707,120-byte
universal total is fat-header/alignment padding between slices.)

Comparing honestly, arm64-to-arm64:

- Zig `ReleaseFast` unstripped (454,552 B) is **larger** than the C++ arm64
  slice (363,056 B) — about 25% bigger. Stripped, Zig `ReleaseFast` (392,216
  B) is still about 8% larger than the C++ arm64 slice.
- Zig `ReleaseSmall` (227,176 B unstripped / 176,888 B stripped) is clearly
  smaller than the C++ arm64 slice in both states.

Note the stripped Zig numbers above are being compared against the
*unstripped* C++ arm64 slice: `lipo` was only run against the unstripped
universal C++ binary, and a stripped C++ slice number wasn't produced
because `strip -x` on the C++ dylib actually grew the universal file
slightly (the code-signature gets rewritten and outweighs the removed local
symbols), so stripping wasn't expected to move the C++ number down anyway.

So the size story depends entirely on which Zig build mode is in play.
`ReleaseFast` is not a size win over C++; `ReleaseSmall` is. Anyone citing
"Zig is smaller" needs to say which mode and needs to compare same-arch
numbers, not the raw totals above.

## 3. Build times

Measured wall / user / sys via `/usr/bin/time -l`. C++: `scons
target=template_release platform=macos -j8`, cold run with `SCONS_CACHE`
bypassed (the environment has a global `SCONS_CACHE` that would otherwise
replay objects — the first "cold" attempt was a 0.76s replay and had to be
discarded). Zig: `zig build`, zig 0.16.0, cold run means `rm -rf
zig/.zig-cache`; the global `~/.cache/zig` package cache was **not**
cleared, so this cold number is optimistic relative to a genuinely first-run
machine. Zig's cold build also spawns Godot once to dump extension
headers/API via gdzig's `HeadersStep`.

| | C++ (scons) | Zig (zig build) |
|---|---|---|
| Cold (98 TUs incl. all of godot-cpp / full compile) | 9.40s wall / 56.31s user / 7.52s sys | ReleaseFast: 14.73s / 14.36s / 0.29s; Debug: 11.77s / 11.95s / 2.80s |
| Warm (real change, one file) | 1.51s / 1.35s / 0.21s | 0.25s / 0.09s / 0.17s |
| No-op rebuild | not separately measured | 0.25s (indistinguishable from warm) |

Two things to flag rather than smooth over:

- A bare `touch` on a source file is a no-op for SCons, because it hashes
  file content (MD5 signatures), not mtimes. A prior session's reported
  "warm 11.5s wall / 58.7s user" for C++ was very likely a cold-adjacent
  measurement caused by exactly this — a touch that didn't actually
  invalidate anything, followed by a change that did.
- Cold wall time favors C++ (9.4s vs 14.7s) but user CPU time favors Zig by
  a wide margin (56.3s vs 14.4s), because SCons parallelizes 98 translation
  units across 8 cores while the Zig cold build is mostly a single
  compilation unit plus one Godot spawn. On a single-core or heavily loaded
  machine the wall-time gap would likely close or invert.

Where Zig wins unambiguously is warm iteration: 0.25s vs 1.5s, a 6x
difference, and that's the number that matters most during day-to-day
development.

---

## 4. Dev experience

### Cost: the gdzig bug ledger

> **Status update:** every numbered bug below has since been fixed at the
> source in our gdzig fork (branch `media-streams-fixes`, with regression
> tests per fix), and the corresponding workarounds were removed from
> `src/godot/`. Two things survived the sweep by design, not as bugs:
> `_getTexture` keeps one `reference()` because gdzig virtual returns use
> transfer semantics (the engine consumes a ref), and the output-mode
> property accessors stay `i64` because Variant-dispatched integers are
> i64-only. Item 8 (casing) is deliberate gdzig house style, not fixed.
> The ledger below is preserved as the historical record of the port.

Every one of these was hit during the port, root-caused, and worked around.
This is the real cost of building against a pre-1.0 binding generator, and
it consumed most of the port's debugging time.

1. `RefCounted.init()` leaves the initial ref *pending* — passing a freshly
   constructed object into an engine method frees it out from under you.
   Fix: call `_ = x.reference()` after init (hit on `RDShaderSource`,
   `RDSamplerState`, `RDTextureFormat`, `RDTextureView`).
2. Raw-pointer virtual returns are engine-*adopted* — objects returned from
   `_get_texture` and similar virtuals must be `reference()`d before
   returning, or the owned refs backing `Texture2DRD` and the loader
   singleton get collected.
3. Null-optional `Array` arguments segfault gdzig outright.
4. `TextureUsageBits` packed-struct bit positions are wrong after
   `DEPTH_RESOLVE` — worked around with `@bitCast` to raw masks instead of
   trusting the generated struct layout.
5. Virtual/raw-bind integer parameters must be `i64` to match the engine
   ABI; getting this wrong doesn't always fail loudly.
6. Malformed `ShaderStage`/`DriverResource` enums in generated bindings.
7. Broken `String.fromUtf8`.
8. Assorted mechanical casing quirks in generated names.

On top of the numbered bugs: gdzig has no releases (we now build against
our fork, which also carries the upstream Zig 0.16 port); and generated
bindings under `.zig-cache/o/*/gdzig/class/*.zig` had to be eyeballed
before relying on any nontrivial call, because the generator's output
wasn't trustworthy by default.

### Benefit: what worked well

- The 218-test pure-Zig core is runnable with `zig build test` alone — no
  SCons, no godot-cpp submodule, no Godot binary needed for core
  development.
- Single-binary toolchain: `build.zig` replaces the scons + python tooling
  entirely. Warm builds land at 0.25s (see build-time section above).
- Inline tests live next to the code they test, rather than in a separate
  tree.
- Zig's explicit allocators caught real leaks during development that would
  have been silent in the C++ port.
- The C-ABI Objective-C interop for the AVFoundation shim worked cleanly.
  A standalone `decode_smoke.zig` CLI harness (43 lines, no Godot
  dependency) isolated decode-side lifetime bugs on its own.
- Every engine-adoption/ref-count workaround is documented in a code
  comment at its call site, so the ledger above isn't tribal knowledge —
  it's discoverable in the diff.

## 5. Maintainability

### Lines of code (raw `wc -l`, blanks and comments included; Windows/MF/DX
backends excluded from the C++ side for a fair comparison)

| | C++ | Zig |
|---|---|---|
| Product | 6,684 (41 files) | 6,120 (part of 35 files) |
| — core | 2,835 (13 files) | 3,667 |
| — glue (Godot) | 2,821 (20 files) + 66 register_types (2 files) | 2,007 |
| — AVFoundation backend | 962 (3 files) | 446 |
| Tests | 6,576 total (core 4,960/18 files; avf 406; shared fixtures 1,210) — core-only comparison: 4,960 | 4,834 (inline 1,684 + dedicated `*_test.zig` 3,150; 223 test blocks) |
| Harness | — | `decode_smoke.zig`, 43 lines, standalone no-Godot decode CLI |

Headline: product code is 6,684 (C++) vs 6,120 (Zig) — about 8% smaller on
the Zig side. Core-test line counts are close to parity: 4,960 vs 4,834.

### Core/glue split

C++ is 42% core / 58% glue by line count. Zig is 60% core / 40% glue, but
that shift is partly an artifact of reclassification: some color-math and
shader-adjacent code that lived in the glue layer in C++ was moved into the
testable core in Zig specifically because it was easy to make testable
there. Comparing apples-to-apples with the same classification puts Zig at
roughly 49% core / 51% glue versus C++'s 42/58 — still a real shift toward
more code under core-test coverage, just smaller than the raw 60/40 number
suggests.

### Test-suite fidelity

The entire C++ doctest suite was ported to Zig, not a subset — including
the one-clock A/V-sync tests, which are the trickiest tests to port
faithfully because they depend on ordering and timing assumptions baked
into the original suite. One rare timing flake was observed in the ported
suite under heavy parallel load, seen once in roughly 10 full-suite runs.
That's a real flake, not zero, and should be tracked if it recurs — but it
did not block the 218/218 passing bar this evaluation used as its
correctness gate.

### Dominant risk

Everything above is favorable to Zig on paper. The risk that overrides all
of it: **gdzig is pre-1.0**. It has no tagged releases, and this project now
builds against its own fork (a local path dependency carrying the upstream
Zig 0.16 port) rather than a single pinned upstream commit. Any
maintainability argument for the Zig port has to be discounted by the fact
that the binding layer underneath it can change out from under the project
with no compatibility guarantee, and the
8-item bug ledger above is exactly the kind of thing that surfaces when a
generator like this is still moving.

---

## Recommendation

The Zig port should **not** replace the C++ extension outright right now,
for one concrete reason: Windows/Media Foundation was never ported, and the
C++ extension is cross-platform while the Zig port is macOS-only. Cutting
over would mean either shipping without Windows support or maintaining two
extensions side by side, and neither is worth it for a port whose main
measured advantage (build-time iteration speed) doesn't move the needle on
end-user-facing behavior.

Where the data does support acting:

- **The Zig core is a keeper regardless of what happens with the glue
  layer.** It covers more of the product surface under independent test
  (60% core vs C++'s 42%, partly the reclassification effect described
  above — the raw core line count is actually larger, 3,667 vs 2,835, not
  smaller), it has full test parity with the C++ core suite, it builds and
  tests in under a second warm with zero Godot/SCons dependency, and its
  bugs (leaks caught by explicit allocators) are the
  kind that stay fixed. If a Windows/MF port to Zig is ever attempted, the
  core doesn't need to be redone.
- **The gating risk is gdzig's maturity, not the Zig language or the port
  itself.** The 8-item bug ledger is real cost, but every entry was
  root-caused and is now documented at its call site — it's a one-time tax
  already paid, not a recurring one, as long as gdzig's pinned commit
  doesn't move. The moment gdzig cuts a 1.0 or otherwise stabilizes its
  bindings and Zig-version support, revisit this: at that point the
  build-time and testability wins stop being offset by generator risk.
- **Binary size is not a reason to switch either way.** `ReleaseSmall` is
  smaller than C++ per architecture; `ReleaseFast` — the mode you'd actually
  ship — is not. This axis is a wash unless the product specifically wants
  to trade runtime performance headroom for a smaller download, and nothing
  in the runtime numbers suggests `ReleaseFast` has headroom to spare over
  `ReleaseSmall` worth checking.
- **Performance is a non-factor**, confirmed rather than assumed: the
  measured parity is exactly what the architecture predicts, since both
  extensions are thin wrappers over the same AVFoundation/Metal path.

Concretely: keep the Zig port in the repo as the reference core
implementation, do not merge the glue/AVFoundation layer over the existing
C++ extension as the shipped default, and re-evaluate a full cutover only
once gdzig has a release with a stability/versioning story that doesn't
require pinning a commit and freezing the Zig toolchain version.

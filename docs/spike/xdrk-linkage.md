# Spike evidence — is the `xdrk` crate a native Rust `.xrk` reader?

**Issue:** 1.1 (decode-strategy ADR). **Date:** 2026-07-15.
**Probe:** [`scripts/spike_xdrk_linkage.sh`](../../scripts/spike_xdrk_linkage.sh)
(reproducible; see *How to reproduce* below).
**Crate inspected:** [`xdrk` v1.0.0](https://crates.io/crates/xdrk)
(bmc::labs, `https://gitlab.bmc-labs.com/libraries/xdrk`).

## Question

`xdrk` is the only third-party Rust crate on crates.io that reads AiM `.xrk`
files. If it is *native* Rust it could be wrapped instead of writing a decoder
(issue-1.1 option **b**). If it links or vendors AiM's proprietary C library, it
reintroduces the exact non-native, redistribution-encumbered dependency the
native rewrite (M1) exists to eliminate — so it must be **rejected**.

## Finding — `xdrk` is **NON-NATIVE** (rejected)

`xdrk` is a thin `extern "C"` FFI wrapper (`src/bindings.rs`) around AiM's
**proprietary, precompiled** shared library. It is not a Rust decoder.

### 1. It vendors AiM's proprietary binaries

The crate ships prebuilt AiM libraries under `aim/`. `file(1)` on each:

```
aim/libmatlabxrk.so.0 : ELF 64-bit LSB shared object, x86-64, (GNU/Linux), not stripped
aim/libxdrk-x86_64.dll: PE32+ executable (DLL) (GUI) x86-64, for MS Windows
aim/libxdrk-x86_64.lib: current ar archive
aim/libxdrk-x86_64.so : ELF 64-bit LSB shared object, x86-64, (GNU/Linux), not stripped
```

These are **AiM's proprietary** `libxdrk` / `libmatlabxrk` binaries (a MATLAB
Runtime dependency), redistribution-encumbered — not open, not Rust.

### 2. `build.rs` links them at compile time

`aim/build.rs` copies the vendored libs into `OUT_DIR` and emits link directives:

```
cargo:rustc-link-search=all={out_dir}/lib
cargo:rustc-link-lib=xdrk-x86_64      # unix
cargo:rustc-link-lib=xml2             # unix
cargo:rustc-link-lib=dylib=libxdrk-x86_64   # windows
```

So every binary built against `xdrk` statically depends on AiM's C library.

### 3. There is **no native macOS / arm64 artifact**

The only shipped objects are **x86_64 Linux (`.so`)** and **x86_64 Windows
(`.dll`)**. There is **no `.dylib`, no `arm64`/`aarch64`** object at all. On the
Apple-Silicon macOS this project targets, `xdrk` cannot even link, let alone run
natively. This alone disqualifies it, independent of the licensing concern.

### Probe verdict (verbatim)

```
  vendored native binaries present : yes
  build.rs links a vendored lib    : yes
  native macOS/arm64 artifact       : no

VERDICT: 'xdrk' is NON-NATIVE — it links/vendors a proprietary C library.
         Worse: it ships NO native macOS/arm64 artifact, so it cannot even
         link on Apple Silicon. Rejected for the native rewrite.
```

## Conclusion

Wrapping `xdrk` (option **b**) is **rejected**: it is non-native (proprietary
C library, not Rust), redistribution-encumbered, and ships **no macOS/arm64**
binary — the opposite of the native, self-contained goal. Combined with the
Python-`libxrk` FFI option (**c**, rejected up front for keeping a Python
runtime), the only path that meets the "native, no proprietary blobs" bar is a
**clean-room Rust port** (option **a**), validated against `libxrk`'s output as
the decode oracle. See
[`docs/adr/0002-xrk-decode-strategy.md`](../adr/0002-xrk-decode-strategy.md).

## How to reproduce

The probe is read-only w.r.t. the working tree — it builds a throwaway crate in
a temp dir, adds `xdrk`, fetches its source, and inspects the vendored binaries
+ `build.rs`:

```sh
bash scripts/spike_xdrk_linkage.sh      # prints the evidence above + VERDICT
```

Or by hand:

```sh
cd "$(mktemp -d)" && cargo new --lib probe && cd probe
cargo add xdrk && cargo fetch
SRC=$(find ~/.cargo/registry/src -maxdepth 2 -type d -name 'xdrk-*' | sort | tail -1)
file "$SRC"/aim/*                                   # -> x86_64 .so/.dll, no macOS
grep -n 'rustc-link-lib' "$SRC/build.rs"            # -> links xdrk-x86_64
```

> `xdrk` is intentionally **not** a dependency of this workspace — adding it
> would pull the proprietary, non-macOS blob into our build graph. The live
> end-to-end probe is exercised by the `#[ignore]`d
> `live_probe_confirms_finding` test
> (`core/racestudio-decode/tests/spike_xdrk_linkage.rs`), run on demand with
> `cargo test -p racestudio-decode -- --ignored`.

//! Version-pinned `uniffi-bindgen` CLI, built only with `--features bindgen`.
//! `scripts/build_xcframework.sh` runs this to generate the Swift bindings so
//! the bindgen version always matches the `uniffi` runtime crate.

fn main() {
    uniffi::uniffi_bindgen_main()
}

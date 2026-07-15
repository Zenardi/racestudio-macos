// Shared test-support code for the decode crate. Each integration-test crate
// includes this via `mod support;`, so not every item is used by every test —
// silence the resulting dead-code warnings.
#![allow(dead_code)]

pub mod fixtures;

#![no_main]
use libfuzzer_sys::fuzz_target;

// NBIS's WSQ decoder on its own (native/nbis_ref). Not a decoder we ship:
// this target is for reproducing and minimising the inputs that crash it,
// which are kept as regression inputs for the Rust decoder (regressions/wsq).
fuzz_target!(|data: &[u8]| {
    let _ = nbis_ref::decode_wsq(data);
});

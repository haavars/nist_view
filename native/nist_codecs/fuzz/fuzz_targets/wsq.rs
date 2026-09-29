#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let _ = nist_codecs::nbis::decode_wsq(data);
});

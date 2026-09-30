#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let _ = nist_codecs::headers::jpeg(data);
    let _ = nist_codecs::headers::jp2(data);
});

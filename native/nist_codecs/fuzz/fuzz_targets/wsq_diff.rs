#![no_main]
use libfuzzer_sys::fuzz_target;

// The Rust WSQ decoder against NBIS (native/nbis_ref). Whatever
// `decode_strict` accepts, NBIS must decode to the same image, without a
// memory error (the C code is built with AddressSanitizer). NBIS is not run
// on what the Rust decoder rejects: it has known memory bugs there.
fuzz_target!(|data: &[u8]| {
    let Ok(rust) = nist_codecs::wsq::decode_strict(data) else {
        return;
    };

    let nbis = nbis_ref::decode_wsq(data).expect("NBIS rejects what decode_strict accepts");
    assert_eq!((rust.width, rust.height, rust.ppi), (nbis.width, nbis.height, nbis.ppi));
    assert!(rust.data == nbis.pixels, "pixels differ from NBIS");

    let lenient = nist_codecs::wsq::decode(data).expect("decode rejects what decode_strict accepts");
    assert!(lenient.data == rust.data && lenient.ppi == rust.ppi, "decode and decode_strict differ");
});

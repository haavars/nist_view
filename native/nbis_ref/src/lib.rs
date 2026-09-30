//! NBIS 5.0.0's WSQ decoder (C, vendored and patched; see README.md), built
//! without fused multiply-add.
//!
//! This is the reference the Rust decoder is compared against in tests and
//! differential fuzzing (docs/wsq-port.md). It has known memory bugs on
//! malformed input: never ship it, and only hand it untrusted bytes under
//! AddressSanitizer or in a process that may crash.

use std::os::raw::{c_int, c_uchar, c_void};
use std::sync::Mutex;

extern "C" {
    fn wsq_decode_mem(
        odata: *mut *mut c_uchar,
        ow: *mut c_int,
        oh: *mut c_int,
        od: *mut c_int,
        oppi: *mut c_int,
        lossyflag: *mut c_int,
        idata: *mut c_uchar,
        ilen: c_int,
    ) -> c_int;

    fn free(ptr: *mut c_void);
}

/// NBIS keeps the WSQ decoder's tables in global variables, so only one
/// WSQ decode may run at a time.
static WSQ_LOCK: Mutex<()> = Mutex::new(());

/// An image as NBIS decodes it: 8-bit greyscale, row-major.
#[derive(Debug, PartialEq, Eq)]
pub struct Image {
    pub width: u32,
    pub height: u32,
    /// From the `NIST_COM` comment; `None` when NBIS reports -1.
    pub ppi: Option<u32>,
    pub pixels: Vec<u8>,
}

/// Decodes with `wsq_decode_mem`. `None` when NBIS returns an error.
///
/// NBIS does no size check of its own: the caller limits the dimensions if
/// the input is not trusted.
pub fn decode_wsq(data: &[u8]) -> Option<Image> {
    let len = c_int::try_from(data.len()).ok()?;

    // NBIS takes a mutable pointer, although it only reads the input.
    let mut input = data.to_vec();
    let (mut out, mut w, mut h, mut d, mut ppi, mut lossy) =
        (std::ptr::null_mut(), 0, 0, 0, 0, 0);

    let ret = {
        let _guard = WSQ_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        unsafe {
            wsq_decode_mem(
                &mut out,
                &mut w,
                &mut h,
                &mut d,
                &mut ppi,
                &mut lossy,
                input.as_mut_ptr(),
                len,
            )
        }
    };

    // NBIS always returns 8-bit greyscale.
    let pixels = take_c_buffer(ret, out, w, h)?;

    Some(Image {
        width: w as u32,
        height: h as u32,
        ppi: (ppi > 0).then_some(ppi as u32),
        pixels,
    })
}

/// Copies a malloc'd C pixel buffer into a Vec and frees it. Returns None
/// if the call failed.
fn take_c_buffer(ret: c_int, out: *mut c_uchar, w: c_int, h: c_int) -> Option<Vec<u8>> {
    if out.is_null() {
        return None;
    }

    let result = if ret == 0 && w > 0 && h > 0 {
        let size = (w as usize) * (h as usize);
        Some(unsafe { std::slice::from_raw_parts(out, size) }.to_vec())
    } else {
        None
    };

    unsafe { free(out as *mut c_void) };
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    const SYNTHETIC: &[u8] = include_bytes!("../../../test/fixtures/synthetic.wsq");

    #[test]
    fn decodes_the_synthetic_fixture() {
        let image = decode_wsq(SYNTHETIC).expect("decodes");
        assert_eq!((image.width, image.height, image.ppi), (128, 96, Some(500)));
        assert_eq!(image.pixels.len(), 128 * 96);
    }

    #[test]
    fn rejects_data_that_is_not_wsq() {
        assert_eq!(decode_wsq(b""), None);
        assert_eq!(decode_wsq(b"not a WSQ image"), None);
    }
}

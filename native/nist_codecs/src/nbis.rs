//! WSQ and lossless JPEG through the vendored NBIS decoders.

use crate::{check_dimensions, headers, Error, Pixels};
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

    fn nist_codecs_jpegl_decode(
        idata: *mut c_uchar,
        ilen: c_int,
        odata: *mut *mut c_uchar,
        ow: *mut c_int,
        oh: *mut c_int,
        ochannels: *mut c_int,
        oppi: *mut c_int,
    ) -> c_int;

    fn free(ptr: *mut c_void);
}

/// NBIS keeps the WSQ decoder's tables in global variables, so only one
/// WSQ decode may run at a time. The lossless JPEG decoder has no globals.
static WSQ_LOCK: Mutex<()> = Mutex::new(());

pub fn decode_wsq(data: &[u8]) -> Result<Pixels, Error> {
    let (width, height) = headers::wsq(data).ok_or(crate::atoms::invalid_wsq())?;
    check_dimensions(width, height)?;
    let len = c_int::try_from(data.len()).map_err(|_| crate::atoms::too_large())?;

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
    let pixels = take_c_buffer(ret, out, w, h, 1).ok_or(crate::atoms::invalid_wsq())?;

    Ok(Pixels {
        width: w as u32,
        height: h as u32,
        channels: 1,
        ppi: positive(ppi),
        colorspace: crate::atoms::gray(),
        data: pixels,
    })
}

pub fn decode_jpegl(data: &[u8]) -> Result<Pixels, Error> {
    match headers::jpeg(data) {
        Some((0xC3, width, height)) => check_dimensions(width, height)?,
        Some(_) => return Err(crate::atoms::not_lossless_jpeg()),
        None => return Err(crate::atoms::invalid_jpegl()),
    }

    let len = c_int::try_from(data.len()).map_err(|_| crate::atoms::too_large())?;
    let mut input = data.to_vec();
    let (mut out, mut w, mut h, mut channels, mut ppi) = (std::ptr::null_mut(), 0, 0, 0, 0);

    let ret = unsafe {
        nist_codecs_jpegl_decode(
            input.as_mut_ptr(),
            len,
            &mut out,
            &mut w,
            &mut h,
            &mut channels,
            &mut ppi,
        )
    };

    let pixels = take_c_buffer(ret, out, w, h, channels).ok_or(crate::atoms::invalid_jpegl())?;

    Ok(Pixels {
        width: w as u32,
        height: h as u32,
        channels: channels as u32,
        ppi: positive(ppi),
        colorspace: if channels == 1 {
            crate::atoms::gray()
        } else {
            crate::atoms::unspecified()
        },
        data: pixels,
    })
}

/// Copies a malloc'd C pixel buffer into a Vec and frees it. Returns None
/// if the call failed.
fn take_c_buffer(ret: c_int, out: *mut c_uchar, w: c_int, h: c_int, channels: c_int) -> Option<Vec<u8>> {
    if out.is_null() {
        return None;
    }

    let result = if ret == 0 && w > 0 && h > 0 && channels > 0 {
        let size = (w as usize) * (h as usize) * (channels as usize);
        Some(unsafe { std::slice::from_raw_parts(out, size) }.to_vec())
    } else {
        None
    };

    unsafe { free(out as *mut c_void) };
    result
}

/// NBIS reports -1 when the file does not say.
fn positive(ppi: c_int) -> Option<u32> {
    (ppi > 0).then_some(ppi as u32)
}

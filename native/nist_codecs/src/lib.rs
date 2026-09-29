//! Image codecs for NistView, exposed as `NistView.Codecs`.
//!
//! Every function runs on a dirty CPU scheduler. Inputs come from untrusted
//! files, so headers are checked here before any C code allocates from them.

use rustler::{Binary, Env, NifMap, NifResult, OwnedBinary};
use std::os::raw::{c_int, c_uchar, c_void};
use std::sync::Mutex;

mod atoms {
    rustler::atoms! {
        invalid_wsq,
        too_large,
        invalid_dimensions,
        png_encode_failed,
        alloc_failed,
    }
}

/// Largest image any decoder will allocate for: 100 megapixels, above a
/// full palm at 1000 ppi.
const MAX_PIXELS: u64 = 100_000_000;

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
/// decode may run at a time.
static WSQ_LOCK: Mutex<()> = Mutex::new(());

#[derive(NifMap)]
struct Decoded<'a> {
    width: u32,
    height: u32,
    channels: u32,
    bit_depth: u32,
    ppi: i32,
    pixels: Binary<'a>,
}

type Error = rustler::Atom;

#[rustler::nif(schedule = "DirtyCpu")]
fn decode_wsq<'a>(env: Env<'a>, data: Binary) -> NifResult<Result<Decoded<'a>, Error>> {
    Ok(decode_wsq_bytes(env, data.as_slice()))
}

fn decode_wsq_bytes<'a>(env: Env<'a>, data: &[u8]) -> Result<Decoded<'a>, Error> {
    let (width, height) = wsq_dimensions(data).ok_or(atoms::invalid_wsq())?;
    check_dimensions(width, height)?;
    let len = c_int::try_from(data.len()).map_err(|_| atoms::too_large())?;

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

    if ret != 0 || out.is_null() {
        if !out.is_null() {
            unsafe { free(out as *mut c_void) };
        }
        return Err(atoms::invalid_wsq());
    }

    // NBIS always returns 8-bit greyscale.
    let size = (w as usize) * (h as usize);
    let pixels = OwnedBinary::new(size).map(|mut bin| {
        bin.as_mut_slice()
            .copy_from_slice(unsafe { std::slice::from_raw_parts(out, size) });
        bin
    });
    unsafe { free(out as *mut c_void) };

    Ok(Decoded {
        width: w as u32,
        height: h as u32,
        channels: 1,
        bit_depth: d as u32,
        ppi,
        pixels: pixels.ok_or(atoms::alloc_failed())?.release(env),
    })
}

/// Reads width and height from the WSQ frame header (SOF, 0xFFA2) by
/// walking the marker segments that precede it.
fn wsq_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    let u16_at = |pos: usize| -> Option<usize> {
        data.get(pos..pos + 2)
            .map(|b| u16::from_be_bytes([b[0], b[1]]) as usize)
    };

    if u16_at(0)? != 0xFFA0 {
        return None;
    }

    let mut pos = 2;
    loop {
        let marker = u16_at(pos)?;
        let seg_len = u16_at(pos + 2)?;

        match marker {
            // Frame header: Lf, A, B, Y (height), X (width), ...
            0xFFA2 => return Some((u16_at(pos + 8)? as u32, u16_at(pos + 6)? as u32)),
            // Tables and comments may come before the frame header.
            0xFFA4..=0xFFA8 if seg_len >= 2 => pos += 2 + seg_len,
            _ => return None,
        }
    }
}

fn check_dimensions(width: u32, height: u32) -> Result<(), Error> {
    if width == 0 || height == 0 {
        Err(atoms::invalid_dimensions())
    } else if (width as u64) * (height as u64) > MAX_PIXELS {
        Err(atoms::too_large())
    } else {
        Ok(())
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn encode_png<'a>(
    env: Env<'a>,
    pixels: Binary,
    width: u32,
    height: u32,
    channels: u32,
) -> NifResult<Result<Binary<'a>, Error>> {
    Ok(encode_png_bytes(pixels.as_slice(), width, height, channels).and_then(|png| {
        let mut bin = OwnedBinary::new(png.len()).ok_or(atoms::alloc_failed())?;
        bin.as_mut_slice().copy_from_slice(&png);
        Ok(bin.release(env))
    }))
}

fn encode_png_bytes(pixels: &[u8], width: u32, height: u32, channels: u32) -> Result<Vec<u8>, Error> {
    check_dimensions(width, height)?;

    let color = match channels {
        1 => png::ColorType::Grayscale,
        3 => png::ColorType::Rgb,
        4 => png::ColorType::Rgba,
        _ => return Err(atoms::invalid_dimensions()),
    };

    if pixels.len() as u64 != (width as u64) * (height as u64) * (channels as u64) {
        return Err(atoms::invalid_dimensions());
    }

    let mut out = Vec::new();
    let mut encoder = png::Encoder::new(&mut out, width, height);
    encoder.set_color(color);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.set_compression(png::Compression::Fast);

    encoder
        .write_header()
        .and_then(|mut writer| writer.write_image_data(pixels))
        .map_err(|_| atoms::png_encode_failed())?;

    Ok(out)
}

rustler::init!("Elixir.NistView.Codecs");

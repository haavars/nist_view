//! The Elixir interface, `NistView.Codecs`: PNG encoding and colour
//! conversion, both safe Rust. The image decoders are deliberately not
//! exposed here; they run in the `nist_decode` helper process
//! (NistView.Decoder).
//! Every function runs on a dirty CPU scheduler; errors become atoms.

use crate::Error;
use rustler::{Atom, Binary, Env, NifResult, OwnedBinary};

mod atoms {
    rustler::atoms! {
        invalid_wsq,
        invalid_jpegl,
        invalid_jp2,
        not_lossless_jpeg,
        unsupported_colorspace,
        too_large,
        invalid_dimensions,
        png_encode_failed,
        alloc_failed,
    }
}

fn error_atom(error: Error) -> Atom {
    match error {
        Error::InvalidWsq => atoms::invalid_wsq(),
        Error::InvalidJpegl => atoms::invalid_jpegl(),
        Error::InvalidJp2 => atoms::invalid_jp2(),
        Error::NotLosslessJpeg => atoms::not_lossless_jpeg(),
        Error::UnsupportedColorspace => atoms::unsupported_colorspace(),
        Error::TooLarge => atoms::too_large(),
        Error::InvalidDimensions => atoms::invalid_dimensions(),
        Error::PngEncodeFailed => atoms::png_encode_failed(),
    }
}

fn to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Result<Binary<'a>, Atom> {
    let mut bin = OwnedBinary::new(bytes.len()).ok_or(atoms::alloc_failed())?;
    bin.as_mut_slice().copy_from_slice(bytes);
    Ok(bin.release(env))
}

fn to_bytes<'a>(env: Env<'a>, result: Result<Vec<u8>, Error>) -> Result<Binary<'a>, Atom> {
    to_binary(env, &result.map_err(error_atom)?)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn ycbcr_to_rgb<'a>(env: Env<'a>, pixels: Binary) -> NifResult<Result<Binary<'a>, Atom>> {
    Ok(to_bytes(env, crate::ycbcr_to_rgb(pixels.as_slice())))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn encode_png<'a>(
    env: Env<'a>,
    pixels: Binary,
    width: u32,
    height: u32,
    channels: u32,
) -> NifResult<Result<Binary<'a>, Atom>> {
    Ok(to_bytes(env, crate::encode_png(pixels.as_slice(), width, height, channels)))
}

rustler::init!("Elixir.NistView.Codecs");

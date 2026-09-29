//! Image codecs for NistView, exposed as `NistView.Codecs`.
//!
//! Every function runs on a dirty CPU scheduler. Inputs come from untrusted
//! files, so image headers are read here and oversized images refused
//! before any decoder allocates for them.

mod headers;
mod jp2;
mod nbis;

use rustler::{Atom, Binary, Env, NifMap, NifResult, OwnedBinary};

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
        gray,
        srgb,
        sycc,
        unspecified,
    }
}

type Error = Atom;

/// Largest image any decoder will allocate for: 100 megapixels, above a
/// full palm at 1000 ppi.
const MAX_PIXELS: u64 = 100_000_000;

/// A decoded image: 8-bit samples, row-major, `channels` interleaved.
pub(crate) struct Pixels {
    width: u32,
    height: u32,
    channels: u32,
    ppi: Option<u32>,
    /// What the decoder knows of the colour space: gray, srgb, sycc or
    /// unspecified. YCbCr data is not converted here.
    colorspace: Atom,
    data: Vec<u8>,
}

#[derive(NifMap)]
struct Decoded<'a> {
    width: u32,
    height: u32,
    channels: u32,
    bit_depth: u32,
    ppi: Option<u32>,
    colorspace: Atom,
    pixels: Binary<'a>,
}

pub(crate) fn check_dimensions(width: u32, height: u32) -> Result<(), Error> {
    if width == 0 || height == 0 {
        Err(atoms::invalid_dimensions())
    } else if (width as u64) * (height as u64) > MAX_PIXELS {
        Err(atoms::too_large())
    } else {
        Ok(())
    }
}

fn to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Result<Binary<'a>, Error> {
    let mut bin = OwnedBinary::new(bytes.len()).ok_or(atoms::alloc_failed())?;
    bin.as_mut_slice().copy_from_slice(bytes);
    Ok(bin.release(env))
}

fn to_decoded<'a>(env: Env<'a>, result: Result<Pixels, Error>) -> Result<Decoded<'a>, Error> {
    let pixels = result?;

    Ok(Decoded {
        width: pixels.width,
        height: pixels.height,
        channels: pixels.channels,
        bit_depth: 8,
        ppi: pixels.ppi,
        colorspace: pixels.colorspace,
        pixels: to_binary(env, &pixels.data)?,
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn decode_wsq<'a>(env: Env<'a>, data: Binary) -> NifResult<Result<Decoded<'a>, Error>> {
    Ok(to_decoded(env, nbis::decode_wsq(data.as_slice())))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn decode_jpegl<'a>(env: Env<'a>, data: Binary) -> NifResult<Result<Decoded<'a>, Error>> {
    Ok(to_decoded(env, nbis::decode_jpegl(data.as_slice())))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn decode_jp2<'a>(env: Env<'a>, data: Binary) -> NifResult<Result<Decoded<'a>, Error>> {
    Ok(to_decoded(env, jp2::decode(data.as_slice())))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn ycbcr_to_rgb<'a>(env: Env<'a>, pixels: Binary) -> NifResult<Result<Binary<'a>, Error>> {
    let pixels = pixels.as_slice();

    if pixels.len() % 3 != 0 {
        return Ok(Err(atoms::invalid_dimensions()));
    }

    Ok(to_binary(env, &ycbcr_to_rgb_bytes(pixels)))
}

/// Full-range YCbCr (JFIF, sYCC) to RGB.
fn ycbcr_to_rgb_bytes(pixels: &[u8]) -> Vec<u8> {
    let clamp = |v: f32| v.round().clamp(0.0, 255.0) as u8;

    pixels
        .chunks_exact(3)
        .flat_map(|p| {
            let (y, cb, cr) = (p[0] as f32, p[1] as f32 - 128.0, p[2] as f32 - 128.0);
            [
                clamp(y + 1.402 * cr),
                clamp(y - 0.344_136 * cb - 0.714_136 * cr),
                clamp(y + 1.772 * cb),
            ]
        })
        .collect()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn encode_png<'a>(
    env: Env<'a>,
    pixels: Binary,
    width: u32,
    height: u32,
    channels: u32,
) -> NifResult<Result<Binary<'a>, Error>> {
    Ok(encode_png_bytes(pixels.as_slice(), width, height, channels).and_then(|png| to_binary(env, &png)))
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ycbcr_grey_stays_grey() {
        assert_eq!(ycbcr_to_rgb_bytes(&[100, 128, 128]), vec![100, 100, 100]);
    }

    #[test]
    fn ycbcr_red() {
        // Pure red in full-range YCbCr.
        assert_eq!(ycbcr_to_rgb_bytes(&[76, 85, 255]), vec![254, 0, 0]);
    }
}

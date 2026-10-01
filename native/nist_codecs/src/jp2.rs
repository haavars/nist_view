//! JPEG 2000 (JP2 files and raw codestreams) in safe Rust, with the
//! `hayro-jpeg2000` crate: a patched copy, `native/hayro-jpeg2000`, built
//! without SIMD so that nothing in it is `unsafe` (docs/jp2.md).
//!
//! The crate decodes; the conversion of its components to 8 bits is ours.
//! Its own packing scales samples of more than 8 bits differently from what
//! the application has always shown.

use crate::{check_dimensions, headers, ColorSpace, Error, Pixels, MAX_DECODE_BYTES};
use hayro_jpeg2000::{ColorSpace as J2kColorSpace, ComponentData, DecodeSettings, DecoderContext, Image};

/// A JP2 file starts with a signature box; anything else is a codestream
/// on its own, which does not say what its components mean.
const JP2_SIGNATURE: &[u8] = b"\x00\x00\x00\x0C\x6A\x50\x20\x20";

pub fn decode(data: &[u8]) -> Result<Pixels, Error> {
    let (width, height) = headers::jp2(data).ok_or(Error::InvalidJp2)?;
    check_dimensions(width, height)?;

    let image = Image::new(data, &DecodeSettings::default()).map_err(|_| Error::InvalidJp2)?;
    let (width, height) = (image.width(), image.height());
    check_dimensions(width, height)?;

    // The colour components come first; an alpha component is left out.
    // sYCC arrives converted to RGB.
    let components = image.color_space().num_channels() as usize;
    let (channels, colorspace) = match (components, image.color_space()) {
        (_, J2kColorSpace::CMYK) => return Err(Error::UnsupportedColorspace),
        (1 | 2, _) => (1, ColorSpace::Gray),
        (3.., J2kColorSpace::RGB) if data.starts_with(JP2_SIGNATURE) => (3, ColorSpace::Srgb),
        (3.., _) => (3, ColorSpace::Unspecified),
        _ => return Err(Error::InvalidJp2),
    };

    let pixels = width as usize * height as usize;
    if decode_bytes(pixels, components + image.has_alpha() as usize, channels) > MAX_DECODE_BYTES {
        return Err(Error::TooLarge);
    }

    let mut context = DecoderContext::default();
    let decoded = image.decode(&mut context).map_err(|_| Error::InvalidJp2)?;
    let mut out = vec![0u8; pixels * channels];

    for (c, component) in decoded.components().iter().take(channels).enumerate() {
        // Subsampled components arrive at the full size.
        let samples = component.samples();
        if samples.len() != pixels {
            return Err(Error::InvalidJp2);
        }

        let to_u8 = scaler(component);
        for (pixel, &sample) in out.chunks_exact_mut(channels).zip(samples) {
            pixel[c] = to_u8(sample);
        }
    }
    if decoded.components().len() < channels {
        return Err(Error::InvalidJp2);
    }

    Ok(Pixels {
        width,
        height,
        channels: channels as u32,
        ppi: None,
        colorspace,
        data: out,
    })
}

/// What decoding allocates, by estimate: the crate holds every component's
/// coefficients and its samples as `f32`, one component of scratch for the
/// wavelet transform and a byte per pixel of coding state; then our pixels.
fn decode_bytes(pixels: usize, components: usize, channels: usize) -> u64 {
    pixels as u64 * (8 * components as u64 + 5 + channels as u64)
}

/// Maps a component's samples to 0..=255: rounded, clamped to the
/// component's precision, and the precision scaled to 8 bits.
fn scaler(component: &ComponentData) -> impl Fn(f32) -> u8 {
    let max: i64 = (1 << component.bit_depth().clamp(1, 31)) - 1;

    move |sample| {
        // A NaN becomes 0.
        let v = (sample.round() as i64).clamp(0, max);
        (v * 255 / max) as u8
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const GREY: &[u8] = include_bytes!("../../../test/fixtures/synthetic_grey.jp2");
    const GREY16: &[u8] = include_bytes!("../../../test/fixtures/synthetic_grey16.jp2");
    const RGB: &[u8] = include_bytes!("../../../test/fixtures/synthetic_rgb.j2k");

    fn pattern(f: impl Fn(usize, usize) -> Vec<u8>) -> Vec<u8> {
        (0..96).flat_map(|y| (0..128).map(move |x| (x, y))).flat_map(|(x, y)| f(x, y)).collect()
    }

    #[test]
    fn lossless_greyscale() {
        let image = decode(GREY).unwrap();
        assert_eq!((image.width, image.height, image.channels, image.colorspace), (128, 96, 1, ColorSpace::Gray));
        let expected = pattern(|x, y| vec![(128.0 + 90.0 * (x as f64 / 2.5).sin() * (y as f64 / 3.5).cos()) as u8]);
        assert_eq!(image.data, expected);
    }

    #[test]
    fn sixteen_bits_are_scaled_to_eight() {
        let image = decode(GREY16).unwrap();
        assert_eq!((image.channels, image.colorspace), (1, ColorSpace::Gray));
        let expected = pattern(|x, y| vec![(((512 * x + 7 * y) % 65536) * 255 / 65535) as u8]);
        assert_eq!(image.data, expected);
    }

    #[test]
    fn a_codestream_on_its_own_has_no_colour_space() {
        let image = decode(RGB).unwrap();
        assert_eq!((image.channels, image.colorspace), (3, ColorSpace::Unspecified));
        assert_eq!(image.data, pattern(|x, y| vec![(x * 2 % 256) as u8, (y * 2 % 256) as u8, ((x + y) % 256) as u8]));
    }

    #[test]
    fn truncations_and_garbage_are_errors_or_images_never_panics() {
        for length in 0..GREY.len() {
            let _ = decode(&GREY[..length]);
        }
        assert_eq!(decode(b"").err(), Some(Error::InvalidJp2));
        assert_eq!(decode(b"not a JPEG 2000 image").err(), Some(Error::InvalidJp2));
    }

    #[test]
    fn memory_is_estimated_from_pixels_and_components() {
        // The largest sample, 3300 x 4400 RGB, was measured at 428 MB.
        assert_eq!(decode_bytes(3300 * 4400, 3, 3) / 1_000_000, 464);
        // 100 megapixels: greyscale fits, RGB does not.
        assert!(decode_bytes(100_000_000, 1, 1) <= MAX_DECODE_BYTES);
        assert!(decode_bytes(100_000_000, 3, 3) > MAX_DECODE_BYTES);
    }
}

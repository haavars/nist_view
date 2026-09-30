//! Image codecs for NistView.
//!
//! The decoders are plain Rust over untrusted bytes: each reads the image
//! header first and refuses oversized images before any decoder allocates.
//! With the default `nif` feature, `nif.rs` exposes them to Elixir as
//! `NistView.Codecs`; without it (the fuzz targets) there is no rustler.

pub mod headers;
pub mod jp2;
pub mod jpegl;
pub mod wsq;

#[cfg(feature = "nif")]
mod nif;

/// Largest image any decoder will allocate for: 100 megapixels, above a
/// full palm at 1000 ppi.
#[cfg(not(fuzzing))]
pub const MAX_PIXELS: u64 = 100_000_000;

/// Under cargo-fuzz: decoding takes time in proportion to the size an image
/// declares, however short the file, and a fuzzer should not spend its time
/// there. 4 megapixels holds every seed image.
#[cfg(fuzzing)]
pub const MAX_PIXELS: u64 = 4_000_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    InvalidWsq,
    InvalidJpegl,
    InvalidJp2,
    NotLosslessJpeg,
    UnsupportedColorspace,
    TooLarge,
    InvalidDimensions,
    PngEncodeFailed,
}

/// What a decoder knows of an image's colour space. YCbCr data is not
/// converted by the decoders.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ColorSpace {
    Gray,
    Srgb,
    Sycc,
    Unspecified,
}

/// A decoded image: 8-bit samples, row-major, `channels` interleaved.
#[derive(Debug)]
pub struct Pixels {
    pub width: u32,
    pub height: u32,
    pub channels: u32,
    pub ppi: Option<u32>,
    pub colorspace: ColorSpace,
    pub data: Vec<u8>,
}

pub fn check_dimensions(width: u32, height: u32) -> Result<(), Error> {
    if width == 0 || height == 0 {
        Err(Error::InvalidDimensions)
    } else if (width as u64) * (height as u64) > MAX_PIXELS {
        Err(Error::TooLarge)
    } else {
        Ok(())
    }
}

/// Full-range YCbCr (JFIF, sYCC) to RGB.
pub fn ycbcr_to_rgb(pixels: &[u8]) -> Result<Vec<u8>, Error> {
    if pixels.len() % 3 != 0 {
        return Err(Error::InvalidDimensions);
    }

    let clamp = |v: f32| v.round().clamp(0.0, 255.0) as u8;

    Ok(pixels
        .chunks_exact(3)
        .flat_map(|p| {
            let (y, cb, cr) = (p[0] as f32, p[1] as f32 - 128.0, p[2] as f32 - 128.0);
            [
                clamp(y + 1.402 * cr),
                clamp(y - 0.344_136 * cb - 0.714_136 * cr),
                clamp(y + 1.772 * cb),
            ]
        })
        .collect())
}

/// Encodes 8-bit pixels with 1, 3 or 4 channels as PNG.
pub fn encode_png(pixels: &[u8], width: u32, height: u32, channels: u32) -> Result<Vec<u8>, Error> {
    check_dimensions(width, height)?;

    let color = match channels {
        1 => png::ColorType::Grayscale,
        3 => png::ColorType::Rgb,
        4 => png::ColorType::Rgba,
        _ => return Err(Error::InvalidDimensions),
    };

    if pixels.len() as u64 != (width as u64) * (height as u64) * (channels as u64) {
        return Err(Error::InvalidDimensions);
    }

    let mut out = Vec::new();
    let mut encoder = png::Encoder::new(&mut out, width, height);
    encoder.set_color(color);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.set_compression(png::Compression::Fast);

    encoder
        .write_header()
        .and_then(|mut writer| writer.write_image_data(pixels))
        .map_err(|_| Error::PngEncodeFailed)?;

    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ycbcr_grey_stays_grey() {
        assert_eq!(ycbcr_to_rgb(&[100, 128, 128]), Ok(vec![100, 100, 100]));
    }

    #[test]
    fn ycbcr_red() {
        // Pure red in full-range YCbCr.
        assert_eq!(ycbcr_to_rgb(&[76, 85, 255]), Ok(vec![254, 0, 0]));
    }

    #[test]
    fn ycbcr_needs_whole_pixels() {
        assert_eq!(ycbcr_to_rgb(&[1, 2]), Err(Error::InvalidDimensions));
    }

    #[test]
    fn png_rejects_mismatched_sizes() {
        assert_eq!(encode_png(&[1, 2, 3], 2, 2, 1), Err(Error::InvalidDimensions));
        assert_eq!(encode_png(&[1], 1, 1, 2), Err(Error::InvalidDimensions));
        assert!(encode_png(&[1, 2, 3, 4], 2, 2, 1).is_ok());
    }
}

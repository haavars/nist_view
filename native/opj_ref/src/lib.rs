//! JPEG 2000 through OpenJPEG (C, by way of the `jpeg2k` crate), with the
//! conversion to 8 bits that the application used while OpenJPEG was its
//! decoder.
//!
//! This is the reference the Rust decoder (`nist_codecs::jp2`) is compared
//! against in tests (docs/jp2-port.md). It is C on untrusted input: never
//! ship it.

use jpeg2k::{ColorSpace as J2kColorSpace, ImageComponent};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ColorSpace {
    Gray,
    Srgb,
    /// Not converted to RGB.
    Sycc,
    Unspecified,
}

/// An image as OpenJPEG decodes it: 8-bit samples, row-major, `channels`
/// interleaved.
#[derive(Debug)]
pub struct Image {
    pub width: u32,
    pub height: u32,
    pub channels: u32,
    pub colorspace: ColorSpace,
    pub pixels: Vec<u8>,
}

/// `None` when OpenJPEG fails, or for the colour spaces the application
/// refuses (CMYK, e-sYCC).
pub fn decode(data: &[u8]) -> Option<Image> {
    let image = jpeg2k::Image::from_bytes(data).ok()?;
    let (width, height) = (image.width(), image.height());

    let colour: Vec<&ImageComponent> = image.components().iter().filter(|c| !c.is_alpha()).collect();

    let (channels, colorspace) = match (colour.len(), image.color_space()) {
        (_, J2kColorSpace::CMYK | J2kColorSpace::EYCC) => return None,
        (1 | 2, _) => (1, ColorSpace::Gray),
        (n, cs) if n >= 3 => (
            3,
            match cs {
                J2kColorSpace::SRGB => ColorSpace::Srgb,
                J2kColorSpace::SYCC => ColorSpace::Sycc,
                _ => ColorSpace::Unspecified,
            },
        ),
        _ => return None,
    };

    let (w, h) = (width as usize, height as usize);
    let mut pixels = vec![0u8; w * h * channels];

    for (c, component) in colour.iter().take(channels).enumerate() {
        let (cw, ch) = (component.width() as usize, component.height() as usize);
        if cw == 0 || ch == 0 || cw > w || ch > h {
            return None;
        }

        let values = component.data();
        let to_u8 = scaler(component);

        for y in 0..h {
            // Subsampled components are upsampled by pixel replication.
            let row = (y * ch / h) * cw;
            for x in 0..w {
                pixels[(y * w + x) * channels + c] = to_u8(values[row + x * cw / w]);
            }
        }
    }

    Some(Image { width, height, channels: channels as u32, colorspace, pixels })
}

/// Maps a component's sample values to 0..=255: signed samples are
/// shifted to unsigned, then the precision is scaled to 8 bits.
fn scaler(component: &ImageComponent) -> impl Fn(i32) -> u8 {
    let precision = component.precision().clamp(1, 31);
    let offset: i64 = if component.is_signed() { 1 << (precision - 1) } else { 0 };
    let max: i64 = (1 << precision) - 1;

    move |value| {
        let v = (value as i64 + offset).clamp(0, max);
        (v * 255 / max) as u8
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const GREY: &[u8] = include_bytes!("../../../test/fixtures/synthetic_grey.jp2");

    #[test]
    fn decodes_the_synthetic_fixture() {
        let image = decode(GREY).expect("decodes");
        assert_eq!((image.width, image.height, image.channels, image.colorspace), (128, 96, 1, ColorSpace::Gray));
        assert_eq!(image.pixels.len(), 128 * 96);
    }

    #[test]
    fn rejects_data_that_is_not_jpeg_2000() {
        assert!(decode(b"").is_none());
        assert!(decode(b"not a JPEG 2000 image").is_none());
    }
}

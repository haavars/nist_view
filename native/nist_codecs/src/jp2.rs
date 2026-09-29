//! JPEG 2000 (JP2 files and raw codestreams) through OpenJPEG.
//!
//! Components are converted to 8-bit here rather than with the jpeg2k
//! crate's `get_pixels`, which rejects YCC colour spaces, assumes every
//! component has the full image size and does not clamp.

use crate::{check_dimensions, headers, ColorSpace, Error, Pixels};
use jpeg2k::{ColorSpace as J2kColorSpace, Image, ImageComponent};

pub fn decode(data: &[u8]) -> Result<Pixels, Error> {
    let (width, height) = headers::jp2(data).ok_or(Error::InvalidJp2)?;
    check_dimensions(width, height)?;

    let image = Image::from_bytes(data).map_err(|_| Error::InvalidJp2)?;
    let (width, height) = (image.width(), image.height());
    check_dimensions(width, height)?;

    let colour: Vec<&ImageComponent> = image.components().iter().filter(|c| !c.is_alpha()).collect();

    let (channels, colorspace) = match (colour.len(), image.color_space()) {
        (_, J2kColorSpace::CMYK | J2kColorSpace::EYCC) => return Err(Error::UnsupportedColorspace),
        (1 | 2, _) => (1, ColorSpace::Gray),
        (n, cs) if n >= 3 => (
            3,
            match cs {
                J2kColorSpace::SRGB => ColorSpace::Srgb,
                J2kColorSpace::SYCC => ColorSpace::Sycc,
                _ => ColorSpace::Unspecified,
            },
        ),
        _ => return Err(Error::InvalidJp2),
    };

    let (w, h) = (width as usize, height as usize);
    let mut out = vec![0u8; w * h * channels];

    for (c, component) in colour.iter().take(channels).enumerate() {
        let (cw, ch) = (component.width() as usize, component.height() as usize);
        if cw == 0 || ch == 0 || cw > w || ch > h {
            return Err(Error::InvalidJp2);
        }

        let values = component.data();
        let to_u8 = scaler(component);

        for y in 0..h {
            // Subsampled components are upsampled by pixel replication.
            let row = (y * ch / h) * cw;
            for x in 0..w {
                out[(y * w + x) * channels + c] = to_u8(values[row + x * cw / w]);
            }
        }
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

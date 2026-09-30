//! WSQ through the NBIS decoder in `nbis_ref`. (Lossless JPEG is
//! `crate::jpegl`.)
//!
//! Temporary: `wsq.rs` replaces this module, and the dependency on
//! `nbis_ref`, in step 4 of docs/wsq-port.md.

use crate::{check_dimensions, headers, ColorSpace, Error, Pixels};

pub fn decode_wsq(data: &[u8]) -> Result<Pixels, Error> {
    let (width, height) = headers::wsq(data).ok_or(Error::InvalidWsq)?;
    check_dimensions(width, height)?;

    let image = nbis_ref::decode_wsq(data).ok_or(Error::InvalidWsq)?;

    Ok(Pixels {
        width: image.width,
        height: image.height,
        channels: 1,
        ppi: image.ppi,
        colorspace: ColorSpace::Gray,
        data: image.pixels,
    })
}

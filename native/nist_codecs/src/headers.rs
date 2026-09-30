//! Reads image dimensions from headers, so oversized images are refused
//! before any decoder allocates for them. (The WSQ decoder reads its own
//! frame header, the way NBIS does.)

fn u16_at(data: &[u8], pos: usize) -> Option<u32> {
    data.get(pos..pos + 2)
        .map(|b| u16::from_be_bytes([b[0], b[1]]) as u32)
}

fn u32_at(data: &[u8], pos: usize) -> Option<u32> {
    data.get(pos..pos + 4)
        .map(|b| u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
}

/// JPEG (any SOFn): walks the marker segments after SOI (0xFFD8) to the
/// first frame header: Lf, P, Y (height), X (width), ...
/// Returns the SOF marker too, which tells baseline from lossless.
pub fn jpeg(data: &[u8]) -> Option<(u8, u32, u32)> {
    if u16_at(data, 0)? != 0xFFD8 {
        return None;
    }

    let mut pos = 2;
    loop {
        // Markers may be preceded by fill bytes (0xFF).
        while data.get(pos) == Some(&0xFF) && data.get(pos + 1) == Some(&0xFF) {
            pos += 1;
        }

        let marker = u16_at(data, pos)?;
        if marker >> 8 != 0xFF {
            return None;
        }

        let code = (marker & 0xFF) as u8;
        let len = u16_at(data, pos + 2)? as usize;

        match code {
            // SOF0–SOF15, except DHT (C4), JPG (C8) and DAC (CC).
            0xC0..=0xCF if !matches!(code, 0xC4 | 0xC8 | 0xCC) => {
                return Some((code, u16_at(data, pos + 7)?, u16_at(data, pos + 5)?));
            }
            // Start of scan before any frame header: malformed.
            0xDA | 0xD9 => return None,
            _ if len >= 2 => pos += 2 + len,
            _ => return None,
        }
    }
}

/// JPEG 2000: a raw codestream (SOC 0xFF4F, then SIZ) or a JP2 file,
/// whose image header box (`ihdr`) holds height and width.
pub fn jp2(data: &[u8]) -> Option<(u32, u32)> {
    if u16_at(data, 0)? == 0xFF4F {
        return codestream(data);
    }

    // JP2 signature box, then boxes: length (4), type (4), content.
    if data.get(4..8)? != b"jP  " {
        return None;
    }

    find_ihdr(data)
}

/// SIZ: Lsiz, Rsiz, Xsiz, Ysiz, XOsiz, YOsiz, ...
fn codestream(data: &[u8]) -> Option<(u32, u32)> {
    if u16_at(data, 2)? != 0xFF51 {
        return None;
    }

    let (xsiz, ysiz) = (u32_at(data, 8)?, u32_at(data, 12)?);
    let (xo, yo) = (u32_at(data, 16)?, u32_at(data, 20)?);
    Some((xsiz.checked_sub(xo)?, ysiz.checked_sub(yo)?))
}

fn find_ihdr(data: &[u8]) -> Option<(u32, u32)> {
    let mut pos = 0;

    while pos + 8 <= data.len() {
        let len = u32_at(data, pos)? as usize;
        let kind = data.get(pos + 4..pos + 8)?;

        match kind {
            // The JP2 header superbox contains ihdr first.
            b"jp2h" => pos += 8,
            b"ihdr" => return Some((u32_at(data, pos + 12)?, u32_at(data, pos + 8)?)),
            // A contiguous codestream box before any header: read SIZ.
            b"jp2c" => return codestream(data.get(pos + 8..)?),
            _ if len >= 8 => pos += len,
            _ => return None,
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jpeg_reads_sof_after_other_segments() {
        let data = [
            0xFF, 0xD8, // SOI
            0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, // APP0, 2 bytes of content
            0xFF, 0xC3, 0x00, 0x0B, 0x08, 0x00, 0x30, 0x00, 0x40, 0x01, // SOF3: 48 × 64
        ];
        assert_eq!(jpeg(&data), Some((0xC3, 64, 48)));
    }

    #[test]
    fn jpeg_rejects_scan_before_frame() {
        assert_eq!(jpeg(&[0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02]), None);
    }

    #[test]
    fn codestream_subtracts_offsets() {
        let mut data = vec![0xFF, 0x4F, 0xFF, 0x51, 0x00, 0x29, 0x00, 0x00];
        data.extend_from_slice(&110u32.to_be_bytes()); // Xsiz
        data.extend_from_slice(&90u32.to_be_bytes()); // Ysiz
        data.extend_from_slice(&10u32.to_be_bytes()); // XOsiz
        data.extend_from_slice(&0u32.to_be_bytes()); // YOsiz
        assert_eq!(jp2(&data), Some((100, 90)));
    }

    #[test]
    fn truncated_headers_are_none() {
        assert_eq!(jpeg(&[0xFF, 0xD8, 0xFF, 0xC0, 0x00]), None);
        assert_eq!(jp2(&[0xFF, 0x4F, 0xFF, 0x51]), None);
        assert_eq!(jp2(b"\0\0\0\x0cjP  \r\n\x87\n\0\0"), None);
    }
}

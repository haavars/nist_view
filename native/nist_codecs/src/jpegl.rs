//! Lossless JPEG (ITU-T T.81 Annex H, Huffman coding, SOF3) in safe Rust.
//!
//! Replaces the NBIS `jpegl` decoder, in which fuzzing found out-of-bounds
//! reads and writes. Supported: 2–16 bit precision, predictors 0–7, point
//! transform, restart intervals, interleaved and one-scan-per-component
//! files, and subsampled components (upsampled by replication).
//!
//! NBIS writes its lossless Huffman tables with table class 1 (AC) although
//! scans select them as DC tables; a table's class is therefore ignored and
//! only its destination (0–3) counts.

use crate::{check_dimensions, ColorSpace, Error, Pixels};

const MAX_COMPONENTS: usize = 4;

struct Component {
    id: u8,
    h: usize,
    v: usize,
    /// Samples per line and lines, rounded up to whole MCUs.
    width: usize,
    height: usize,
    samples: Vec<u16>,
}

struct Frame {
    precision: u32,
    width: usize,
    height: usize,
    h_max: usize,
    v_max: usize,
    components: Vec<Component>,
}

/// A canonical Huffman table, decoded bit by bit (T.81 F.2.2.3).
#[derive(Clone)]
struct Huffman {
    maxcode: [i32; 17],
    mincode: [i32; 17],
    valptr: [usize; 17],
    values: Vec<u8>,
}

impl Huffman {
    fn new(counts: &[u8; 16], values: &[u8]) -> Result<Self, Error> {
        let mut table = Huffman { maxcode: [-1; 17], mincode: [0; 17], valptr: [0; 17], values: values.to_vec() };
        let mut code: i32 = 0;
        let mut k = 0usize;

        for len in 1..=16 {
            let n = counts[len - 1] as usize;
            if n > 0 {
                table.valptr[len] = k;
                table.mincode[len] = code;
                code += n as i32;
                k += n;
                table.maxcode[len] = code - 1;
                // More codes of this length than the length allows.
                if code > (1 << len) {
                    return Err(Error::InvalidJpegl);
                }
            }
            code <<= 1;
        }

        Ok(table)
    }

    fn decode(&self, bits: &mut BitReader) -> Result<u8, Error> {
        let mut code: i32 = 0;

        for len in 1..=16 {
            code = (code << 1) | bits.bit()? as i32;
            if code <= self.maxcode[len] {
                let index = self.valptr[len] + (code - self.mincode[len]) as usize;
                return self.values.get(index).copied().ok_or(Error::InvalidJpegl);
            }
        }

        Err(Error::InvalidJpegl)
    }
}

/// Reads entropy-coded bits, removing stuffed zero bytes and stopping at
/// markers.
struct BitReader<'a> {
    data: &'a [u8],
    pos: usize,
    byte: u8,
    left: u8,
}

impl<'a> BitReader<'a> {
    fn new(data: &'a [u8], pos: usize) -> Self {
        BitReader { data, pos, byte: 0, left: 0 }
    }

    fn bit(&mut self) -> Result<u8, Error> {
        if self.left == 0 {
            let byte = *self.data.get(self.pos).ok_or(Error::InvalidJpegl)?;
            if byte == 0xFF {
                match self.data.get(self.pos + 1) {
                    Some(0x00) => self.pos += 2,
                    // A marker inside the data: truncated or corrupt.
                    _ => return Err(Error::InvalidJpegl),
                }
            } else {
                self.pos += 1;
            }
            self.byte = byte;
            self.left = 8;
        }

        self.left -= 1;
        Ok((self.byte >> self.left) & 1)
    }

    fn bits(&mut self, n: u8) -> Result<u32, Error> {
        let mut value = 0u32;
        for _ in 0..n {
            value = (value << 1) | self.bit()? as u32;
        }
        Ok(value)
    }

    /// Skips to the restart marker `RST<n mod 8>` at a byte boundary.
    fn restart(&mut self, n: usize) -> Result<(), Error> {
        self.left = 0;
        while self.data.get(self.pos) == Some(&0xFF) && self.data.get(self.pos + 1) == Some(&0xFF) {
            self.pos += 1;
        }
        match self.data.get(self.pos..self.pos + 2) {
            Some([0xFF, m]) if *m == 0xD0 + (n % 8) as u8 => {
                self.pos += 2;
                Ok(())
            }
            _ => Err(Error::InvalidJpegl),
        }
    }

    /// The position of the next marker after the entropy-coded data.
    fn end(&self) -> usize {
        let mut pos = self.pos;
        while pos + 1 < self.data.len() {
            if self.data[pos] == 0xFF && self.data[pos + 1] != 0 && !(0xD0..=0xD7).contains(&self.data[pos + 1]) {
                return pos;
            }
            pos += 1;
        }
        self.data.len()
    }
}

pub fn decode(data: &[u8]) -> Result<Pixels, Error> {
    if data.get(0..2) != Some(&[0xFF, 0xD8][..]) {
        return Err(Error::InvalidJpegl);
    }

    let mut frame: Option<Frame> = None;
    let mut tables: [Option<Huffman>; 4] = [None, None, None, None];
    let mut table_is_dc = [false; 4];
    let mut restart_interval = 0usize;
    let mut ppi: Option<u32> = None;
    let mut scans = 0;
    let mut pos = 2;

    loop {
        // Tolerate a missing EOI after at least one scan.
        if pos >= data.len() && scans > 0 {
            break;
        }

        // Skip fill bytes before a marker.
        while data.get(pos) == Some(&0xFF) && data.get(pos + 1) == Some(&0xFF) {
            pos += 1;
        }

        let marker = match data.get(pos..pos + 2) {
            Some([0xFF, m]) => *m,
            _ => return Err(Error::InvalidJpegl),
        };

        if marker == 0xD9 {
            break;
        }

        // Markers without a length: RSTn outside a scan, TEM.
        if (0xD0..=0xD7).contains(&marker) || marker == 0x01 {
            pos += 2;
            continue;
        }

        let len = u16_at(data, pos + 2)? as usize;
        let segment = data.get(pos + 4..pos + 2 + len).filter(|_| len >= 2).ok_or(Error::InvalidJpegl)?;
        pos += 2 + len;

        match marker {
            0xC3 => {
                if frame.is_some() {
                    return Err(Error::InvalidJpegl);
                }
                frame = Some(parse_frame(segment)?);
            }
            // Other frame types: baseline, arithmetic, hierarchical, ...
            0xC0..=0xCF if !matches!(marker, 0xC4 | 0xC8 | 0xCC) => return Err(Error::NotLosslessJpeg),
            0xC4 => parse_tables(segment, &mut tables, &mut table_is_dc)?,
            0xDD => restart_interval = u16_at(segment, 0)? as usize,
            0xE0 => ppi = ppi.or(jfif_ppi(segment)),
            0xFE => ppi = ppi.or(nistcom_ppi(segment)),
            0xDA => {
                let frame = frame.as_mut().ok_or(Error::InvalidJpegl)?;
                pos = decode_scan(data, pos, segment, frame, &tables, restart_interval)?;
                scans += 1;
            }
            _ => {}
        }
    }

    let frame = frame.ok_or(Error::InvalidJpegl)?;
    assemble(frame, ppi)
}

fn u16_at(data: &[u8], pos: usize) -> Result<u16, Error> {
    data.get(pos..pos + 2)
        .map(|b| u16::from_be_bytes([b[0], b[1]]))
        .ok_or(Error::InvalidJpegl)
}

fn parse_frame(s: &[u8]) -> Result<Frame, Error> {
    let precision = *s.first().ok_or(Error::InvalidJpegl)? as u32;
    let height = u16_at(s, 1)? as usize;
    let width = u16_at(s, 3)? as usize;
    let count = *s.get(5).ok_or(Error::InvalidJpegl)? as usize;

    // Height 0 means a DNL marker gives it later, which is not supported.
    if !(2..=16).contains(&precision) || !(1..=MAX_COMPONENTS).contains(&count) || height == 0 {
        return Err(Error::InvalidJpegl);
    }
    check_dimensions(width as u32, height as u32)?;

    let mut components = Vec::with_capacity(count);
    for k in 0..count {
        let c = s.get(6 + 3 * k..9 + 3 * k).ok_or(Error::InvalidJpegl)?;
        let (h, v) = ((c[1] >> 4) as usize, (c[1] & 0x0F) as usize);
        if !(1..=4).contains(&h) || !(1..=4).contains(&v) {
            return Err(Error::InvalidJpegl);
        }
        components.push(Component { id: c[0], h, v, width: 0, height: 0, samples: Vec::new() });
    }

    let h_max = components.iter().map(|c| c.h).max().unwrap_or(1);
    let v_max = components.iter().map(|c| c.v).max().unwrap_or(1);
    let (mcus_x, mcus_y) = (width.div_ceil(h_max), height.div_ceil(v_max));

    for c in components.iter_mut() {
        c.width = mcus_x * c.h;
        c.height = mcus_y * c.v;
        c.samples = vec![0; c.width * c.height];
    }

    Ok(Frame { precision, width, height, h_max, v_max, components })
}

fn parse_tables(s: &[u8], tables: &mut [Option<Huffman>; 4], is_dc: &mut [bool; 4]) -> Result<(), Error> {
    let mut pos = 0;

    while pos < s.len() {
        let class_and_id = s[pos];
        let (class, id) = (class_and_id >> 4, (class_and_id & 0x0F) as usize);
        let counts: &[u8; 16] = s.get(pos + 1..pos + 17).and_then(|c| c.try_into().ok()).ok_or(Error::InvalidJpegl)?;
        let n: usize = counts.iter().map(|&c| c as usize).sum();
        let values = s.get(pos + 17..pos + 17 + n).ok_or(Error::InvalidJpegl)?;

        if id > 3 || class > 1 {
            return Err(Error::InvalidJpegl);
        }

        // Lossless scans use DC tables. NBIS writes AC-class ones: accept
        // them unless a DC table with the same destination exists.
        if class == 0 || !is_dc[id] {
            tables[id] = Some(Huffman::new(counts, values)?);
            is_dc[id] = class == 0;
        }

        pos += 17 + n;
    }

    Ok(())
}

/// JFIF APP0: units 1 = dots per inch, 2 = dots per centimetre.
fn jfif_ppi(s: &[u8]) -> Option<u32> {
    if s.get(0..5)? != b"JFIF\0" {
        return None;
    }
    let density = u16::from_be_bytes([*s.get(8)?, *s.get(9)?]) as u32;
    match (*s.get(7)?, density) {
        (_, 0) => None,
        (1, d) => Some(d),
        (2, d) => Some((d as f64 * 2.54).round() as u32),
        _ => None,
    }
}

/// NIST comment (`NIST_COM`) lines such as `PPI 500`, which NBIS writes.
fn nistcom_ppi(s: &[u8]) -> Option<u32> {
    let text = std::str::from_utf8(s).ok()?;
    if !text.starts_with("NIST_COM") {
        return None;
    }
    text.lines()
        .find_map(|line| line.strip_prefix("PPI "))
        .and_then(|v| v.trim().parse().ok())
        .filter(|&ppi| ppi > 0)
}

/// Decodes one scan into the frame's component planes and returns the
/// position after its entropy-coded data.
fn decode_scan(
    data: &[u8],
    pos: usize,
    header: &[u8],
    frame: &mut Frame,
    tables: &[Option<Huffman>; 4],
    restart_interval: usize,
) -> Result<usize, Error> {
    let count = *header.first().ok_or(Error::InvalidJpegl)? as usize;
    if !(1..=frame.components.len()).contains(&count) {
        return Err(Error::InvalidJpegl);
    }

    let mut scan: Vec<(usize, &Huffman)> = Vec::with_capacity(count);
    for k in 0..count {
        let id = *header.get(1 + 2 * k).ok_or(Error::InvalidJpegl)?;
        let table = (*header.get(2 + 2 * k).ok_or(Error::InvalidJpegl)? >> 4) as usize;
        let index = frame.components.iter().position(|c| c.id == id).ok_or(Error::InvalidJpegl)?;
        let huffman = tables.get(table).and_then(|t| t.as_ref()).ok_or(Error::InvalidJpegl)?;
        scan.push((index, huffman));
    }

    let predictor = *header.get(1 + 2 * count).ok_or(Error::InvalidJpegl)?;
    let point_transform = (*header.get(3 + 2 * count).ok_or(Error::InvalidJpegl)? & 0x0F) as u32;
    if predictor > 7 || point_transform >= frame.precision {
        return Err(Error::InvalidJpegl);
    }

    let bits = frame.precision - point_transform;
    let mask = (1u32 << bits) - 1;
    let initial = 1u32 << (bits - 1);
    let mut reader = BitReader::new(data, pos);

    // A single-component scan codes that component's samples one by one;
    // an interleaved scan codes H x V samples of each component per MCU.
    let (units_x, units_y) = if count == 1 {
        // T.81 A.1.1: a component's own size, rounded up.
        let c = &frame.components[scan[0].0];
        ((frame.width * c.h).div_ceil(frame.h_max), (frame.height * c.v).div_ceil(frame.v_max))
    } else {
        (frame.width.div_ceil(frame.h_max), frame.height.div_ceil(frame.v_max))
    };

    // The prediction rules restart at the start of a line, so a restart
    // interval must cover whole lines of MCUs.
    if restart_interval > 0 && restart_interval % units_x != 0 {
        return Err(Error::InvalidJpegl);
    }

    let mut restarts = 0usize;
    let mut first_line_of_interval = 0usize;
    let mut done = 0usize;

    for unit_y in 0..units_y {
        for unit_x in 0..units_x {
            if restart_interval > 0 && done > 0 && done % restart_interval == 0 {
                reader.restart(restarts)?;
                restarts += 1;
                first_line_of_interval = unit_y;
            }

            for &(index, huffman) in &scan {
                let c = &mut frame.components[index];
                let (h, v) = if count == 1 { (1, 1) } else { (c.h, c.v) };

                for dy in 0..v {
                    for dx in 0..h {
                        let x = unit_x * h + dx;
                        let y = unit_y * v + dy;
                        if x >= c.width || y >= c.height {
                            return Err(Error::InvalidJpegl);
                        }

                        let first_row = y == first_line_of_interval * v;
                        let prediction = predict(c, x, y, first_row, predictor, initial);
                        let diff = read_difference(&mut reader, huffman)?;
                        let value = (prediction as i32 + diff) as u32 & mask;
                        c.samples[y * c.width + x] = value as u16;
                    }
                }
            }

            done += 1;
        }
    }

    // Undo the point transform.
    if point_transform > 0 {
        for &(index, _) in &scan {
            for s in frame.components[index].samples.iter_mut() {
                *s <<= point_transform;
            }
        }
    }

    Ok(reader.end())
}

/// T.81 H.1.2.1: the first sample of an interval starts from 2^(P-Pt-1),
/// the rest of its first line from the left neighbour, and the first
/// column from the sample above.
fn predict(c: &Component, x: usize, y: usize, first_row: bool, predictor: u8, initial: u32) -> u32 {
    let at = |x: usize, y: usize| c.samples[y * c.width + x] as i32;

    if first_row {
        return if x == 0 { initial } else { at(x - 1, y) as u32 };
    }
    if x == 0 {
        return at(0, y - 1) as u32;
    }

    let (ra, rb, rc) = (at(x - 1, y), at(x, y - 1), at(x - 1, y - 1));
    let p = match predictor {
        0 => 0,
        1 => ra,
        2 => rb,
        3 => rc,
        4 => ra + rb - rc,
        5 => ra + ((rb - rc) >> 1),
        6 => rb + ((ra - rc) >> 1),
        _ => (ra + rb) >> 1,
    };
    p as u32
}

/// A difference: its magnitude category, then that many bits (T.81 F.1.2.1
/// and H.1.2.2; category 16 is the difference 32768 with no extra bits).
fn read_difference(reader: &mut BitReader, huffman: &Huffman) -> Result<i32, Error> {
    let category = huffman.decode(reader)?;

    match category {
        0 => Ok(0),
        16 => Ok(32768),
        1..=15 => {
            let bits = reader.bits(category)? as i32;
            Ok(if bits < 1 << (category - 1) { bits - (1 << category) + 1 } else { bits })
        }
        _ => Err(Error::InvalidJpegl),
    }
}

/// Crops the planes to the image, upsamples subsampled components and
/// scales samples to 8 bits.
fn assemble(frame: Frame, ppi: Option<u32>) -> Result<Pixels, Error> {
    let channels = match frame.components.len() {
        1 => 1,
        3 => 3,
        _ => return Err(Error::UnsupportedColorspace),
    };

    let (w, h) = (frame.width, frame.height);
    let max = (1u32 << frame.precision) - 1;
    let mut data = vec![0u8; w * h * channels];

    for (index, c) in frame.components.iter().enumerate() {
        for y in 0..h {
            let row = (y * c.v / frame.v_max) * c.width;
            for x in 0..w {
                let sample = c.samples[row + x * c.h / frame.h_max] as u32;
                data[(y * w + x) * channels + index] = (sample.min(max) * 255 / max) as u8;
            }
        }
    }

    Ok(Pixels {
        width: w as u32,
        height: h as u32,
        channels: channels as u32,
        ppi,
        colorspace: if channels == 1 { ColorSpace::Gray } else { ColorSpace::Unspecified },
        data,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const GREY: &[u8] = include_bytes!("../../../test/fixtures/synthetic_grey.jpl");
    const RGB: &[u8] = include_bytes!("../../../test/fixtures/synthetic_rgb.jpl");
    const YCC: &[u8] = include_bytes!("../../../test/fixtures/synthetic_ycc420.jpl");

    fn pattern(f: impl Fn(usize, usize) -> Vec<u8>) -> Vec<u8> {
        let mut out = Vec::new();
        for y in 0..96 {
            for x in 0..128 {
                out.extend(f(x, y));
            }
        }
        out
    }

    #[test]
    fn greyscale() {
        let p = decode(GREY).unwrap();
        assert_eq!((p.width, p.height, p.channels, p.ppi), (128, 96, 1, Some(500)));
        let expected = pattern(|x, y| vec![(128.0 + 90.0 * (x as f64 / 2.5).sin() * (y as f64 / 3.5).cos()) as u8]);
        assert_eq!(p.data, expected);
    }

    #[test]
    fn one_scan_per_component() {
        let p = decode(RGB).unwrap();
        assert_eq!(p.channels, 3);
        assert_eq!(p.data, pattern(|x, y| vec![(x * 2 % 256) as u8, (y * 2 % 256) as u8, ((x + y) % 256) as u8]));
    }

    #[test]
    fn subsampled_components() {
        let p = decode(YCC).unwrap();
        let expected = pattern(|x, y| {
            vec![((x + 2 * y) % 256) as u8, ((64 + (x / 2) * 2) % 256) as u8, (200i32 - (y as i32 / 2) * 2).rem_euclid(256) as u8]
        });
        assert_eq!(p.data, expected);
    }

    #[test]
    fn rejects_other_jpeg_frames_and_truncation() {
        let baseline = [0xFF, 0xD8, 0xFF, 0xC0, 0, 11, 8, 0, 1, 0, 1, 1, 1, 0x11, 0];
        assert_eq!(decode(&baseline).unwrap_err(), Error::NotLosslessJpeg);

        // Everything short of the final EOI marker is incomplete...
        for len in 0..GREY.len() - 2 {
            assert!(decode(&GREY[..len]).is_err(), "prefix {len}");
        }

        // ...while a missing EOI after a complete scan is tolerated.
        assert_eq!(decode(&GREY[..GREY.len() - 2]).unwrap().data, decode(GREY).unwrap().data);
    }
}

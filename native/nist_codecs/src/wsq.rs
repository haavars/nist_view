//! WSQ (Wavelet Scalar Quantization, FBI IAFIS-IC-0110 v3.1) in safe Rust.
//!
//! The reference is NBIS 5.0.0: files in the wild are made for decoders
//! derived from it. For every input that NBIS decodes without reading or
//! writing outside its buffers, `decode` returns the pixels and resolution
//! that NBIS gives when it is built without fused multiply-add
//! (`native/nbis_ref`). Where NBIS fails or corrupts memory, this returns an
//! error. docs/wsq-port.md describes the NBIS behaviour reproduced here;
//! the parts that look odd are deliberate:
//!
//! * Segment lengths are ignored, except for Huffman tables and comments
//!   (and by the separate scan for the resolution, `nistcom_ppi`).
//! * The arithmetic is `f32` with the intermediate `f64` steps of the C
//!   source, in its order of operations, and never `mul_add`.
//! * The wavelet synthesis (`join_lets`) walks the whole image buffer with
//!   the offsets NBIS uses. They reach outside the subband being
//!   reconstructed, also for valid images.
//!
//! `decode` is more lenient than NBIS in two places, which `decode_strict`
//! turns off: fill bytes (`FF`) before a marker that ends a block, and a
//! `NIST_COM` comment without a `PPI` entry.

use crate::{check_dimensions, ColorSpace, Error, Pixels};

const SOI: u16 = 0xFFA0;
const EOI: u16 = 0xFFA1;
const SOF: u16 = 0xFFA2;
const SOB: u16 = 0xFFA3;
const DTT: u16 = 0xFFA4;
const DQT: u16 = 0xFFA5;
const DHT: u16 = 0xFFA6;
const COM: u16 = 0xFFA8;

const INVALID: Error = Error::InvalidWsq;

const MAX_HUFFMAN_TABLES: usize = 8;
/// The longest filter the specification allows. NBIS accepts up to 255
/// taps, but decoding time grows with the length, and no encoder writes
/// anything but the 9 and 7 tap pair.
const MAX_FILTER_LENGTH: usize = 32;
/// Subbands of the quantisation tree; the last four are never transmitted.
const SUBBANDS: usize = 64;
const CODED_SUBBANDS: usize = 60;
/// Names and values in a `NIST_COM` comment go through 512-byte buffers in
/// NBIS.
const NISTCOM_TOKEN_LIMIT: usize = 512;

pub fn decode(data: &[u8]) -> Result<Pixels, Error> {
    decode_with(data, false)
}

/// As `decode`, but also fails on the inputs that only NBIS rejects. If this
/// succeeds, NBIS decodes the same image: used to compare the two.
pub fn decode_strict(data: &[u8]) -> Result<Pixels, Error> {
    decode_with(data, true)
}

fn decode_with(data: &[u8], strict: bool) -> Result<Pixels, Error> {
    let mut reader = Reader { data, pos: 0 };
    let mut tables = Tables::default();

    if reader.u16()? != SOI {
        return Err(INVALID);
    }
    loop {
        match reader.marker(&[DTT, DQT, DHT, COM, SOF])? {
            SOF => break,
            marker => tables.read(marker, &mut reader)?,
        }
    }

    let frame = Frame::read(&mut reader)?;
    check_dimensions(frame.width as u32, frame.height as u32)?;
    let (width, height) = (frame.width as usize, frame.height as usize);

    let ppi = nistcom_ppi(data, strict)?;
    let w_tree = build_w_tree(width as i32, height as i32);
    let q_tree = build_q_tree(&w_tree, width as i32, height as i32)?;

    let coefficients = decode_blocks(&mut reader, &mut tables, width * height, &q_tree, strict)?;
    let dqt = tables.dqt.as_ref().ok_or(INVALID)?;
    let dtt = tables.dtt.as_ref().ok_or(INVALID)?;

    let mut image = unquantize(dqt, &q_tree, &coefficients, width)?;
    drop(coefficients);
    reconstruct(&mut image, width, &w_tree, dtt)?;

    Ok(Pixels {
        width: frame.width as u32,
        height: frame.height as u32,
        channels: 1,
        ppi,
        colorspace: ColorSpace::Gray,
        data: image.iter().map(|&value| frame.pixel(value)).collect(),
    })
}

/// Big-endian fields read one after the other, as NBIS does.
struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn bytes(&mut self, n: usize) -> Result<&'a [u8], Error> {
        let end = self.pos.checked_add(n).ok_or(INVALID)?;
        let bytes = self.data.get(self.pos..end).ok_or(INVALID)?;
        self.pos = end;
        Ok(bytes)
    }

    fn u8(&mut self) -> Result<u8, Error> {
        Ok(self.bytes(1)?[0])
    }

    fn u16(&mut self) -> Result<u16, Error> {
        let b = self.bytes(2)?;
        Ok(u16::from_be_bytes([b[0], b[1]]))
    }

    fn u32(&mut self) -> Result<u32, Error> {
        let b = self.bytes(4)?;
        Ok(u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
    }

    /// A value V with a decimal exponent E in front, meaning V / 10^E.
    fn scaled_u16(&mut self) -> Result<f32, Error> {
        let exponent = self.u8()?;
        Ok(scale(self.u16()? as f32, exponent))
    }

    fn marker(&mut self, allowed: &[u16]) -> Result<u16, Error> {
        let marker = self.u16()?;
        allowed.contains(&marker).then_some(marker).ok_or(INVALID)
    }

    /// Any marker from SOI to COM.
    fn any_marker(&mut self) -> Result<u16, Error> {
        let marker = self.u16()?;
        (SOI..=COM).contains(&marker).then_some(marker).ok_or(INVALID)
    }

    /// The text of a comment segment, whose length field is honoured.
    fn comment(&mut self) -> Result<&'a [u8], Error> {
        let len = self.u16()? as usize;
        self.bytes(len.checked_sub(2).ok_or(INVALID)?)
    }
}

/// NBIS divides in double precision and rounds to `float` at every step.
fn scale(mut value: f32, exponent: u8) -> f32 {
    for _ in 0..exponent {
        value = (value as f64 / 10.0) as f32;
    }
    value
}

struct Frame {
    width: u16,
    height: u16,
    /// Midpoint and range of the pixel values: pixel = value · R + M.
    m_shift: f32,
    r_scale: f32,
}

impl Frame {
    fn read(reader: &mut Reader) -> Result<Self, Error> {
        let _length = reader.u16()?;
        let (_black, _white) = (reader.u8()?, reader.u8()?);
        let height = reader.u16()?;
        let width = reader.u16()?;
        let m_shift = reader.scaled_u16()?;
        let r_scale = reader.scaled_u16()?;
        let (_encoder, _software) = (reader.u8()?, reader.u16()?);

        Ok(Frame { width, height, m_shift, r_scale })
    }

    fn pixel(&self, value: f32) -> u8 {
        let pixel = value * self.r_scale + self.m_shift;
        let pixel = (pixel as f64 + 0.5) as f32;

        if pixel < 0.0 {
            0
        } else if pixel > 255.0 {
            255
        } else {
            // Truncates; NaN becomes 0.
            pixel as u8
        }
    }
}

/// The synthesis filters, expanded from the transmitted right halves.
struct Transform {
    lo: Vec<f32>,
    hi: Vec<f32>,
    /// `hi` negated: NBIS negates the filter in place, and restores it,
    /// around every pass with an even-length lowpass filter.
    hi_negated: Vec<f32>,
}

impl Transform {
    fn read(reader: &mut Reader) -> Result<Self, Error> {
        let _length = reader.u16()?;
        let (hisz, losz) = (reader.u8()? as usize, reader.u8()? as usize);

        // NBIS writes 256 coefficients into an empty array for a length of 0.
        if hisz == 0 || losz == 0 || hisz > MAX_FILTER_LENGTH || losz > MAX_FILTER_LENGTH {
            return Err(INVALID);
        }

        let mut coefficient = || -> Result<f32, Error> {
            let (sign, exponent) = (reader.u8()?, reader.u8()?);
            let value = scale(reader.u32()? as f32, exponent);
            Ok(if sign != 0 { -value } else { value })
        };
        let sign = |power: usize| if power % 2 == 0 { 1.0f32 } else { -1.0 };

        let mut hi = vec![0.0f32; hisz];
        let centre = hisz.div_ceil(2) - 1;
        for k in 0..=centre {
            let value = sign(k) * coefficient()?;
            if hisz % 2 == 1 {
                hi[centre + k] = value;
                hi[centre - k] = value;
            } else {
                hi[centre + k + 1] = value;
                hi[centre - k] = -value;
            }
        }

        let mut lo = vec![0.0f32; losz];
        let centre = losz.div_ceil(2) - 1;
        for k in 0..=centre {
            if losz % 2 == 1 {
                let value = sign(k) * coefficient()?;
                lo[centre + k] = value;
                lo[centre - k] = value;
            } else {
                let value = sign(k + 1) * coefficient()?;
                lo[centre + k + 1] = value;
                lo[centre - k] = value;
            }
        }

        let hi_negated = hi.iter().map(|&value| -value).collect();
        Ok(Transform { lo, hi, hi_negated })
    }
}

struct Quantization {
    bin_centre: f32,
    /// Bin widths; 0 means the subband is not transmitted.
    q: [f32; SUBBANDS],
    /// Zero bin widths.
    z: [f32; SUBBANDS],
}

impl Quantization {
    fn read(reader: &mut Reader) -> Result<Self, Error> {
        let _length = reader.u16()?;
        let mut table = Quantization { bin_centre: reader.scaled_u16()?, q: [0.0; SUBBANDS], z: [0.0; SUBBANDS] };

        for subband in 0..SUBBANDS {
            table.q[subband] = reader.scaled_u16()?;
            table.z[subband] = reader.scaled_u16()?;
        }

        Ok(table)
    }
}

#[derive(Clone)]
struct HuffmanTable {
    /// Number of codes of each length, 1 to 16 bits.
    counts: [u8; 16],
    /// NBIS keeps 257 values, and zeros after the ones transmitted.
    values: [u8; 257],
}

#[derive(Default)]
struct Tables {
    dtt: Option<Transform>,
    dqt: Option<Quantization>,
    dht: [Option<HuffmanTable>; MAX_HUFFMAN_TABLES],
}

impl Tables {
    /// Reads the table or comment segment that follows `marker`.
    fn read(&mut self, marker: u16, reader: &mut Reader) -> Result<(), Error> {
        match marker {
            DTT => self.dtt = Some(Transform::read(reader)?),
            DQT => self.dqt = Some(Quantization::read(reader)?),
            DHT => self.read_huffman(reader)?,
            COM => {
                reader.comment()?;
            }
            _ => return Err(INVALID),
        }
        Ok(())
    }

    /// One or more tables in a segment. The first may replace a table; the
    /// others may not.
    fn read_huffman(&mut self, reader: &mut Reader) -> Result<(), Error> {
        let mut bytes_left = reader.u16()? as i32 - 2;
        let mut first = true;

        while first || bytes_left != 0 {
            if bytes_left <= 0 {
                return Err(INVALID);
            }

            let id = reader.u8()? as usize;
            let mut table = HuffmanTable { counts: [0; 16], values: [0; 257] };
            for count in &mut table.counts {
                *count = reader.u8()?;
            }

            let values = table.counts.iter().map(|&count| count as usize).sum::<usize>();
            if values > table.values.len() {
                return Err(INVALID);
            }
            table.values[..values].copy_from_slice(reader.bytes(values)?);
            bytes_left -= 17 + values as i32;

            // NBIS does not check the id and writes past its eight tables.
            let slot = self.dht.get_mut(id).ok_or(INVALID)?;
            if !first && slot.is_some() {
                return Err(INVALID);
            }
            *slot = Some(table);
            first = false;
        }

        Ok(())
    }
}

/// The PPI from the first `NIST_COM` comment before the first block.
///
/// This is a pass of its own over the file in NBIS too, and unlike the
/// decoder it skips segments by their length fields. A failure here fails
/// the decode.
fn nistcom_ppi(data: &[u8], strict: bool) -> Result<Option<u32>, Error> {
    let mut reader = Reader { data, pos: 0 };

    if reader.u16()? != SOI {
        return Err(INVALID);
    }
    let mut marker = reader.any_marker()?;

    while marker != SOB {
        // NBIS looks for the header after the length, whatever the length.
        if marker == COM && data.get(reader.pos + 2..reader.pos + 10) == Some(b"NIST_COM".as_slice()) {
            return nistcom_text_ppi(reader.comment()?, strict);
        }

        let length = reader.u16()?.wrapping_sub(2) as usize;
        if reader.pos + length >= data.len() {
            return Err(INVALID);
        }
        reader.pos += length;
        marker = reader.any_marker()?;
    }

    Ok(None)
}

/// `NIST_COM` text is name and value pairs, one per line. NBIS's tokeniser
/// (`string2fet`) ends a name at a space or tab only, and a value at a
/// newline.
fn nistcom_text_ppi(text: &[u8], strict: bool) -> Result<Option<u32>, Error> {
    let text = text.split(|&byte| byte == 0).next().unwrap_or_default();
    let blank = |byte: u8| byte == b' ' || byte == b'\t';
    let mut ppi = None;
    let mut pos = 0;

    let take = |pos: &mut usize, stop: &dyn Fn(u8) -> bool| {
        let start = *pos;
        while *pos < text.len() && !stop(text[*pos]) {
            *pos += 1;
        }
        &text[start..*pos]
    };

    while pos < text.len() {
        let name = take(&mut pos, &blank);
        take(&mut pos, &|byte| !blank(byte));
        let value = take(&mut pos, &|byte| byte == b'\n');
        take(&mut pos, &|byte| !blank(byte) && byte != b'\n');

        // NBIS overflows its buffers on these.
        if strict && (name.len() >= NISTCOM_TOKEN_LIMIT || value.len() >= NISTCOM_TOKEN_LIMIT) {
            return Err(INVALID);
        }
        // The last entry counts.
        if name == b"PPI" {
            ppi = Some(value);
        }
    }

    match ppi {
        Some(value) => Ok(atoi(value)),
        // NBIS fails the whole decode.
        None if strict => Err(INVALID),
        None => Ok(None),
    }
}

/// C's `atoi`, for a positive result that fits in an `int`.
fn atoi(text: &[u8]) -> Option<u32> {
    let space = |byte: &u8| matches!(byte, b' ' | b'\t' | b'\n' | 0x0B | 0x0C | b'\r');
    let text = &text[text.iter().take_while(|byte| space(byte)).count()..];
    let digits = text.strip_prefix(b"+").unwrap_or(text);

    let value = digits
        .iter()
        .take_while(|byte| byte.is_ascii_digit())
        .fold(0u64, |value, &digit| value.saturating_mul(10).saturating_add((digit - b'0') as u64));

    (value > 0 && value <= i32::MAX as u64).then_some(value as u32)
}

/// A Huffman table prepared for decoding bit by bit, as NBIS prepares it:
/// the smallest and largest code of each length and the index of the
/// first value of that length.
struct Huffman {
    maxcode: [i32; 17],
    mincode: [i32; 17],
    valptr: [i32; 17],
    values: [u8; 257],
}

impl Huffman {
    fn new(table: &HuffmanTable) -> Result<Self, Error> {
        // The code length of each value, then a 0.
        let mut sizes: Vec<u32> = Vec::with_capacity(258);
        for (length, &count) in table.counts.iter().enumerate() {
            sizes.extend(std::iter::repeat_n(length as u32 + 1, count as usize));
        }
        // With 257 codes NBIS writes the terminator past its array.
        if sizes.len() > 256 {
            return Err(INVALID);
        }
        sizes.push(0);

        // Canonical codes. They are 16 bits wide in NBIS and wrap when a
        // table has more codes of a length than the length allows.
        let mut codes = vec![0u16; sizes.len()];
        if sizes[0] != 0 {
            let (mut index, mut code, mut size) = (0, 0u16, sizes[0]);
            loop {
                while sizes[index] == size {
                    codes[index] = code;
                    code = code.wrapping_add(1);
                    index += 1;
                }
                if sizes[index] == 0 {
                    break;
                }
                while sizes[index] != size {
                    code <<= 1;
                    size += 1;
                }
            }
        }

        let mut huffman = Huffman { maxcode: [0; 17], mincode: [0; 17], valptr: [0; 17], values: table.values };
        let mut index = 0;
        for length in 1..=16 {
            let count = table.counts[length - 1] as usize;
            if count == 0 {
                huffman.maxcode[length] = -1;
                continue;
            }
            huffman.valptr[length] = index as i32;
            huffman.mincode[length] = codes[index] as i32;
            index += count;
            huffman.maxcode[length] = codes[index - 1] as i32;
        }

        Ok(huffman)
    }

    /// The next symbol, or the marker that ends the block.
    fn symbol(&self, bits: &mut BitReader) -> Result<Bits, Error> {
        let mut code = match bits.read(1)? {
            Bits::Value(bit) => bit as i32,
            marker => return Ok(marker),
        };
        let mut length = 1;

        while code > self.maxcode[length] {
            if length >= 16 {
                return Err(INVALID);
            }
            match bits.read(1)? {
                Bits::Value(bit) => code = (code << 1) + bit as i32,
                marker => return Ok(marker),
            }
            length += 1;
        }

        let index = self.valptr[length] + code - self.mincode[length];
        let value = usize::try_from(index).ok().and_then(|index| self.values.get(index));
        Ok(Bits::Value(*value.ok_or(INVALID)? as u16))
    }
}

enum Bits {
    Value(u16),
    Marker(u16),
}

/// Entropy-coded bits: most significant bit first, with a zero byte stuffed
/// after every `FF` data byte.
struct BitReader<'r, 'a> {
    reader: &'r mut Reader<'a>,
    byte: u8,
    left: u32,
    strict: bool,
}

impl BitReader<'_, '_> {
    /// Up to 16 bits. A marker is only recognised at a byte boundary, by a
    /// read of one bit; anywhere else `FF xx` is an error.
    fn read(&mut self, count: u32) -> Result<Bits, Error> {
        let (mut value, mut needed) = (0u32, count);
        let mut may_be_marker = count == 1;

        loop {
            if self.left == 0 {
                if let Some(marker) = self.load(may_be_marker)? {
                    return Ok(Bits::Marker(marker));
                }
            }
            may_be_marker = false;

            let take = needed.min(self.left);
            self.left -= take;
            value = (value << take) | ((self.byte as u32 >> self.left) & ((1 << take) - 1));
            needed -= take;

            if needed == 0 {
                return Ok(Bits::Value(value as u16));
            }
        }
    }

    /// As `read`, where NBIS does not accept a marker.
    fn value(&mut self, count: u32) -> Result<u16, Error> {
        match self.read(count)? {
            Bits::Value(value) => Ok(value),
            Bits::Marker(_) => Err(INVALID),
        }
    }

    /// Loads the next data byte, or returns the marker found instead.
    fn load(&mut self, may_be_marker: bool) -> Result<Option<u16>, Error> {
        let byte = self.reader.u8()?;

        if byte == 0xFF {
            let mut next = self.reader.u8()?;

            if next != 0 {
                if !may_be_marker {
                    return Err(INVALID);
                }
                // Fill bytes before the marker, which the specification
                // allows. NBIS takes `FF FF` for a marker and fails.
                while next == 0xFF && !self.strict {
                    next = self.reader.u8()?;
                }
                if next == 0 {
                    return Err(INVALID);
                }
                return Ok(Some(0xFF00 | next as u16));
            }
        }

        self.byte = byte;
        self.left = 8;
        Ok(None)
    }
}

/// Decodes the blocks up to EOI into quantised coefficients, in subband
/// order. Positions the stream does not reach stay 0.
fn decode_blocks(
    reader: &mut Reader,
    tables: &mut Tables,
    pixels: usize,
    q_tree: &[Subband; SUBBANDS],
    strict: bool,
) -> Result<Vec<i16>, Error> {
    const TABLES_OR_BLOCK: &[u16] = &[DTT, DQT, DHT, COM, SOB];

    let mut coefficients = vec![0i16; pixels];
    // The number of coefficients decoded, and the limit NBIS holds it to.
    let mut count = 0i64;
    let mut limit = pixels as i64;
    let mut limit_adjusted = false;

    let mut bits = BitReader { reader, byte: 0, left: 0, strict };
    let mut marker = bits.reader.marker(TABLES_OR_BLOCK)?;
    let mut block = 0;
    let mut huffman = None;

    while marker != EOI {
        if marker != 0 {
            block += 1;
            while marker != SOB {
                tables.read(marker, bits.reader)?;
                marker = bits.reader.marker(TABLES_OR_BLOCK)?;
            }

            // Once, when a quantisation table is first known: subbands that
            // are not transmitted do not count.
            if let (Some(dqt), false) = (&tables.dqt, limit_adjusted) {
                for (subband, &q) in q_tree.iter().zip(&dqt.q) {
                    if q == 0.0 {
                        limit -= subband.lenx as i64 * subband.leny as i64;
                    }
                }
                limit_adjusted = true;
            }

            let _length = bits.reader.u16()?;
            let table = bits.reader.u8()? as usize;
            let table = tables.dht.get(table).and_then(Option::as_ref).ok_or(INVALID)?;
            huffman = Some(Huffman::new(table)?);
            bits.left = 0;
            marker = 0;
        }

        let symbol = match huffman.as_ref().ok_or(INVALID)?.symbol(&mut bits)? {
            Bits::Value(symbol) => symbol,
            Bits::Marker(found) => {
                marker = found;
                // Comments may follow the last of the three blocks.
                while marker == COM && block == 3 {
                    bits.reader.comment()?;
                    marker = bits.reader.any_marker()?;
                }
                continue;
            }
        };

        if count > limit {
            return Err(INVALID);
        }

        let coefficient = match symbol {
            // Runs of zeros: the run length, or 8 or 16 bits holding it.
            1..=100 | 105 | 106 => {
                count += match symbol {
                    105 => bits.value(8)?,
                    106 => bits.value(16)?,
                    run => run,
                } as i64;
                if count > limit {
                    return Err(INVALID);
                }
                continue;
            }
            // A coefficient in 8 or 16 bits, positive or negated.
            101 => bits.value(8)? as i16,
            102 => -(bits.value(8)? as i16),
            103 => bits.value(16)? as i16,
            104 => (bits.value(16)? as i16).wrapping_neg(),
            107..=254 => symbol as i16 - 180,
            _ => return Err(INVALID),
        };

        // NBIS writes one past its buffer when the limit is the whole image.
        *coefficients.get_mut(count as usize).ok_or(INVALID)? = coefficient;
        count += 1;
    }

    Ok(coefficients)
}

/// A node of the wavelet tree: a rectangle of the image that one synthesis
/// step joins from its four quarters.
#[derive(Clone, Copy, Default)]
struct Node {
    x: i32,
    y: i32,
    lenx: i32,
    leny: i32,
    /// Whether the high and low halves are swapped in rows and in columns.
    inv_rw: bool,
    inv_cl: bool,
}

/// The rectangle of one quantised subband.
#[derive(Clone, Copy, Default)]
struct Subband {
    x: i32,
    y: i32,
    lenx: i32,
    leny: i32,
}

/// NBIS `build_w_tree`.
fn build_w_tree(width: i32, height: i32) -> [Node; 20] {
    let mut tree = [Node::default(); 20];

    for node in [2, 4, 7, 9, 11, 13, 16, 18] {
        tree[node].inv_rw = true;
    }
    for node in [3, 5, 8, 9, 12, 13, 17, 18] {
        tree[node].inv_cl = true;
    }

    w_tree4(&mut tree, 0, 1, width, height, 0, 0, true);

    let (lenx, lenx2) = if tree[1].lenx % 2 == 0 {
        (tree[1].lenx / 2, tree[1].lenx / 2)
    } else {
        ((tree[1].lenx + 1) / 2, (tree[1].lenx + 1) / 2 - 1)
    };
    let (leny, leny2) = if tree[1].leny % 2 == 0 {
        (tree[1].leny / 2, tree[1].leny / 2)
    } else {
        ((tree[1].leny + 1) / 2, (tree[1].leny + 1) / 2 - 1)
    };

    w_tree4(&mut tree, 4, 6, lenx2, leny, lenx, 0, false);
    w_tree4(&mut tree, 5, 10, lenx, leny2, 0, leny, false);
    w_tree4(&mut tree, 14, 15, lenx, leny, 0, 0, false);

    tree[19].x = 0;
    tree[19].y = 0;
    tree[19].lenx = (tree[15].lenx + 1) / 2;
    tree[19].leny = (tree[15].leny + 1) / 2;

    tree
}

/// NBIS `w_tree4`: node `p1` and its four quarters from `p2`. `stop1` leaves
/// the fourth quarter alone.
#[allow(clippy::too_many_arguments)]
fn w_tree4(tree: &mut [Node; 20], p1: usize, p2: usize, lenx: i32, leny: i32, x: i32, y: i32, stop1: bool) {
    tree[p1].x = x;
    tree[p1].y = y;
    tree[p1].lenx = lenx;
    tree[p1].leny = leny;

    tree[p2].x = x;
    tree[p2 + 2].x = x;
    tree[p2].y = y;
    tree[p2 + 1].y = y;

    if lenx % 2 == 0 {
        tree[p2].lenx = lenx / 2;
        tree[p2 + 1].lenx = tree[p2].lenx;
    } else if p1 == 4 {
        tree[p2].lenx = (lenx - 1) / 2;
        tree[p2 + 1].lenx = tree[p2].lenx + 1;
    } else {
        tree[p2].lenx = (lenx + 1) / 2;
        tree[p2 + 1].lenx = tree[p2].lenx - 1;
    }
    tree[p2 + 1].x = tree[p2].lenx + x;
    if !stop1 {
        tree[p2 + 3].lenx = tree[p2 + 1].lenx;
        tree[p2 + 3].x = tree[p2 + 1].x;
    }
    tree[p2 + 2].lenx = tree[p2].lenx;

    if leny % 2 == 0 {
        tree[p2].leny = leny / 2;
        tree[p2 + 2].leny = tree[p2].leny;
    } else if p1 == 5 {
        tree[p2].leny = (leny - 1) / 2;
        tree[p2 + 2].leny = tree[p2].leny + 1;
    } else {
        tree[p2].leny = (leny + 1) / 2;
        tree[p2 + 2].leny = tree[p2].leny - 1;
    }
    tree[p2 + 2].y = tree[p2].leny + y;
    if !stop1 {
        tree[p2 + 3].leny = tree[p2 + 2].leny;
        tree[p2 + 3].y = tree[p2 + 2].y;
    }
    tree[p2 + 1].leny = tree[p2].leny;
}

/// NBIS `build_q_tree`. The order of the calls matters: they overlap.
fn build_q_tree(w_tree: &[Node; 20], width: i32, height: i32) -> Result<[Subband; SUBBANDS], Error> {
    let mut tree = [Subband::default(); SUBBANDS];

    q_tree16(&mut tree, 3, &w_tree[14], false, false);
    q_tree16(&mut tree, 19, &w_tree[4], false, true);
    q_tree16(&mut tree, 48, &w_tree[0], false, false);
    q_tree16(&mut tree, 35, &w_tree[5], true, false);
    q_tree4(&mut tree, 0, &w_tree[19]);

    // NBIS keeps these in `short`s, which wrap above 32767, and nothing
    // stops a rectangle from leaving the image.
    let fits = |start: i32, len: i32, size: i32| {
        start >= 0 && len >= 0 && start <= i16::MAX as i32 && len <= i16::MAX as i32 && start + len <= size
    };
    if tree.iter().all(|s| fits(s.x, s.lenx, width) && fits(s.y, s.leny, height)) {
        Ok(tree)
    } else {
        Err(INVALID)
    }
}

/// NBIS `q_tree16`: sixteen subbands from `p`, splitting a node twice.
fn q_tree16(tree: &mut [Subband; SUBBANDS], p: usize, node: &Node, rw: bool, cl: bool) {
    let (lenx, leny, x, y) = (node.lenx, node.leny, node.x, node.y);

    let (tempx, temp2x) = if lenx % 2 == 0 {
        (lenx / 2, lenx / 2)
    } else if cl {
        ((lenx + 1) / 2 - 1, (lenx + 1) / 2)
    } else {
        ((lenx + 1) / 2, (lenx + 1) / 2 - 1)
    };
    let (tempy, temp2y) = if leny % 2 == 0 {
        (leny / 2, leny / 2)
    } else if rw {
        ((leny + 1) / 2 - 1, (leny + 1) / 2)
    } else {
        ((leny + 1) / 2, (leny + 1) / 2 - 1)
    };

    tree[p].x = x;
    tree[p + 2].x = x;
    tree[p].y = y;
    tree[p + 1].y = y;
    if tempx % 2 == 0 {
        tree[p].lenx = tempx / 2;
        tree[p + 1].lenx = tree[p].lenx;
        tree[p + 2].lenx = tree[p].lenx;
        tree[p + 3].lenx = tree[p].lenx;
    } else {
        tree[p].lenx = (tempx + 1) / 2;
        tree[p + 1].lenx = tree[p].lenx - 1;
        tree[p + 2].lenx = tree[p].lenx;
        tree[p + 3].lenx = tree[p + 1].lenx;
    }
    tree[p + 1].x = x + tree[p].lenx;
    tree[p + 3].x = tree[p + 1].x;
    if tempy % 2 == 0 {
        tree[p].leny = tempy / 2;
        tree[p + 1].leny = tree[p].leny;
        tree[p + 2].leny = tree[p].leny;
        tree[p + 3].leny = tree[p].leny;
    } else {
        tree[p].leny = (tempy + 1) / 2;
        tree[p + 1].leny = tree[p].leny;
        tree[p + 2].leny = tree[p].leny - 1;
        tree[p + 3].leny = tree[p + 2].leny;
    }
    tree[p + 2].y = y + tree[p].leny;
    tree[p + 3].y = tree[p + 2].y;

    tree[p + 4].x = x + tempx;
    tree[p + 6].x = tree[p + 4].x;
    tree[p + 4].y = y;
    tree[p + 5].y = y;
    tree[p + 6].y = tree[p + 2].y;
    tree[p + 7].y = tree[p + 2].y;
    tree[p + 4].leny = tree[p].leny;
    tree[p + 5].leny = tree[p].leny;
    tree[p + 6].leny = tree[p + 2].leny;
    tree[p + 7].leny = tree[p + 2].leny;
    if temp2x % 2 == 0 {
        tree[p + 4].lenx = temp2x / 2;
        tree[p + 5].lenx = tree[p + 4].lenx;
        tree[p + 6].lenx = tree[p + 4].lenx;
        tree[p + 7].lenx = tree[p + 4].lenx;
    } else {
        tree[p + 5].lenx = (temp2x + 1) / 2;
        tree[p + 4].lenx = tree[p + 5].lenx - 1;
        tree[p + 6].lenx = tree[p + 4].lenx;
        tree[p + 7].lenx = tree[p + 5].lenx;
    }
    tree[p + 5].x = tree[p + 4].x + tree[p + 4].lenx;
    tree[p + 7].x = tree[p + 5].x;

    tree[p + 8].x = x;
    tree[p + 9].x = tree[p + 1].x;
    tree[p + 10].x = x;
    tree[p + 11].x = tree[p + 1].x;
    tree[p + 8].y = y + tempy;
    tree[p + 9].y = tree[p + 8].y;
    tree[p + 8].lenx = tree[p].lenx;
    tree[p + 9].lenx = tree[p + 1].lenx;
    tree[p + 10].lenx = tree[p].lenx;
    tree[p + 11].lenx = tree[p + 1].lenx;
    if temp2y % 2 == 0 {
        tree[p + 8].leny = temp2y / 2;
        tree[p + 9].leny = tree[p + 8].leny;
        tree[p + 10].leny = tree[p + 8].leny;
        tree[p + 11].leny = tree[p + 8].leny;
    } else {
        tree[p + 10].leny = (temp2y + 1) / 2;
        tree[p + 11].leny = tree[p + 10].leny;
        tree[p + 8].leny = tree[p + 10].leny - 1;
        tree[p + 9].leny = tree[p + 8].leny;
    }
    tree[p + 10].y = tree[p + 8].y + tree[p + 8].leny;
    tree[p + 11].y = tree[p + 10].y;

    tree[p + 12].x = tree[p + 4].x;
    tree[p + 13].x = tree[p + 5].x;
    tree[p + 14].x = tree[p + 4].x;
    tree[p + 15].x = tree[p + 5].x;
    tree[p + 12].y = tree[p + 8].y;
    tree[p + 13].y = tree[p + 8].y;
    tree[p + 14].y = tree[p + 10].y;
    tree[p + 15].y = tree[p + 10].y;
    tree[p + 12].lenx = tree[p + 4].lenx;
    tree[p + 13].lenx = tree[p + 5].lenx;
    tree[p + 14].lenx = tree[p + 4].lenx;
    tree[p + 15].lenx = tree[p + 5].lenx;
    tree[p + 12].leny = tree[p + 8].leny;
    tree[p + 13].leny = tree[p + 8].leny;
    tree[p + 14].leny = tree[p + 10].leny;
    tree[p + 15].leny = tree[p + 10].leny;
}

/// NBIS `q_tree4`: four subbands from `p`, splitting a node once.
fn q_tree4(tree: &mut [Subband; SUBBANDS], p: usize, node: &Node) {
    let (lenx, leny, x, y) = (node.lenx, node.leny, node.x, node.y);

    tree[p].x = x;
    tree[p + 2].x = x;
    tree[p].y = y;
    tree[p + 1].y = y;
    if lenx % 2 == 0 {
        tree[p].lenx = lenx / 2;
        tree[p + 1].lenx = tree[p].lenx;
        tree[p + 2].lenx = tree[p].lenx;
        tree[p + 3].lenx = tree[p].lenx;
    } else {
        tree[p].lenx = (lenx + 1) / 2;
        tree[p + 1].lenx = tree[p].lenx - 1;
        tree[p + 2].lenx = tree[p].lenx;
        tree[p + 3].lenx = tree[p + 1].lenx;
    }
    tree[p + 1].x = x + tree[p].lenx;
    tree[p + 3].x = tree[p + 1].x;
    if leny % 2 == 0 {
        tree[p].leny = leny / 2;
        tree[p + 1].leny = tree[p].leny;
        tree[p + 2].leny = tree[p].leny;
        tree[p + 3].leny = tree[p].leny;
    } else {
        tree[p].leny = (leny + 1) / 2;
        tree[p + 1].leny = tree[p].leny;
        tree[p + 2].leny = tree[p].leny - 1;
        tree[p + 3].leny = tree[p + 2].leny;
    }
    tree[p + 2].y = y + tree[p].leny;
    tree[p + 3].y = tree[p + 2].y;
}

/// Turns the quantised coefficients into wavelet coefficients, each
/// subband in its rectangle of the image.
fn unquantize(
    dqt: &Quantization,
    q_tree: &[Subband; SUBBANDS],
    coefficients: &[i16],
    width: usize,
) -> Result<Vec<f32>, Error> {
    let mut image = vec![0.0f32; coefficients.len()];
    let mut coefficients = coefficients.iter();
    let centre = dqt.bin_centre;

    for (subband, (&q, &z)) in q_tree.iter().zip(dqt.q.iter().zip(&dqt.z)).take(CODED_SUBBANDS) {
        if q == 0.0 {
            continue;
        }
        let half_zero_bin = z as f64 / 2.0;

        for row in 0..subband.leny as usize {
            let start = (subband.y as usize + row) * width + subband.x as usize;
            let samples = image.get_mut(start..start + subband.lenx as usize).ok_or(INVALID)?;

            for value in samples {
                let p = *coefficients.next().ok_or(INVALID)?;
                *value = match p {
                    0 => 0.0,
                    1.. => ((q * (p as f32 - centre)) as f64 + half_zero_bin) as f32,
                    _ => ((q * (p as f32 + centre)) as f64 - half_zero_bin) as f32,
                };
            }
        }
    }

    Ok(image)
}

/// Wavelet synthesis: joins the subbands node by node, from the deepest
/// node up to the whole image, columns first and then rows.
fn reconstruct(image: &mut [f32], width: usize, w_tree: &[Node; 20], dtt: &Transform) -> Result<(), Error> {
    // NBIS always writes this buffer from its start, whatever the node.
    let mut scratch = vec![0.0f32; image.len()];
    let width = width as isize;

    for node in w_tree.iter().rev() {
        let base = node.y as isize * width + node.x as isize;

        join_lets(&mut scratch, 0, image, base, node.lenx, node.leny, 1, width, dtt, node.inv_cl)?;
        join_lets(image, base, &scratch, 0, node.leny, node.lenx, width, 1, dtt, node.inv_rw)?;
    }

    Ok(())
}

fn get(buffer: &[f32], index: isize) -> Result<f32, Error> {
    usize::try_from(index).ok().and_then(|index| buffer.get(index)).copied().ok_or(INVALID)
}

fn put(buffer: &mut [f32], index: isize, value: f32) -> Result<(), Error> {
    *usize::try_from(index).ok().and_then(|index| buffer.get_mut(index)).ok_or(INVALID)? = value;
    Ok(())
}

/// The ends of one half of a line in the source buffer, where the filter
/// reflects, and the steps forwards and backwards along the line.
struct Span {
    first: isize,
    last: isize,
    forward: isize,
    backward: isize,
}

/// NBIS `join_lets`: joins the low and high halves of `len1` lines of
/// `len2` samples. Lines are `pitch` apart and their samples `stride` apart,
/// in both buffers.
///
/// A literal port. The positions are offsets into the whole buffers, as the
/// pointers are in NBIS, and are only checked when they are read or written:
/// NBIS reads outside the node it is joining (the filter's first sample can
/// lie beyond a short half), and writes two samples of every line before it
/// reads anything. Staying inside the buffers is what keeps that defined.
#[allow(clippy::too_many_arguments)]
fn join_lets(
    new: &mut [f32],
    new_base: isize,
    old: &[f32],
    old_base: isize,
    len1: i32,
    len2: i32,
    pitch: isize,
    stride: isize,
    dtt: &Transform,
    inv: bool,
) -> Result<(), Error> {
    let lo = &dtt.lo[..];
    let (lsz, hsz) = (lo.len() as i32, dtt.hi.len() as i32);
    let da_ev = len2 % 2 != 0;
    let fi_ev = lsz % 2 != 0;
    let asym = !fi_ev;
    let hi = if fi_ev { &dtt.hi[..] } else { &dtt.hi_negated[..] };

    let llen = if da_ev { (len2 + 1) / 2 } else { len2 / 2 };
    let hlen = if da_ev { llen - 1 } else { llen };

    let (ssfac, ofhre, mut loc, mut hoc, lotap, hotap);
    let (mut olle, olre, mut ohle, ohre);
    if fi_ev {
        ssfac = 1.0f32;
        ofhre = 0;
        loc = (lsz - 1) / 4;
        hoc = (hsz + 1) / 4 - 1;
        lotap = ((lsz - 1) / 2) % 2;
        hotap = ((hsz + 1) / 2) % 2;
        (olle, olre, ohle, ohre) = if da_ev { (false, false, true, true) } else { (false, true, true, false) };
    } else {
        ssfac = -1.0;
        ofhre = 2;
        loc = lsz / 4 - 1;
        hoc = hsz / 4 - 1;
        lotap = (lsz / 2) % 2;
        hotap = (hsz / 2) % 2;
        (olle, olre, ohle, ohre) = if da_ev { (true, false, true, true) } else { (true, true, true, true) };
        if loc == -1 {
            loc = 0;
            olle = false;
        }
        if hoc == -1 {
            hoc = 0;
            ohle = false;
        }
    }

    // One output sample of the lowpass branch: `*limg = ...; *limg += ...`.
    let low = |new: &mut [f32], limg: isize, tap: i32, mut lpx: isize, mut lpxstr: isize, mut lle: bool, mut lre: bool, span: &Span| {
        let mut sum = get(old, lpx)? * *lo.get(tap as usize).ok_or(INVALID)?;

        for i in ((tap + 2)..lsz).step_by(2) {
            if lpx == span.first {
                if lle {
                    lpxstr = 0;
                    lle = false;
                } else {
                    lpxstr = span.forward;
                }
            }
            if lpx == span.last {
                if lre {
                    lpxstr = 0;
                    lre = false;
                } else {
                    lpxstr = span.backward;
                }
            }
            lpx += lpxstr;
            sum += get(old, lpx)? * lo[i as usize];
        }

        put(new, limg, sum)
    };

    // One output sample of the highpass branch: `*himg += ...`.
    #[allow(clippy::too_many_arguments)]
    let high = |new: &mut [f32], himg: isize, tap: i32, mut hpx: isize, mut hpxstr: isize, mut hle: bool, mut hre: bool, mut sfac: f32, fhre: &mut i32, span: &Span| {
        if tap >= hsz {
            return Ok(());
        }
        let mut sum = get(new, himg)?;

        for i in (tap..hsz).step_by(2) {
            if hpx == span.first {
                if hle {
                    hpxstr = 0;
                    hle = false;
                } else {
                    hpxstr = span.forward;
                    sfac = 1.0;
                }
            }
            if hpx == span.last {
                if hre {
                    hpxstr = 0;
                    hre = false;
                    if asym && da_ev {
                        hre = true;
                        *fhre -= 1;
                        sfac = *fhre as f32;
                        if sfac == 0.0 {
                            hre = false;
                        }
                    }
                } else {
                    hpxstr = span.backward;
                    if asym {
                        sfac = -1.0;
                    }
                }
            }
            sum += get(old, hpx)? * hi[i as usize] * sfac;
            hpx += hpxstr;
        }

        put(new, himg, sum)
    };

    let (pstr, nstr) = (stride, -stride);
    let mut fhre = 0;

    for cl_rw in 0..len1 as isize {
        let mut limg = new_base + cl_rw * pitch;
        let mut himg = limg;
        put(new, himg, 0.0)?;
        put(new, himg + stride, 0.0)?;

        let line = old_base + cl_rw * pitch;
        let (lopass, hipass) = if inv {
            (line + stride * hlen as isize, line)
        } else {
            (line, line + stride * llen as isize)
        };

        let lspan = Span { first: lopass, last: lopass + (llen - 1) as isize * stride, forward: pstr, backward: nstr };
        let mut lspx = lopass + loc as isize * stride;
        let mut lspxstr = nstr;
        let mut lstap = lotap;
        let mut lle2 = olle;
        let lre2 = olre;

        let hspan = Span { first: hipass, last: hipass + (hlen - 1) as isize * stride, forward: pstr, backward: nstr };
        let mut hspx = hipass + hoc as isize * stride;
        let mut hspxstr = nstr;
        let mut hstap = hotap;
        let mut hle2 = ohle;
        let hre2 = ohre;
        let mut osfac = ssfac;

        for _ in 0..hlen {
            for tap in (0..=lstap).rev() {
                low(new, limg, tap, lspx, lspxstr, lle2, lre2, &lspan)?;
                limg += stride;
            }
            if lspx == lspan.first {
                if lle2 {
                    lspxstr = 0;
                    lle2 = false;
                } else {
                    lspxstr = pstr;
                }
            }
            lspx += lspxstr;
            lstap = 1;

            for tap in (0..=hstap).rev() {
                fhre = ofhre;
                high(new, himg, tap, hspx, hspxstr, hle2, hre2, osfac, &mut fhre, &hspan)?;
                himg += stride;
            }
            if hspx == hspan.first {
                if hle2 {
                    hspxstr = 0;
                    hle2 = false;
                } else {
                    hspxstr = pstr;
                    osfac = 1.0;
                }
            }
            hspx += hspxstr;
            hstap = 1;
        }

        lstap = match (da_ev, lotap != 0) {
            (true, true) => 1,
            (true, false) => 0,
            (false, true) => 2,
            (false, false) => 1,
        };
        for tap in (lstap..=1).rev() {
            low(new, limg, tap, lspx, lspxstr, lle2, lre2, &lspan)?;
            limg += stride;
        }

        if da_ev {
            hstap = if hotap != 0 { 1 } else { 0 };
            if hsz == 2 {
                hspx -= hspxstr;
                fhre = 1;
            }
        } else {
            hstap = if hotap != 0 { 2 } else { 1 };
        }
        for tap in (hstap..=1).rev() {
            if hsz != 2 {
                fhre = ofhre;
            }
            high(new, himg, tap, hspx, hspxstr, hle2, hre2, osfac, &mut fhre, &hspan)?;
            himg += stride;
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SYNTHETIC: &[u8] = include_bytes!("../../../test/fixtures/synthetic.wsq");

    // Offsets in the fixture: SOI, COM, DTT, DQT, SOF, DHT, the first block
    // (table 0), a second DHT and two more blocks (table 1), EOI.
    const DTT_SEGMENT: usize = 125;
    const DHT_SEGMENT: usize = 595;
    const FIRST_BLOCK: usize = 739;
    const SECOND_DHT: usize = 1738;

    fn patched(offset: usize, byte: u8) -> Vec<u8> {
        let mut data = SYNTHETIC.to_vec();
        data[offset] = byte;
        data
    }

    fn fnv1a(data: &[u8]) -> u64 {
        data.iter().fold(0xcbf2_9ce4_8422_2325, |hash, &byte| (hash ^ byte as u64).wrapping_mul(0x0000_0100_0000_01b3))
    }

    #[test]
    fn synthetic_fixture() {
        let image = decode(SYNTHETIC).unwrap();
        assert_eq!((image.width, image.height, image.channels, image.ppi), (128, 96, 1, Some(500)));
        assert_eq!(image.colorspace, ColorSpace::Gray);

        // Lossy: close to the pattern that was encoded.
        let error: f64 = (0..96)
            .flat_map(|y| (0..128).map(move |x| (x, y)))
            .map(|(x, y)| {
                let expected = (128.0 + 90.0 * (x as f64 / 2.5).sin() * (y as f64 / 3.5).cos()) as u8;
                (image.data[y * 128 + x] as f64 - expected as f64).abs()
            })
            .sum();
        assert!(error / (128.0 * 96.0) < 1.0);

        // The same on every platform: no fused multiply-add. NBIS gives
        // these pixels too (native/nbis_ref/tests/compare.rs).
        assert_eq!(fnv1a(&image.data), 0xb0e4_0f64_3dff_73b9);
    }

    #[test]
    fn strict_decoding_agrees_on_the_fixture() {
        assert_eq!(decode_strict(SYNTHETIC).unwrap().data, decode(SYNTHETIC).unwrap().data);
    }

    #[test]
    fn every_truncation_is_an_error() {
        for length in 0..SYNTHETIC.len() {
            assert_eq!(decode(&SYNTHETIC[..length]).err(), Some(INVALID), "{length} bytes");
        }
    }

    #[test]
    fn corrupted_bytes_never_panic() {
        let mut state = 0x9E37_79B9u32;
        let mut random = || {
            state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            (state >> 8) as usize
        };

        for _ in 0..3000 {
            let mut data = SYNTHETIC.to_vec();
            for _ in 0..1 + random() % 4 {
                // Mostly in the headers and tables, where a byte decides more.
                let offset = if random() % 3 == 0 { random() % data.len() } else { random() % FIRST_BLOCK };
                data[offset] = random() as u8;
            }
            let _ = decode(&data);
            let _ = decode_strict(&data);
        }
    }

    #[test]
    fn oversized_and_empty_images_are_refused_before_decoding() {
        let mut data = SYNTHETIC.to_vec();
        data[582..586].copy_from_slice(&[0xFF, 0xFF, 0xFF, 0xFF]);
        assert_eq!(decode(&data).err(), Some(Error::TooLarge));

        data[582..586].copy_from_slice(&[0, 0, 0, 128]);
        assert_eq!(decode(&data).err(), Some(Error::InvalidDimensions));
    }

    #[test]
    fn zero_length_filters_are_errors() {
        // hisz and losz follow the marker and the length.
        assert_eq!(decode(&patched(DTT_SEGMENT + 4, 0)).err(), Some(INVALID));
        assert_eq!(decode(&patched(DTT_SEGMENT + 5, 0)).err(), Some(INVALID));
    }

    #[test]
    fn huffman_table_ids_are_checked() {
        // The id a table is stored under.
        assert_eq!(decode(&patched(DHT_SEGMENT + 4, 8)).err(), Some(INVALID));
        assert_eq!(decode(&patched(DHT_SEGMENT + 4, 255)).err(), Some(INVALID));
        // The table a block selects: out of range, and not defined yet.
        assert_eq!(decode(&patched(FIRST_BLOCK + 4, 8)).err(), Some(INVALID));
        assert_eq!(decode(&patched(FIRST_BLOCK + 4, 1)).err(), Some(INVALID));
    }

    #[test]
    fn a_huffman_segment_may_not_redefine_a_table_after_its_first() {
        let table = |id: u8| {
            let mut table = vec![id];
            table.extend_from_slice(&[1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 181]);
            table
        };
        let read = |tables: &mut Tables, ids: &[u8]| {
            let mut segment = ((2 + 18 * ids.len()) as u16).to_be_bytes().to_vec();
            ids.iter().for_each(|&id| segment.extend(table(id)));
            tables.read(DHT, &mut Reader { data: &segment, pos: 0 })
        };

        let mut tables = Tables::default();
        assert_eq!(read(&mut tables, &[3, 4]), Ok(()));
        // The first table of a segment replaces; a later one does not.
        assert_eq!(read(&mut tables, &[3]), Ok(()));
        assert_eq!(read(&mut tables, &[5, 3]), Err(INVALID));
        assert_eq!(read(&mut tables, &[6, 6]), Err(INVALID));
        assert!(tables.dht[5].is_some() && tables.dht[7].is_none());
    }

    #[test]
    fn a_huffman_segment_length_must_match_its_tables() {
        let segment = |length: u16| {
            let mut segment = length.to_be_bytes().to_vec();
            segment.extend_from_slice(&[0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 181]);
            // What a second table would be read from.
            segment.extend_from_slice(&[0; 40]);
            segment
        };
        let read = |length| Tables::default().read(DHT, &mut Reader { data: &segment(length), pos: 0 });

        assert_eq!(read(20), Ok(()));
        assert_eq!(read(2), Err(INVALID));
        assert_eq!(read(19), Err(INVALID));
        assert_eq!(read(21), Err(INVALID));
    }

    #[test]
    fn huffman_tables_with_too_many_codes() {
        let table = |counts: [u8; 16]| HuffmanTable { counts, values: [181; 257] };
        let mut counts = [0; 16];

        counts[15] = 255;
        counts[14] = 1;
        assert!(Huffman::new(&table(counts)).is_ok());
        // NBIS writes past its array for 257 codes.
        counts[14] = 2;
        assert!(Huffman::new(&table(counts)).is_err());

        // More codes of a length than exist: the 16-bit codes wrap, as in
        // NBIS, and nothing panics.
        assert!(Huffman::new(&table([17, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])).is_ok());
        assert!(Huffman::new(&table([16; 16])).is_ok());
    }

    fn bits<'r, 'a>(reader: &'r mut Reader<'a>, strict: bool) -> BitReader<'r, 'a> {
        BitReader { reader, byte: 0, left: 0, strict }
    }

    fn marker(bits: &mut BitReader) -> Option<u16> {
        match bits.read(1) {
            Ok(Bits::Marker(marker)) => Some(marker),
            _ => None,
        }
    }

    #[test]
    fn bits_are_read_most_significant_first_across_stuffed_bytes() {
        let mut reader = Reader { data: &[0b1010_0000, 0xFF, 0x00, 0x12, 0x34], pos: 0 };
        let mut bits = bits(&mut reader, false);

        assert_eq!(bits.value(1), Ok(1));
        assert_eq!(bits.value(3), Ok(0b010));
        // Four bits of the first byte, then the stuffed FF.
        assert_eq!(bits.value(8), Ok(0x0F));
        assert_eq!(bits.value(16), Ok(0xF123));
        assert_eq!(bits.value(4), Ok(4));
        assert_eq!(bits.value(1), Err(INVALID));
    }

    #[test]
    fn a_marker_is_found_by_a_one_bit_read_at_a_byte_boundary() {
        let mut reader = Reader { data: &[0x80, 0xFF, 0xA1], pos: 0 };
        let mut bits = bits(&mut reader, false);

        assert_eq!(bits.value(8), Ok(0x80));
        assert_eq!(marker(&mut bits), Some(EOI));
    }

    #[test]
    fn a_marker_inside_a_longer_read_is_an_error() {
        // At the start of the read.
        let mut reader = Reader { data: &[0xFF, 0xA1, 0x00], pos: 0 };
        assert_eq!(bits(&mut reader, false).value(8), Err(INVALID));

        // With 7 bits taken and 1 to go: NBIS writes through a null pointer.
        let mut reader = Reader { data: &[0x80, 0xFF, 0xA1], pos: 0 };
        let mut bits = bits(&mut reader, false);
        assert_eq!(bits.value(1), Ok(1));
        assert_eq!(bits.value(8), Err(INVALID));
    }

    #[test]
    fn fill_bytes_before_a_marker() {
        let data = [0xFF, 0xFF, 0xFF, 0xA3];
        assert_eq!(marker(&mut bits(&mut Reader { data: &data, pos: 0 }, false)), Some(SOB));
        // NBIS reads `FF FF` as a marker, which then fails as unknown.
        assert_eq!(marker(&mut bits(&mut Reader { data: &data, pos: 0 }, true)), Some(0xFFFF));
        // Fill bytes and then a stuffed zero mean nothing.
        assert_eq!(marker(&mut bits(&mut Reader { data: &[0xFF, 0xFF, 0x00], pos: 0 }, false)), None);

        // In a whole file: before the table that follows the first block.
        let mut data = SYNTHETIC.to_vec();
        data.insert(SECOND_DHT, 0xFF);
        assert_eq!(decode(&data).unwrap().data, decode(SYNTHETIC).unwrap().data);
        assert_eq!(decode_strict(&data).err(), Some(INVALID));
    }

    #[test]
    fn scaled_values_round_at_every_division() {
        assert_eq!(scale(12752.0, 2), 127.52);
        assert_eq!(scale(7.0, 0), 7.0);
        // Not what one division by 10^9 gives.
        assert_ne!(scale(852_698_679.0, 9), 0.852_698_679);
        assert_eq!(scale(1.0, 255), 0.0);
    }

    #[test]
    fn filters_are_expanded_from_their_right_halves() {
        let coefficients = |values: &[(u8, u32)]| values.iter().flat_map(|&(sign, value)| [vec![sign, 0], value.to_be_bytes().to_vec()].concat()).collect::<Vec<u8>>();
        let read = |hisz: u8, losz: u8, values: &[(u8, u32)]| {
            let data = [vec![0, 0, hisz, losz], coefficients(values)].concat();
            Transform::read(&mut Reader { data: &data, pos: 0 })
        };

        // Odd lengths: symmetric, signs alternating from the centre.
        let odd = read(5, 3, &[(0, 1), (0, 2), (1, 3), (0, 4), (0, 5)]).unwrap();
        assert_eq!(odd.hi, [-3.0, -2.0, 1.0, -2.0, -3.0]);
        assert_eq!(odd.lo, [-5.0, 4.0, -5.0]);
        assert_eq!(odd.hi_negated, [3.0, 2.0, -1.0, 2.0, 3.0]);

        // Even lengths: the highpass filter is antisymmetric.
        let even = read(4, 2, &[(0, 1), (0, 2), (0, 3)]).unwrap();
        assert_eq!(even.hi, [2.0, -1.0, 1.0, -2.0]);
        assert_eq!(even.lo, [-3.0, -3.0]);

        assert!(read(4, 2, &[(0, 1), (0, 2)]).is_err());
    }

    #[test]
    fn filters_longer_than_the_specification_allows_are_errors() {
        let read = |hisz: u8, losz: u8| {
            let data = [vec![0, 0, hisz, losz], vec![0; 6 * 256]].concat();
            Transform::read(&mut Reader { data: &data, pos: 0 }).is_ok()
        };

        assert!(read(32, 31) && read(31, 32) && read(1, 32));
        assert!(!read(33, 7) && !read(9, 33) && !read(255, 255));
    }

    #[test]
    fn subbands_tile_the_image() {
        let sizes = (1..=70).flat_map(|width| (1..=70).map(move |height| (width, height)));

        for (width, height) in sizes.chain([(127, 95), (545, 622), (804, 1000), (1, 3000), (32_767, 3)]) {
            let w_tree = build_w_tree(width, height);
            let q_tree = build_q_tree(&w_tree, width, height).unwrap_or_else(|_| panic!("{width} × {height}"));

            let mut covered = vec![0u8; (width * height) as usize];
            for subband in &q_tree {
                for y in subband.y..subband.y + subband.leny {
                    for x in subband.x..subband.x + subband.lenx {
                        covered[(y * width + x) as usize] += 1;
                    }
                }
            }
            assert!(covered.iter().all(|&count| count == 1), "{width} × {height}");

            for node in &w_tree {
                assert!(node.x >= 0 && node.y >= 0 && node.lenx >= 0 && node.leny >= 0, "{width} × {height}");
                assert!(node.x + node.lenx <= width && node.y + node.leny <= height, "{width} × {height}");
            }
        }
    }

    #[test]
    fn subband_positions_that_nbis_cannot_hold_are_errors() {
        assert!(build_q_tree(&build_w_tree(65_535, 3), 65_535, 3).is_err());
    }

    #[test]
    fn ppi_comes_from_the_last_ppi_entry_of_nist_com() {
        let ppi = |text: &[u8]| nistcom_text_ppi(text, false);

        assert_eq!(ppi(b"NIST_COM 2\nPPI 500\n"), Ok(Some(500)));
        assert_eq!(ppi(b"NIST_COM 3\nPPI 500\nPPI 1000\n"), Ok(Some(1000)));
        assert_eq!(ppi(b"NIST_COM 2\nPPI\t 72 \n"), Ok(Some(72)));
        assert_eq!(ppi(b"NIST_COM 2\nPPI -1\n"), Ok(None));
        assert_eq!(ppi(b"NIST_COM 2\nPPI\n"), Ok(None));
        assert_eq!(ppi(b"NIST_COM 2\nPPI 99999999999\n"), Ok(None));
        // The text ends at the first NUL.
        assert_eq!(ppi(b"NIST_COM 2\nPPI 500\0\nPPI 300\n"), Ok(Some(500)));
        // A name runs to a space or tab, so a line without a value takes the
        // next line's name with it.
        assert_eq!(ppi(b"NIST_COM 2\nLOSSY\nPPI 500\n"), Ok(None));
    }

    #[test]
    fn nist_com_without_ppi() {
        assert_eq!(nistcom_text_ppi(b"NIST_COM 1\n", false), Ok(None));
        // NBIS fails the decode, and overflows on long names and values.
        assert_eq!(nistcom_text_ppi(b"NIST_COM 1\n", true), Err(INVALID));
        let long = [b"NIST_COM 2\nPPI 500\nX ".as_slice(), &[b'y'; 512]].concat();
        assert_eq!(nistcom_text_ppi(&long, false), Ok(Some(500)));
        assert_eq!(nistcom_text_ppi(&long, true), Err(INVALID));
    }

    #[test]
    fn ppi_is_none_without_a_nist_com_comment() {
        // The comment no longer starts with NIST_COM.
        let image = decode(&patched(6, b'n')).unwrap();
        assert_eq!(image.ppi, None);
        assert_eq!(image.data, decode(SYNTHETIC).unwrap().data);
    }

    #[test]
    fn the_ppi_pass_needs_correct_segment_lengths() {
        // The decoder itself ignores the length of a transform table, but
        // the scan for NIST_COM skips by it, in NBIS too.
        assert_eq!(decode(&patched(6, b'n')).map(|image| image.ppi), Ok(None));
        let mut data = patched(6, b'n');
        data[DTT_SEGMENT + 3] += 1;
        assert_eq!(decode(&data).err(), Some(INVALID));
    }

    #[test]
    fn pixels_are_shifted_scaled_and_clamped() {
        let frame = Frame { width: 1, height: 1, m_shift: 128.0, r_scale: 2.0 };
        assert_eq!(frame.pixel(0.0), 128);
        assert_eq!(frame.pixel(0.24), 128);
        assert_eq!(frame.pixel(0.25), 129);
        assert_eq!(frame.pixel(-100.0), 0);
        assert_eq!(frame.pixel(100.0), 255);
        assert_eq!(frame.pixel(f32::NAN), 0);
        assert_eq!(frame.pixel(f32::INFINITY), 255);
    }
}

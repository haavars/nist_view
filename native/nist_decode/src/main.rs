//! Decodes images for NistView in a process of its own. The decoders are
//! safe Rust (`nist_codecs::wsq`, `jpegl` and `jp2`), so a hostile file
//! cannot corrupt memory, but it can make one panic, run out of memory or
//! take too long. Here that ends this process and not the BEAM. See
//! `NistView.Decoder`.
//!
//! The protocol is Erlang's `{:packet, 4}` on stdin and stdout: every
//! message is a 4-byte big-endian length followed by that many bytes.
//!
//! * Request: one format byte (`W` WSQ, `L` lossless JPEG, `J` JPEG 2000),
//!   then the encoded image.
//! * Reply: `O`, then width, height, channels and ppi (0 when unknown) as
//!   big-endian u32s, one colour space byte (`G` grey, `R` sRGB, `Y` sYCC,
//!   `U` unspecified) and the pixels; or `E` and an error name.
//!
//! The process serves requests until stdin closes.

use std::io::{self, Read, Write};

use nist_codecs::{jp2, jpegl, wsq, ColorSpace, Error, Pixels};

fn main() {
    let mut stdin = io::stdin().lock();
    let mut stdout = io::stdout().lock();

    while let Some(request) = read_packet(&mut stdin) {
        let reply = match request.split_first() {
            Some((b'W', data)) => encode(wsq::decode(data)),
            Some((b'L', data)) => encode(jpegl::decode(data)),
            Some((b'J', data)) => encode(jp2::decode(data)),
            _ => b"Eunknown_format".to_vec(),
        };

        if write_packet(&mut stdout, &reply).is_err() {
            break;
        }
    }
}

fn read_packet(input: &mut impl Read) -> Option<Vec<u8>> {
    let mut len = [0u8; 4];
    input.read_exact(&mut len).ok()?;

    let mut packet = vec![0u8; u32::from_be_bytes(len) as usize];
    input.read_exact(&mut packet).ok()?;
    Some(packet)
}

fn write_packet(output: &mut impl Write, packet: &[u8]) -> io::Result<()> {
    let len = u32::try_from(packet.len()).map_err(|_| io::ErrorKind::InvalidData)?;
    output.write_all(&len.to_be_bytes())?;
    output.write_all(packet)?;
    output.flush()
}

fn encode(result: Result<Pixels, Error>) -> Vec<u8> {
    match result {
        Ok(pixels) => {
            let mut reply = Vec::with_capacity(18 + pixels.data.len());
            reply.push(b'O');
            for n in [pixels.width, pixels.height, pixels.channels, pixels.ppi.unwrap_or(0)] {
                reply.extend_from_slice(&n.to_be_bytes());
            }
            reply.push(match pixels.colorspace {
                ColorSpace::Gray => b'G',
                ColorSpace::Srgb => b'R',
                ColorSpace::Sycc => b'Y',
                ColorSpace::Unspecified => b'U',
            });
            reply.extend_from_slice(&pixels.data);
            reply
        }
        Err(error) => [b"E".as_slice(), error_name(error).as_bytes()].concat(),
    }
}

fn error_name(error: Error) -> &'static str {
    match error {
        Error::InvalidWsq => "invalid_wsq",
        Error::InvalidJpegl => "invalid_jpegl",
        Error::InvalidJp2 => "invalid_jp2",
        Error::NotLosslessJpeg => "not_lossless_jpeg",
        Error::UnsupportedColorspace => "unsupported_colorspace",
        Error::TooLarge => "too_large",
        Error::InvalidDimensions => "invalid_dimensions",
        Error::PngEncodeFailed => "png_encode_failed",
    }
}

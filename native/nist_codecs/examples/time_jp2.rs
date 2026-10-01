//! Times `jp2::decode` on each file given, in a release build:
//!
//!     cargo run --release --no-default-features --example time_jp2 -- FILE...
//!
//! and prints what the codestream's SIZ and COD markers declare, which is
//! what decides the cost (docs/jp2.md, "Slow inputs").

fn main() {
    for path in std::env::args().skip(1) {
        let data = std::fs::read(&path).unwrap();
        let start = std::time::Instant::now();
        let result = nist_codecs::jp2::decode(&data);
        let seconds = start.elapsed().as_secs_f64();
        let name = path.rsplit('/').next().unwrap();
        println!(
            "{name:<20.20} {:>6} B  {:>6.2} s  {:<28}  {}",
            data.len(),
            seconds,
            match result {
                Ok(p) => format!("{} x {} x {}", p.width, p.height, p.channels),
                Err(e) => format!("{e:?}"),
            },
            markers(&data)
        );
    }
}

/// SIZ: image and tile size and offset, and each component's subsampling;
/// COD: decomposition levels and code-block size.
fn markers(data: &[u8]) -> String {
    let u16_at = |i: usize| data.get(i..i + 2).map(|b| u16::from_be_bytes([b[0], b[1]]) as u32);
    let u32_at = |i: usize| data.get(i..i + 4).map(|b| u32::from_be_bytes([b[0], b[1], b[2], b[3]]));
    let mut out = String::new();

    if let Some(siz) = data.windows(2).position(|w| w == [0xFF, 0x51]) {
        let f = |k: usize| u32_at(siz + 6 + 4 * k).unwrap_or(0);
        let (xsiz, ysiz, x0, y0, xt, yt, xt0, yt0) = (f(0), f(1), f(2), f(3), f(4), f(5), f(6), f(7));
        let n = u16_at(siz + 38).unwrap_or(0) as usize;
        let tiles_x = (xsiz - xt0.min(xsiz)).div_ceil(xt.max(1));
        let tiles_y = (ysiz - yt0.min(ysiz)).div_ceil(yt.max(1));
        out += &format!("size {xsiz}x{ysiz} off {x0},{y0} tile {xt}x{yt} ({tiles_x}x{tiles_y}) sub");
        for c in 0..n.min(4) {
            let b = |k: usize| data.get(siz + 40 + 3 * c + k).copied().unwrap_or(0);
            out += &format!(" {}x{}", b(1), b(2));
        }
    }
    if let Some(cod) = data.windows(2).position(|w| w == [0xFF, 0x52]) {
        let b = |k: usize| data.get(cod + k).copied().unwrap_or(0);
        out += &format!(
            "  prog {} levels {} cblk {}x{}",
            b(5),
            b(9),
            1u32 << (b(10) + 2).min(31),
            1u32 << (b(11) + 2).min(31)
        );
    }
    out
}

# Regression inputs

Inputs that crashed a decoder under fuzzing, kept so that they stay errors.
`NistView.DecoderTest` decodes every file in `<format>/` through the
`nist_decode` helper and expects `{:error, _}`.

Nothing here contains image data from a real print. An input that came from
a fuzz corpus (mutated BioCTS samples) is first shrunk with
`fuzz/minimise.py`, which keeps the crash, removes what it can and zeroes
the rest; what remains is markers, lengths and table bytes.

## wsq

Each of these crashes NBIS's WSQ decoder (`native/nbis_ref`, the `nbis_wsq`
fuzz target, with AddressSanitizer). The Rust decoder returns an error.
Root causes are in `docs/wsq-port.md`.

| File | In NBIS | From |
|---|---|---|
| `nbis-double-free-after-truncated-transform-table.wsq` | double free of the filter arrays in `free_wsq_decoder_resources` | fuzzing, minimised from 1,832 bytes |
| `nbis-heap-overflow-in-transform-table.wsq` | heap buffer overflow in `getc_transform_table` (filter length 0) | fuzzing, minimised from 3,794 bytes |
| `nbis-null-write-in-bit-reader.wsq` | write through a null pointer in `getc_nextbits_wsq` (a marker where one more bit of a longer read is due) | fuzzing, minimised from 2,547 bytes; 3 bytes of block data left |
| `nbis-out-of-bounds-in-unquantize.wsq` | out-of-bounds access in `unquantize` (a width of 64,000: subband positions above 32,767 wrap in its `short`s) | fuzzing, minimised from 20,731 bytes; no block data left |
| `nbis-negative-size-comment-length-1.wsq` | `memcpy` with a size of −1 in `getc_bytes` (a comment segment of length 1) | made by hand: six bytes |
| `nbis-global-overflow-huffman-table-id.wsq` | global buffer overflow in `getc_huffman_table_wsq` (table id 8) | made from `test/fixtures/synthetic.wsq`: its headers and tables with the id changed |

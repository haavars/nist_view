/*
 * Minimal NBIS WSQ decoder driver for comparing builds (docs/wsq-port.md).
 * Decodes each file given and writes the pixels to <file>.<$TAG>.raw.
 *
 *   cd native/nbis_ref
 *   clang -O2 -ffp-contract=off -w -D__NBISLE__ -include c/quiet.h \
 *     -Ivendor/nbis/include vendor/nbis/src/{wsq,jpegl,fet,ioutil,util}/*.c \
 *     c/glue.c ../../scripts/dwsq_min.c -o dwsq_off
 *   TAG=off ./dwsq_off OUT_DIR/*.wsq
 */
#include <stdio.h>
#include <stdlib.h>
int wsq_decode_mem(unsigned char **, int *, int *, int *, int *, int *, unsigned char *, const int);
int main(int argc, char **argv) {
  for (int a = 1; a < argc; a++) {
    FILE *f = fopen(argv[a], "rb"); fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
    unsigned char *buf = malloc(n); fread(buf, 1, n, f); fclose(f);
    unsigned char *out; int w, h, d, ppi, lossy;
    int ret = wsq_decode_mem(&out, &w, &h, &d, &ppi, &lossy, buf, (int)n);
    if (ret) { printf("%s ERR %d\n", argv[a], ret); continue; }
    char path[4096]; snprintf(path, sizeof path, "%s.%s.raw", argv[a], getenv("TAG"));
    FILE *o = fopen(path, "wb"); fwrite(out, 1, (size_t)w * h, o); fclose(o);
    free(out); free(buf);
  }
  return 0;
}

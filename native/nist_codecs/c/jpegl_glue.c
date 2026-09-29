/*
 * Wraps the NBIS lossless JPEG decoder: returns interleaved 8-bit pixels
 * instead of NBIS's separate component planes.
 */

#include <stdlib.h>
#include <jpegl.h>

/* Returned when the image uses something this wrapper does not handle. */
#define NIST_CODECS_JPEGL_UNSUPPORTED -1000
#define NIST_CODECS_JPEGL_NOMEM -1001

/*
 * Decodes `idata` into `*odata` (w * h * channels bytes, row-major,
 * interleaved), which the caller frees with free(). Subsampled components
 * are upsampled by pixel replication. Returns 0, a negative NBIS error
 * code, or one of the codes above.
 */
int nist_codecs_jpegl_decode(unsigned char *idata, int ilen, unsigned char **odata,
                             int *ow, int *oh, int *ochannels, int *oppi)
{
   IMG_DAT *img;
   int lossy, ret, w, h, n, c, x, y;
   unsigned char *out;

   if ((ret = jpegl_decode_mem(&img, &lossy, idata, ilen)))
      return ret;

   w = img->max_width;
   h = img->max_height;
   n = img->n_cmpnts;

   if (w <= 0 || h <= 0 || n < 1 || n > 4 || img->cmpnt_depth != 8) {
      free_IMG_DAT(img, FREE_IMAGE);
      return NIST_CODECS_JPEGL_UNSUPPORTED;
   }

   for (c = 0; c < n; c++) {
      if (img->samp_width[c] <= 0 || img->samp_height[c] <= 0 ||
          img->samp_width[c] > w || img->samp_height[c] > h) {
         free_IMG_DAT(img, FREE_IMAGE);
         return NIST_CODECS_JPEGL_UNSUPPORTED;
      }
   }

   out = (unsigned char *)malloc((size_t)w * (size_t)h * (size_t)n);
   if (out == NULL) {
      free_IMG_DAT(img, FREE_IMAGE);
      return NIST_CODECS_JPEGL_NOMEM;
   }

   for (c = 0; c < n; c++) {
      int sw = img->samp_width[c];
      int sh = img->samp_height[c];
      unsigned char *plane = img->image[c];

      for (y = 0; y < h; y++) {
         int sy = (int)((long long)y * sh / h);
         for (x = 0; x < w; x++) {
            int sx = (int)((long long)x * sw / w);
            out[((size_t)y * w + x) * n + c] = plane[(size_t)sy * sw + sx];
         }
      }
   }

   *odata = out;
   *ow = w;
   *oh = h;
   *ochannels = n;
   *oppi = img->ppi;

   free_IMG_DAT(img, FREE_IMAGE);
   return 0;
}

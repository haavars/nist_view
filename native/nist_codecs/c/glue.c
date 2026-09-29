/* Definitions that NBIS expects the application to provide. */

#include <stdarg.h>
#include <stdio.h>

#undef fprintf

/* Verbosity for NBIS's own diagnostics; 0 keeps them quiet. */
int debug = 0;

/* Drops NBIS's diagnostics on stdout and stderr (see quiet.h). */
int nist_codecs_fprintf(FILE *stream, const char *format, ...)
{
   va_list args;
   int written;

   if (stream == stderr || stream == stdout)
      return 0;

   va_start(args, format);
   written = vfprintf(stream, format, args);
   va_end(args);

   return written;
}

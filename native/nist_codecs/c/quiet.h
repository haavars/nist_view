/*
 * Force-included into every NBIS source file (see build.rs). NBIS reports
 * errors by printing to stderr; inside the BEAM that is noise in the
 * application's output, and the error code it returns is enough.
 */
#ifndef NIST_CODECS_QUIET_H
#define NIST_CODECS_QUIET_H

#include <stdio.h>

int nist_codecs_fprintf(FILE *stream, const char *format, ...);

#define fprintf nist_codecs_fprintf

#endif

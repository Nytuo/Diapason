#ifndef RUNNER_PCM_CAPTURE_H_
#define RUNNER_PCM_CAPTURE_H_

#include <flutter_linux/flutter_linux.h>

typedef struct _PcmCapture PcmCapture;

PcmCapture* pcm_capture_register(FlBinaryMessenger* messenger);

void pcm_capture_free(PcmCapture* self);

#endif  // RUNNER_PCM_CAPTURE_H_

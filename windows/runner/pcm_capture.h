#ifndef RUNNER_PCM_CAPTURE_H_
#define RUNNER_PCM_CAPTURE_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

#include <memory>

class PcmCaptureImpl;

class PcmCapture {
 public:
  static constexpr UINT kPcmReadyMessage = WM_APP + 0x51;

  static std::unique_ptr<PcmCapture> Register(
      flutter::BinaryMessenger* messenger, HWND host_window);

  ~PcmCapture();

  void Drain();

 private:
  explicit PcmCapture(std::unique_ptr<PcmCaptureImpl> impl);
  std::unique_ptr<PcmCaptureImpl> impl_;
};

#endif  // RUNNER_PCM_CAPTURE_H_

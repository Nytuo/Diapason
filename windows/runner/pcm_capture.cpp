#include "pcm_capture.h"

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <deque>
#include <mutex>
#include <vector>

#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#include <miniaudio.h>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr size_t kMaxQueuedBuffers = 128;

struct AudioBlock {
  std::vector<float> samples;
};

}  // namespace

class PcmCaptureImpl {
 public:
  PcmCaptureImpl(flutter::BinaryMessenger* messenger, HWND host_window)
      : host_window_(host_window) {
    method_channel_ =
        std::make_unique<flutter::MethodChannel<EncodableValue>>(
            messenger, "fr.nytuo.diapason/pcm_capture",
            &flutter::StandardMethodCodec::GetInstance());
    method_channel_->SetMethodCallHandler(
        [this](const auto& call, auto result) {
          if (call.method_name() == "start") {
            result->Success(EncodableValue(Start()));
          } else if (call.method_name() == "stop") {
            Stop();
            result->Success();
          } else {
            result->NotImplemented();
          }
        });

    event_channel_ =
        std::make_unique<flutter::EventChannel<EncodableValue>>(
            messenger, "fr.nytuo.diapason/pcm_capture_data",
            &flutter::StandardMethodCodec::GetInstance());
    event_channel_->SetStreamHandler(
        std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
            [this](const auto*, auto&& events)
                -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
              sink_ = std::move(events);
              return nullptr;
            },
            [this](const auto*)
                -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
              sink_.reset();
              return nullptr;
            }));
  }

  ~PcmCaptureImpl() { Stop(); }

  bool Start() {
    if (running_) return true;

    if (!TryInit(true) && !TryInit(false)) {
      return false;
    }
    channels_ = static_cast<int>(device_.capture.channels);
    sample_rate_ = static_cast<int>(device_.sampleRate);

    if (ma_device_start(&device_) != MA_SUCCESS) {
      ma_device_uninit(&device_);
      return false;
    }
    running_ = true;
    return true;
  }

  bool TryInit(bool process_scoped) {
    ma_device_config config = ma_device_config_init(ma_device_type_loopback);
    config.capture.format = ma_format_f32;
    config.capture.channels = 0;
    config.sampleRate = 0;
    config.dataCallback = &PcmCaptureImpl::DataCallback;
    config.pUserData = this;
    if (process_scoped) {
      config.wasapi.loopbackProcessID = GetCurrentProcessId();
      config.wasapi.loopbackProcessExclude = MA_FALSE;
    }
    return ma_device_init(nullptr, &config, &device_) == MA_SUCCESS;
  }

  void Stop() {
    if (!running_) return;
    running_ = false;
    ma_device_uninit(&device_);
    std::lock_guard<std::mutex> lock(mutex_);
    queue_.clear();
  }

  void Drain() {
    if (!sink_) return;
    std::deque<AudioBlock> pending;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      pending.swap(queue_);
    }
    for (auto& block : pending) {
      EncodableMap map{
          {EncodableValue("pcm"), EncodableValue(std::move(block.samples))},
          {EncodableValue("sampleRate"), EncodableValue(sample_rate_)},
          {EncodableValue("channels"), EncodableValue(channels_)},
      };
      sink_->Success(EncodableValue(std::move(map)));
    }
  }

 private:
  static void DataCallback(ma_device* device, void* /*output*/,
                           const void* input, ma_uint32 frame_count) {
    auto* self = static_cast<PcmCaptureImpl*>(device->pUserData);
    if (input == nullptr || frame_count == 0) return;

    const auto* in = static_cast<const float*>(input);
    const size_t count =
        static_cast<size_t>(frame_count) * device->capture.channels;

    AudioBlock block;
    block.samples.assign(in, in + count);

    {
      std::lock_guard<std::mutex> lock(self->mutex_);
      if (self->queue_.size() >= kMaxQueuedBuffers) {
        self->queue_.pop_front();
      }
      self->queue_.push_back(std::move(block));
    }
    PostMessage(self->host_window_, PcmCapture::kPcmReadyMessage, 0, 0);
  }

  HWND host_window_;
  ma_device device_{};
  bool running_ = false;
  int channels_ = 2;
  int sample_rate_ = 44100;

  std::mutex mutex_;
  std::deque<AudioBlock> queue_;

  std::unique_ptr<flutter::MethodChannel<EncodableValue>> method_channel_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> event_channel_;
  std::unique_ptr<flutter::EventSink<EncodableValue>> sink_;
};

std::unique_ptr<PcmCapture> PcmCapture::Register(
    flutter::BinaryMessenger* messenger, HWND host_window) {
  if (messenger == nullptr || host_window == nullptr) return nullptr;
  return std::unique_ptr<PcmCapture>(
      new PcmCapture(std::make_unique<PcmCaptureImpl>(messenger, host_window)));
}

PcmCapture::PcmCapture(std::unique_ptr<PcmCaptureImpl> impl)
    : impl_(std::move(impl)) {}

PcmCapture::~PcmCapture() = default;

void PcmCapture::Drain() { impl_->Drain(); }

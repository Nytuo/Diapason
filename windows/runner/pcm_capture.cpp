#include "pcm_capture.h"

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>

#include <atomic>
#include <cstdio>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// Process loopback (Windows 10 2004+).  Provide fallback definitions so the
// code compiles even with an older SDK that lacks the header.
#if __has_include(<audioclientactivationparams.h>)
#include <audioclientactivationparams.h>
#else
#define VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK L"VAD\\Process_Loopback"

typedef enum AUDIOCLIENT_ACTIVATION_TYPE {
  AUDIOCLIENT_ACTIVATION_TYPE_DEFAULT,
  AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK
} AUDIOCLIENT_ACTIVATION_TYPE;

typedef enum PROCESS_LOOPBACK_MODE {
  PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE,
  PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE
} PROCESS_LOOPBACK_MODE;

typedef struct AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS {
  DWORD TargetProcessId;
  PROCESS_LOOPBACK_MODE ProcessLoopbackMode;
} AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS;

typedef struct AUDIOCLIENT_ACTIVATION_PARAMS {
  AUDIOCLIENT_ACTIVATION_TYPE ActivationType;
  union {
    AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS ProcessLoopbackParams;
  };
} AUDIOCLIENT_ACTIVATION_PARAMS;
#endif

// IEEE-float subtype GUID for WAVEFORMATEXTENSIBLE
static const GUID kSubTypeFloat = {
    0x00000003, 0x0000, 0x0010,
    {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}};

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

constexpr size_t kMaxQueuedBuffers = 128;

struct AudioBlock {
  std::vector<float> samples;
};

// Minimal COM implementation of IActivateAudioInterfaceCompletionHandler.
class CompletionHandler : public IActivateAudioInterfaceCompletionHandler {
 public:
  CompletionHandler() { event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr); }

  // IUnknown
  ULONG STDMETHODCALLTYPE AddRef() override {
    return InterlockedIncrement(&ref_count_);
  }
  ULONG STDMETHODCALLTYPE Release() override {
    ULONG count = InterlockedDecrement(&ref_count_);
    if (count == 0) delete this;
    return count;
  }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                           void** ppv) override {
    if (riid == __uuidof(IUnknown) ||
        riid == __uuidof(IActivateAudioInterfaceCompletionHandler)) {
      *ppv = static_cast<IActivateAudioInterfaceCompletionHandler*>(this);
      AddRef();
      return S_OK;
    }
    if (riid == __uuidof(IAgileObject)) {
      *ppv = static_cast<IUnknown*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }

  // IActivateAudioInterfaceCompletionHandler
  STDMETHOD(ActivateCompleted)
  (IActivateAudioInterfaceAsyncOperation* op) override {
    HRESULT hr_activate = E_FAIL;
    ComPtr<IUnknown> unknown;
    HRESULT hr = op->GetActivateResult(&hr_activate, &unknown);
    if (SUCCEEDED(hr) && SUCCEEDED(hr_activate) && unknown) {
      unknown.As(&client_);
    }
    result_ = SUCCEEDED(hr) ? hr_activate : hr;
    SetEvent(event_);
    return S_OK;
  }

  HANDLE event_ = nullptr;
  ComPtr<IAudioClient> client_;
  HRESULT result_ = E_FAIL;

 private:
  ~CompletionHandler() {
    if (event_) CloseHandle(event_);
  }
  ULONG ref_count_ = 1;
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
            auto err = Start();
            if (err.empty()) {
              result->Success(EncodableValue(true));
            } else {
              result->Success(EncodableValue(err));
            }
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
                -> std::unique_ptr<
                    flutter::StreamHandlerError<EncodableValue>> {
              sink_ = std::move(events);
              return nullptr;
            },
            [this](const auto*)
                -> std::unique_ptr<
                    flutter::StreamHandlerError<EncodableValue>> {
              sink_.reset();
              return nullptr;
            }));
  }

  ~PcmCaptureImpl() { Stop(); }

  static std::string HrMsg(const char* step, HRESULT hr) {
    char buf[256];
    snprintf(buf, sizeof(buf), "%s failed: HRESULT 0x%08lX", step,
             static_cast<unsigned long>(hr));
    return buf;
  }

  // Returns empty string on success, error description on failure.
  std::string Start() {
    if (running_) return {};

    // --- Activate process-scoped loopback via WASAPI ---
    AUDIOCLIENT_ACTIVATION_PARAMS act_params{};
    act_params.ActivationType =
        AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    act_params.ProcessLoopbackParams.TargetProcessId = GetCurrentProcessId();
    act_params.ProcessLoopbackParams.ProcessLoopbackMode =
        PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;

    PROPVARIANT pv{};
    pv.vt = VT_BLOB;
    pv.blob.cbSize = sizeof(act_params);
    pv.blob.pBlobData = reinterpret_cast<BYTE*>(&act_params);

    auto* handler = new CompletionHandler();
    ComPtr<IActivateAudioInterfaceAsyncOperation> async_op;
    HRESULT hr = ActivateAudioInterfaceAsync(
        VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient), &pv,
        handler, &async_op);
    if (FAILED(hr)) {
      handler->Release();
      return HrMsg("ActivateAudioInterfaceAsync", hr);
    }

    DWORD wait = WaitForSingleObject(handler->event_, 5000);
    if (wait != WAIT_OBJECT_0) {
      handler->Release();
      return "ActivateAudioInterfaceAsync timed out";
    }
    if (FAILED(handler->result_)) {
      auto msg = HrMsg("ActivateCompleted", handler->result_);
      handler->Release();
      return msg;
    }
    if (!handler->client_) {
      handler->Release();
      return "ActivateCompleted returned null client";
    }

    audio_client_ = handler->client_;
    handler->Release();

    // IAudioClient was created on MTA (completion handler thread).
    // All further calls (GetMixFormat, Initialize, GetService, Start)
    // must happen on MTA too — the capture thread handles this.
    init_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    running_ = true;
    capture_thread_ = std::thread(&PcmCaptureImpl::CaptureLoop, this);

    WaitForSingleObject(init_event_, 5000);
    CloseHandle(init_event_);
    init_event_ = nullptr;

    if (!init_error_.empty()) {
      running_ = false;
      capture_thread_.join();
      capture_client_.Reset();
      audio_client_.Reset();
      auto err = std::move(init_error_);
      init_error_.clear();
      return err;
    }

    return {};
  }

  void Stop() {
    if (!running_) return;
    running_ = false;
    if (capture_thread_.joinable()) capture_thread_.join();
    if (audio_client_) audio_client_->Stop();
    capture_client_.Reset();
    audio_client_.Reset();
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
  void CaptureLoop() {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);

    // --- Initialize audio client on MTA thread ---
    // Process loopback IAudioClient may not implement GetMixFormat on
    // recent Windows 11 builds.  Specify a float32 format directly and
    // let WASAPI convert via AUTOCONVERTPCM.
    WAVEFORMATEXTENSIBLE wfx{};
    wfx.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    wfx.Format.nChannels = 2;
    wfx.Format.nSamplesPerSec = 48000;
    wfx.Format.wBitsPerSample = 32;
    wfx.Format.nBlockAlign =
        wfx.Format.nChannels * wfx.Format.wBitsPerSample / 8;
    wfx.Format.nAvgBytesPerSec =
        wfx.Format.nSamplesPerSec * wfx.Format.nBlockAlign;
    wfx.Format.cbSize =
        sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    wfx.Samples.wValidBitsPerSample = 32;
    wfx.dwChannelMask = SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT;
    wfx.SubFormat = kSubTypeFloat;

    channels_ = wfx.Format.nChannels;
    sample_rate_ = wfx.Format.nSamplesPerSec;
    bits_per_sample_ = 32;
    is_float_ = true;

    // Process loopback still requires AUDCLNT_STREAMFLAGS_LOOPBACK in
    // Initialize (the activation params only select the target process).
    // GetMixFormat returns E_NOTIMPL on recent Win 11 builds, so we
    // specify a format and let WASAPI convert via AUTOCONVERTPCM.
    const DWORD kLoopback = AUDCLNT_STREAMFLAGS_LOOPBACK;
    const DWORD kAutoConvert = AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                               AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;

    HRESULT hr = audio_client_->Initialize(
        AUDCLNT_SHAREMODE_SHARED, kLoopback | kAutoConvert, 0, 0,
        &wfx.Format, nullptr);
    if (FAILED(hr)) {
      // Retry without AUTOCONVERTPCM in case it's not supported.
      hr = audio_client_->Initialize(AUDCLNT_SHAREMODE_SHARED, kLoopback,
                                     0, 0, &wfx.Format, nullptr);
    }
    if (FAILED(hr)) {
      init_error_ = HrMsg("IAudioClient::Initialize", hr);
      SetEvent(init_event_);
      CoUninitialize();
      return;
    }

    hr = audio_client_->GetService(IID_PPV_ARGS(&capture_client_));
    if (FAILED(hr)) {
      init_error_ = HrMsg("GetService(IAudioCaptureClient)", hr);
      SetEvent(init_event_);
      CoUninitialize();
      return;
    }

    hr = audio_client_->Start();
    if (FAILED(hr)) {
      capture_client_.Reset();
      init_error_ = HrMsg("IAudioClient::Start", hr);
      SetEvent(init_event_);
      CoUninitialize();
      return;
    }

    SetEvent(init_event_);

    // --- Capture loop ---
    while (running_) {
      UINT32 packet_size = 0;
      hr = capture_client_->GetNextPacketSize(&packet_size);
      if (FAILED(hr)) break;

      while (packet_size > 0) {
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        hr = capture_client_->GetBuffer(&data, &frames, &flags, nullptr,
                                        nullptr);
        if (FAILED(hr)) break;

        if (running_ && frames > 0 && data != nullptr) {
          const size_t sample_count =
              static_cast<size_t>(frames) * channels_;
          AudioBlock block;
          block.samples.resize(sample_count);

          if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
            std::fill(block.samples.begin(), block.samples.end(), 0.0f);
          } else if (is_float_ && bits_per_sample_ == 32) {
            const auto* src = reinterpret_cast<const float*>(data);
            std::copy(src, src + sample_count, block.samples.begin());
          } else if (!is_float_ && bits_per_sample_ == 16) {
            const auto* src = reinterpret_cast<const int16_t*>(data);
            for (size_t i = 0; i < sample_count; i++)
              block.samples[i] = src[i] / 32768.0f;
          }

          {
            std::lock_guard<std::mutex> lock(mutex_);
            if (queue_.size() >= kMaxQueuedBuffers) queue_.pop_front();
            queue_.push_back(std::move(block));
          }
          PostMessage(host_window_, PcmCapture::kPcmReadyMessage, 0, 0);
        }

        capture_client_->ReleaseBuffer(frames);

        if (!running_) break;
        hr = capture_client_->GetNextPacketSize(&packet_size);
        if (FAILED(hr)) break;
      }

      if (running_) Sleep(5);
    }

    CoUninitialize();
  }

  HWND host_window_;
  ComPtr<IAudioClient> audio_client_;
  ComPtr<IAudioCaptureClient> capture_client_;
  std::thread capture_thread_;
  std::atomic<bool> running_{false};
  HANDLE init_event_ = nullptr;
  std::string init_error_;
  int channels_ = 2;
  int sample_rate_ = 44100;
  int bits_per_sample_ = 32;
  bool is_float_ = true;

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

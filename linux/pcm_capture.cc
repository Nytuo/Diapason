#include "pcm_capture.h"

#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <vector>

#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#include <miniaudio.h>

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>

namespace {

constexpr size_t kMaxQueuedBuffers = 128;

struct AudioBlock {
  std::vector<float> samples;
};

}  // namespace

struct _PcmCapture {
  FlMethodChannel* method_channel = nullptr;
  FlEventChannel* event_channel = nullptr;
  bool listening = false;

  int channels = 2;
  int sample_rate = 44100;

  std::mutex mutex;
  std::deque<AudioBlock> queue;
  bool drain_scheduled = false;

  ma_device ma_device_handle{};
  bool ma_running = false;

  pw_thread_loop* pw_loop = nullptr;
  pw_context* pw_context_handle = nullptr;
  pw_core* pw_core_handle = nullptr;
  pw_registry* pw_registry_handle = nullptr;
  spa_hook registry_listener{};
  pw_stream* pw_stream_handle = nullptr;
  spa_hook stream_listener{};
  uint32_t target_node_id = SPA_ID_INVALID;
  bool pw_active = false;
};

static gboolean pcm_capture_drain(gpointer user_data);

static void pcm_enqueue(PcmCapture* self, const float* in, size_t count) {
  if (count == 0) return;
  AudioBlock block;
  block.samples.assign(in, in + count);

  bool schedule = false;
  {
    std::lock_guard<std::mutex> lock(self->mutex);
    if (self->queue.size() >= kMaxQueuedBuffers) self->queue.pop_front();
    self->queue.push_back(std::move(block));
    if (!self->drain_scheduled) {
      self->drain_scheduled = true;
      schedule = true;
    }
  }
  if (schedule) g_idle_add(pcm_capture_drain, self);
}

static gboolean pcm_capture_drain(gpointer user_data) {
  auto* self = static_cast<PcmCapture*>(user_data);

  std::deque<AudioBlock> pending;
  {
    std::lock_guard<std::mutex> lock(self->mutex);
    pending.swap(self->queue);
    self->drain_scheduled = false;
  }
  if (!self->listening) return G_SOURCE_REMOVE;

  for (auto& block : pending) {
    g_autoptr(FlValue) map = fl_value_new_map();
    fl_value_set_string_take(
        map, "pcm",
        fl_value_new_float32_list(block.samples.data(), block.samples.size()));
    fl_value_set_string_take(map, "sampleRate",
                             fl_value_new_int(self->sample_rate));
    fl_value_set_string_take(map, "channels", fl_value_new_int(self->channels));
    fl_event_channel_send(self->event_channel, map, nullptr, nullptr);
  }
  return G_SOURCE_REMOVE;
}

static void on_pw_process(void* data) {
  auto* self = static_cast<PcmCapture*>(data);
  if (self->pw_stream_handle == nullptr) return;

  pw_buffer* b = pw_stream_dequeue_buffer(self->pw_stream_handle);
  if (b == nullptr) return;

  spa_buffer* buf = b->buffer;
  const auto* samples = static_cast<const float*>(buf->datas[0].data);
  if (samples != nullptr && buf->datas[0].chunk != nullptr) {
    const uint32_t size = buf->datas[0].chunk->size;
    pcm_enqueue(self, samples, size / sizeof(float));
  }
  pw_stream_queue_buffer(self->pw_stream_handle, b);
}

static void on_pw_param_changed(void* data, uint32_t id, const spa_pod* param) {
  auto* self = static_cast<PcmCapture*>(data);
  if (param == nullptr || id != SPA_PARAM_Format) return;

  spa_audio_info info{};
  if (spa_format_parse(param, &info.media_type, &info.media_subtype) < 0) return;
  if (info.media_type != SPA_MEDIA_TYPE_audio ||
      info.media_subtype != SPA_MEDIA_SUBTYPE_raw) {
    return;
  }
  spa_format_audio_raw_parse(param, &info.info.raw);
  if (info.info.raw.rate > 0) self->sample_rate = static_cast<int>(info.info.raw.rate);
  if (info.info.raw.channels > 0) self->channels = static_cast<int>(info.info.raw.channels);
}

static const pw_stream_events kStreamEvents = {
    .version = PW_VERSION_STREAM_EVENTS,
    .param_changed = on_pw_param_changed,
    .process = on_pw_process,
};

static void pw_connect_capture(PcmCapture* self, const char* target_serial) {
  if (self->pw_stream_handle != nullptr) return;

  pw_properties* props = pw_properties_new(
      PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Capture",
      PW_KEY_MEDIA_CLASS, "Stream/Input/Audio", PW_KEY_NODE_NAME,
      "diapason-visualizer", nullptr);
  if (target_serial != nullptr) {
    pw_properties_set(props, PW_KEY_TARGET_OBJECT, target_serial);
  }

  self->pw_stream_handle =
      pw_stream_new(self->pw_core_handle, "diapason-visualizer", props);
  if (self->pw_stream_handle == nullptr) return;

  pw_stream_add_listener(self->pw_stream_handle, &self->stream_listener,
                         &kStreamEvents, self);

  uint8_t buffer[1024];
  spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
  spa_audio_info_raw raw{};
  raw.format = SPA_AUDIO_FORMAT_F32;
  const spa_pod* params[1] = {
      spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat, &raw)};

  pw_stream_connect(
      self->pw_stream_handle, PW_DIRECTION_INPUT, PW_ID_ANY,
      static_cast<pw_stream_flags>(PW_STREAM_FLAG_AUTOCONNECT |
                                   PW_STREAM_FLAG_MAP_BUFFERS |
                                   PW_STREAM_FLAG_RT_PROCESS),
      params, 1);
}

static void on_pw_registry_global(void* data, uint32_t id, uint32_t,
                                  const char* type, uint32_t,
                                  const spa_dict* props) {
  auto* self = static_cast<PcmCapture*>(data);
  if (self->pw_stream_handle != nullptr) return;
  if (props == nullptr || std::strcmp(type, PW_TYPE_INTERFACE_Node) != 0) return;

  const char* media_class = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
  if (media_class == nullptr ||
      std::strstr(media_class, "Stream/Output/Audio") == nullptr) {
    return;
  }

  char our_pid[16];
  std::snprintf(our_pid, sizeof(our_pid), "%d", static_cast<int>(getpid()));
  const char* node_pid = spa_dict_lookup(props, PW_KEY_APP_PROCESS_ID);
  const char* app_name = spa_dict_lookup(props, PW_KEY_APP_NAME);
  const bool mine = (node_pid != nullptr && std::strcmp(node_pid, our_pid) == 0) ||
                    (app_name != nullptr && std::strcmp(app_name, "Diapason") == 0);
  if (!mine) return;

  self->target_node_id = id;
  const char* serial = spa_dict_lookup(props, PW_KEY_OBJECT_SERIAL);
  pw_connect_capture(self, serial);
}

static void on_pw_registry_global_remove(void* data, uint32_t id) {
  auto* self = static_cast<PcmCapture*>(data);
  if (id != self->target_node_id) return;
  self->target_node_id = SPA_ID_INVALID;
  if (self->pw_stream_handle != nullptr) {
    spa_hook_remove(&self->stream_listener);
    pw_stream_destroy(self->pw_stream_handle);
    self->pw_stream_handle = nullptr;
  }
}

static const pw_registry_events kRegistryEvents = {
    .version = PW_VERSION_REGISTRY_EVENTS,
    .global = on_pw_registry_global,
    .global_remove = on_pw_registry_global_remove,
};

static bool pw_start(PcmCapture* self) {
  static bool pw_inited = false;
  if (!pw_inited) {
    pw_init(nullptr, nullptr);
    pw_inited = true;
  }

  self->pw_loop = pw_thread_loop_new("diapason-visualizer", nullptr);
  if (self->pw_loop == nullptr) return false;

  pw_thread_loop_lock(self->pw_loop);
  self->pw_context_handle =
      pw_context_new(pw_thread_loop_get_loop(self->pw_loop), nullptr, 0);
  if (self->pw_context_handle != nullptr) {
    self->pw_core_handle =
        pw_context_connect(self->pw_context_handle, nullptr, 0);
  }
  if (self->pw_core_handle != nullptr) {
    self->pw_registry_handle =
        pw_core_get_registry(self->pw_core_handle, PW_VERSION_REGISTRY, 0);
    pw_registry_add_listener(self->pw_registry_handle, &self->registry_listener,
                             &kRegistryEvents, self);
  }
  pw_thread_loop_unlock(self->pw_loop);

  if (self->pw_core_handle == nullptr) {
    pw_thread_loop_destroy(self->pw_loop);
    self->pw_loop = nullptr;
    if (self->pw_context_handle != nullptr) {
      pw_context_destroy(self->pw_context_handle);
      self->pw_context_handle = nullptr;
    }
    return false;
  }

  pw_thread_loop_start(self->pw_loop);
  self->pw_active = true;
  return true;
}

static void pw_stop(PcmCapture* self) {
  if (self->pw_loop == nullptr) return;

  pw_thread_loop_lock(self->pw_loop);
  if (self->pw_stream_handle != nullptr) {
    spa_hook_remove(&self->stream_listener);
    pw_stream_destroy(self->pw_stream_handle);
    self->pw_stream_handle = nullptr;
  }
  if (self->pw_registry_handle != nullptr) {
    spa_hook_remove(&self->registry_listener);
    pw_proxy_destroy(reinterpret_cast<pw_proxy*>(self->pw_registry_handle));
    self->pw_registry_handle = nullptr;
  }
  if (self->pw_core_handle != nullptr) {
    pw_core_disconnect(self->pw_core_handle);
    self->pw_core_handle = nullptr;
  }
  pw_thread_loop_unlock(self->pw_loop);

  pw_thread_loop_stop(self->pw_loop);
  if (self->pw_context_handle != nullptr) {
    pw_context_destroy(self->pw_context_handle);
    self->pw_context_handle = nullptr;
  }
  pw_thread_loop_destroy(self->pw_loop);
  self->pw_loop = nullptr;
  self->pw_active = false;
  self->target_node_id = SPA_ID_INVALID;
}

static void ma_data_callback(ma_device* device, void*, const void* input,
                             ma_uint32 frame_count) {
  auto* self = static_cast<PcmCapture*>(device->pUserData);
  if (input == nullptr || frame_count == 0) return;
  const auto* in = static_cast<const float*>(input);
  const size_t count =
      static_cast<size_t>(frame_count) * device->capture.channels;
  pcm_enqueue(self, in, count);
}

static bool ma_start(PcmCapture* self) {
  ma_device_config config = ma_device_config_init(ma_device_type_loopback);
  config.capture.format = ma_format_f32;
  config.capture.channels = 0;
  config.sampleRate = 0;
  config.dataCallback = ma_data_callback;
  config.pUserData = self;

  if (ma_device_init(nullptr, &config, &self->ma_device_handle) != MA_SUCCESS) {
    return false;
  }
  self->channels = static_cast<int>(self->ma_device_handle.capture.channels);
  self->sample_rate = static_cast<int>(self->ma_device_handle.sampleRate);

  if (ma_device_start(&self->ma_device_handle) != MA_SUCCESS) {
    ma_device_uninit(&self->ma_device_handle);
    return false;
  }
  self->ma_running = true;
  return true;
}

static void ma_stop(PcmCapture* self) {
  if (!self->ma_running) return;
  self->ma_running = false;
  ma_device_uninit(&self->ma_device_handle);
}

static bool pcm_capture_start(PcmCapture* self) {
  if (self->pw_active || self->ma_running) return true;
  if (pw_start(self)) return true;
  return ma_start(self);
}

static void pcm_capture_stop(PcmCapture* self) {
  pw_stop(self);
  ma_stop(self);
  std::lock_guard<std::mutex> lock(self->mutex);
  self->queue.clear();
}

static void method_call_cb(FlMethodChannel*, FlMethodCall* method_call,
                           gpointer user_data) {
  auto* self = static_cast<PcmCapture*>(user_data);
  const gchar* name = fl_method_call_get_name(method_call);

  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(name, "start") == 0) {
    gboolean ok = pcm_capture_start(self) ? TRUE : FALSE;
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_bool(ok)));
  } else if (g_strcmp0(name, "stop") == 0) {
    pcm_capture_stop(self);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

static FlMethodErrorResponse* event_listen_cb(FlEventChannel*, FlValue*,
                                              gpointer user_data) {
  static_cast<PcmCapture*>(user_data)->listening = true;
  return nullptr;
}

static FlMethodErrorResponse* event_cancel_cb(FlEventChannel*, FlValue*,
                                              gpointer user_data) {
  static_cast<PcmCapture*>(user_data)->listening = false;
  return nullptr;
}

PcmCapture* pcm_capture_register(FlBinaryMessenger* messenger) {
  if (messenger == nullptr) return nullptr;
  auto* self = new _PcmCapture();

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->method_channel = fl_method_channel_new(
      messenger, "fr.nytuo.diapason/pcm_capture", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->method_channel, method_call_cb,
                                            self, nullptr);

  self->event_channel = fl_event_channel_new(
      messenger, "fr.nytuo.diapason/pcm_capture_data", FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(self->event_channel, event_listen_cb,
                                       event_cancel_cb, self, nullptr);
  return self;
}

void pcm_capture_free(PcmCapture* self) {
  if (self == nullptr) return;
  pcm_capture_stop(self);
  g_clear_object(&self->method_channel);
  g_clear_object(&self->event_channel);
  delete self;
}

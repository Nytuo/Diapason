/* Example WASM plugin: two context-menu commands backed by MusicBrainz.
 *
 *  - "open": opens a MusicBrainz search for the item, and counts how often it was used in the plugin's storage.
 *  - "count": asks MusicBrainz (through the host's fetch, limited to musicbrainz.org) how many matches it has.
 */
#include "../../../sdk/c/diapason_plugin.h"

static const char *entity_for(const char *type) {
  if (dp_streq(type, "artist")) return "artist";
  if (dp_streq(type, "album")) return "release_group";
  return "recording";
}

static dp_u32 bump_counter(void) {
  char *answer = dp_host("{\"op\":\"storage.get\",\"key\":\"runs\"}");
  int runs = dp_json_int(answer, "value", 0);
  /* The value is stored as a JSON string, e.g. "value":"3". */
  char *text = dp_json_string(answer, "value");
  if (text) {
    runs = 0;
    for (char *p = text; *p >= '0' && *p <= '9'; p++) runs = runs * 10 + (*p - '0');
  }
  runs++;
  dp_buf req = {0};
  dp_append(&req, "{\"op\":\"storage.set\",\"key\":\"runs\",\"value\":\"");
  dp_append_uint(&req, (dp_u32)runs);
  dp_append(&req, "\"}");
  dp_host(req.data);
  return (dp_u32)runs;
}

static void run_open(const char *type, const char *name, dp_buf *out) {
  dp_buf url = {0};
  dp_append(&url, "https://musicbrainz.org/search?type=");
  dp_append(&url, entity_for(type));
  dp_append(&url, "&query=");
  dp_append_url_encoded(&url, name);

  dp_u32 runs = bump_counter();
  dp_buf line = {0};
  dp_append(&line, "Opening MusicBrainz for ");
  dp_append(&line, name);
  dp_append(&line, " (use #");
  dp_append_uint(&line, runs);
  dp_append(&line, ")");
  dp_log("info", line.data);

  dp_append(out, "{\"openUrl\":");
  dp_append_json_string(out, url.data);
  dp_append(out, "}");
}

static void run_count(const char *type, const char *name, dp_buf *out) {
  const char *entity = dp_streq(type, "artist") ? "artist" : "release-group";
  dp_buf req = {0};
  dp_append(&req, "{\"op\":\"http.fetch\",\"url\":\"https://musicbrainz.org/ws/2/");
  dp_append(&req, entity);
  dp_append(&req, "?fmt=json&limit=1&query=");
  dp_append_url_encoded(&req, name);
  dp_append(&req, "\",\"headers\":{\"Accept\":\"application/json\"}}");

  char *answer = dp_host(req.data);
  char *error = dp_json_string(answer, "error");
  if (error) {
    dp_error(error);
    return;
  }
  int status = dp_json_int(answer, "status", 0);
  if (status != 200) {
    dp_error("MusicBrainz did not answer");
    return;
  }
  /* The response body is a JSON string inside the host's answer; unescape it, then read its "count". */
  char *body = dp_json_string(answer, "body");
  int count = body ? dp_json_int(body, "count", -1) : -1;
  if (count < 0) {
    dp_error("Unexpected answer from MusicBrainz");
    return;
  }

  dp_buf message = {0};
  dp_append(&message, "MusicBrainz has ");
  dp_append_uint(&message, (dp_u32)count);
  dp_append(&message, count == 1 ? " match for " : " matches for ");
  dp_append(&message, name);
  dp_append(out, "{\"message\":");
  dp_append_json_string(out, message.data);
  dp_append(out, "}");
}

void plugin_handle(const char *method, const char *request, dp_buf *out) {
  if (!dp_streq(method, "command.run")) {
    dp_error("unsupported method");
    return;
  }
  char *command = dp_json_string(request, "command");
  char *type = dp_json_string(request, "type");
  char *name = dp_json_string(request, "name");
  if (!command || !type || !name || !*name) {
    dp_error("missing item");
    return;
  }
  if (dp_streq(command, "open")) {
    run_open(type, name, out);
  } else if (dp_streq(command, "count")) {
    run_count(type, name, out);
  } else {
    dp_error("unknown command");
  }
}

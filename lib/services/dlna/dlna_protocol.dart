/// Pure (network-free) pieces of the UPnP AV / DLNA media server protocol:
/// device descriptions, SOAP envelopes for the ContentDirectory service,
/// DIDL-Lite listings and SSDP datagrams. Everything here is unit-testable
/// with saved answers; [DlnaClient] does the HTTP and [SsdpDiscovery] the UDP.
library;

import 'package:xml/xml.dart';

const dlnaMediaServerDeviceType = "urn:schemas-upnp-org:device:MediaServer:1";
const dlnaContentDirectoryService = "urn:schemas-upnp-org:service:ContentDirectory:1";

/// The container every ContentDirectory has at its top.
const dlnaRootId = "0";

/// Thrown when an answer isn't what a DLNA media server would send.
class DlnaException implements Exception {
  const DlnaException(this.message);

  final String message;

  @override
  String toString() => "DlnaException: $message";
}

/// A SOAP fault carrying a UPnP error code (e.g. 701 "No such object",
/// 708 "Unsupported or invalid search criteria").
class DlnaFault extends DlnaException {
  const DlnaFault(this.code, String description) : super(description);

  final int? code;

  @override
  String toString() => "DlnaFault($code): $message";
}

/// A media server, as its device description says.
class DlnaDevice {
  const DlnaDevice({
    required this.location,
    required this.friendlyName,
    required this.udn,
    required this.controlUrl,
    this.manufacturer = "",
    this.modelName = "",
    this.modelNumber = "",
    this.iconUrl,
  });

  /// Where the description was read: what a source keeps as its address.
  final Uri location;
  final String friendlyName;
  final String udn;
  final String manufacturer;
  final String modelName;
  final String modelNumber;

  /// Where the ContentDirectory takes SOAP requests.
  final Uri controlUrl;
  final Uri? iconUrl;

  String get product => "$modelName $modelNumber".trim();

  @override
  String toString() => "DlnaDevice($friendlyName, $udn, $location)";
}

/// One `<res>` of a DIDL-Lite item.
class DidlResource {
  const DidlResource({
    required this.uri,
    required this.protocolInfo,
    this.duration,
    this.size,
    this.bitrate,
    this.sampleFrequency,
    this.bitsPerSample,
    this.channels,
  });

  final Uri uri;
  final String protocolInfo;
  final Duration? duration;
  final int? size;

  /// Bytes per second, as UPnP defines `res@bitrate`.
  final int? bitrate;
  final int? sampleFrequency;
  final int? bitsPerSample;
  final int? channels;

  List<String> get _info => protocolInfo.split(":");

  String get protocol => _info.isNotEmpty ? _info[0].trim().toLowerCase() : "";

  /// The MIME type without its parameters, lower case.
  String get mime => _info.length > 2 ? _info[2].split(";").first.trim().toLowerCase() : "";

  String get _flags => _info.length > 3 ? _info.sublist(3).join(":") : "";

  /// Converted on the fly by the server (`DLNA.ORG_CI=1`).
  bool get isConverted => _flags.split(";").any((f) => f.trim().toUpperCase() == "DLNA.ORG_CI=1");

  bool get isAudio => mime.startsWith("audio/") || mime == "application/ogg" || mime.contains("flac");
  bool get isImage => mime.startsWith("image/");

  /// Raw PCM a renderer is fed; no regular player decodes it as a file.
  bool get isRawPcm => const {"audio/l8", "audio/l16", "audio/l24", "audio/lpcm"}.contains(mime);

  bool get isHttp => protocol == "http-get" && (uri.isScheme("http") || uri.isScheme("https"));

  /// A file extension for [mime], when it names a known one.
  String? get container => switch (mime) {
    "audio/flac" || "audio/x-flac" || "application/flac" || "application/x-flac" => "flac",
    "audio/mpeg" || "audio/mp3" || "audio/x-mp3" || "audio/mpeg3" => "mp3",
    "audio/mp4" || "audio/x-m4a" || "audio/m4a" || "audio/aac" || "audio/x-aac" => "m4a",
    "audio/ogg" || "audio/x-ogg" || "application/ogg" || "audio/vorbis" => "ogg",
    "audio/opus" => "opus",
    "audio/wav" || "audio/x-wav" || "audio/wave" || "audio/vnd.wave" => "wav",
    "audio/aiff" || "audio/x-aiff" => "aiff",
    "audio/x-ms-wma" => "wma",
    "audio/x-wavpack" || "audio/wavpack" => "wv",
    "audio/x-ape" || "audio/ape" => "ape",
    "audio/x-dsf" || "audio/dsf" => "dsf",
    _ => null,
  };
}

/// A container or an item of a DIDL-Lite listing.
class DidlObject {
  DidlObject({
    required this.id,
    required this.parentId,
    required this.isContainer,
    required this.title,
    required this.upnpClass,
    this.refId,
    this.childCount,
    this.creator,
    this.artists = const [],
    this.albumArtist,
    this.album,
    this.genres = const [],
    this.trackNumber,
    this.discNumber,
    this.date,
    this.albumArtUri,
    this.resources = const [],
  });

  final String id;
  final String parentId;
  final String? refId;
  final bool isContainer;
  final String title;
  final String upnpClass;
  final int? childCount;
  final String? creator;

  /// Performers: `upnp:artist` without a role, or with a performer role.
  final List<String> artists;
  final String? albumArtist;
  final String? album;
  final List<String> genres;
  final int? trackNumber;
  final int? discNumber;
  final String? date;
  final Uri? albumArtUri;
  final List<DidlResource> resources;

  bool get isAudioItem =>
      !isContainer &&
      upnpClass.startsWith("object.item.audioItem") &&
      !upnpClass.startsWith("object.item.audioItem.audioBroadcast");

  bool get isMusicAlbum => isContainer && upnpClass.startsWith("object.container.album.musicAlbum");
  bool get isMusicArtist => isContainer && upnpClass.startsWith("object.container.person");
  bool get isMusicGenre => isContainer && upnpClass.startsWith("object.container.genre.musicGenre");
  bool get isPlaylist => isContainer && upnpClass.startsWith("object.container.playlistContainer");

  /// A container of video or pictures, never music.
  bool get isNonMusicContainer =>
      isContainer &&
      (upnpClass.startsWith("object.container.album.photoAlbum") ||
          upnpClass.startsWith("object.container.genre.movieGenre") ||
          upnpClass.startsWith("object.container.channelGroup.videoChannelGroup"));

  /// The artist to show: performers, else the creator.
  String? get displayArtist {
    if (artists.isNotEmpty) return artists.join(", ");
    final c = creator?.trim();
    return (c == null || c.isEmpty) ? null : c;
  }

  int? get year {
    final d = date;
    if (d == null || d.length < 4) return null;
    final y = int.tryParse(d.substring(0, 4));
    return (y != null && y >= 1000 && y <= 9999) ? y : null;
  }

  /// The resource to play: an original over a server-side conversion, and
  /// never raw PCM when anything else is offered. Null when none is HTTP audio.
  DidlResource? get bestAudioResource {
    final candidates = resources.where((r) => r.isHttp && r.isAudio).toList();
    if (candidates.isEmpty) return null;
    int rank(DidlResource r) => (r.isRawPcm ? 2 : 0) + (r.isConverted ? 1 : 0);
    candidates.sort((a, b) => rank(a).compareTo(rank(b)));
    return candidates.first;
  }

  /// Cover art: `upnp:albumArtURI`, else a `res` that is an image.
  Uri? get artUri => albumArtUri ?? resources.where((r) => r.isImage && r.isHttp).map((r) => r.uri).firstOrNull;
}

/// What a `Browse` or `Search` answered.
class DlnaBrowseResult {
  const DlnaBrowseResult({required this.objects, required this.numberReturned, required this.totalMatches});

  final List<DidlObject> objects;
  final int numberReturned;

  /// What the container counts; 0 when the server doesn't say.
  final int totalMatches;
}

// ---------------------------------------------------------------------------
// XML helpers

Iterable<XmlElement> _children(XmlElement e, String local) => e.childElements.where((c) => c.name.local == local);

XmlElement? _child(XmlElement e, String local) => _children(e, local).firstOrNull;

String _text(XmlElement e, String local) => _child(e, local)?.innerText.trim() ?? "";

String? _textOrNull(XmlElement e, String local) {
  final t = _text(e, local);
  return t.isEmpty ? null : t;
}

Iterable<XmlElement> _descendants(XmlNode n, String local) =>
    n.descendants.whereType<XmlElement>().where((c) => c.name.local == local);

XmlDocument _parse(String text, String what) {
  try {
    return XmlDocument.parse(text.trim());
  } on XmlException catch (e) {
    throw DlnaException("$what is not valid XML: ${e.message}");
  }
}

String escapeXml(String text) => text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");

/// Resolves an address a description or listing names. A path without a
/// scheme is on [base]'s origin, with or without its leading slash (older
/// devices leave it out).
Uri? resolveDlnaUrl(Uri base, String named) {
  final t = named.trim();
  if (t.isEmpty || t.contains(RegExp(r"\s"))) return null;
  final parsed = Uri.tryParse(t);
  if (parsed == null) return null;
  if (parsed.hasScheme) return parsed;
  return base.replace(path: "", query: null, fragment: null).resolve(t.startsWith("/") ? t : "/$t");
}

// ---------------------------------------------------------------------------
// Device description

/// Reads a device description. Throws [DlnaException] when it doesn't
/// describe a media server with a ContentDirectory.
DlnaDevice parseDeviceDescription(String xml, Uri location) {
  final doc = _parse(xml, "The device description");
  final device = _descendants(
    doc,
    "device",
  ).where((d) => _text(d, "deviceType").contains(":device:MediaServer:")).firstOrNull;
  if (device == null) throw const DlnaException("Not a UPnP media server description.");

  final urlBase = _descendants(doc, "URLBase").firstOrNull?.innerText.trim();
  final base = (urlBase != null && urlBase.isNotEmpty) ? (Uri.tryParse(urlBase) ?? location) : location;

  final service = _descendants(
    device,
    "service",
  ).where((s) => _text(s, "serviceType").startsWith("urn:schemas-upnp-org:service:ContentDirectory:")).firstOrNull;
  final control = service == null ? null : resolveDlnaUrl(base, _text(service, "controlURL"));
  if (control == null) throw const DlnaException("The media server has no ContentDirectory service.");

  Uri? icon;
  final icons = _descendants(device, "icon").toList()
    ..sort((a, b) => (int.tryParse(_text(b, "width")) ?? 0).compareTo(int.tryParse(_text(a, "width")) ?? 0));
  for (final i in icons) {
    if (_text(i, "mimetype").contains("png") || _text(i, "mimetype").contains("jpeg")) {
      icon = resolveDlnaUrl(base, _text(i, "url"));
      if (icon != null) break;
    }
  }

  final name = _text(device, "friendlyName");
  return DlnaDevice(
    location: location,
    friendlyName: name.isEmpty ? (location.host) : name,
    udn: _text(device, "UDN"),
    manufacturer: _text(device, "manufacturer"),
    modelName: _text(device, "modelName"),
    modelNumber: _text(device, "modelNumber"),
    controlUrl: control,
    iconUrl: icon,
  );
}

// ---------------------------------------------------------------------------
// SOAP

String soapActionHeader(String action) => '"$dlnaContentDirectoryService#$action"';

/// A SOAP envelope for one ContentDirectory action. [args] are written in
/// order and XML-escaped.
String buildSoapEnvelope(String action, Map<String, String> args) {
  final body = args.entries.map((e) => "<${e.key}>${escapeXml(e.value)}</${e.key}>").join();
  return '<?xml version="1.0" encoding="utf-8"?>'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      '<s:Body><u:$action xmlns:u="$dlnaContentDirectoryService">$body</u:$action></s:Body>'
      '</s:Envelope>';
}

Map<String, String> browseArgs(
  String objectId, {
  bool metadata = false,
  int start = 0,
  int count = 200,
  String filter = "*",
  String sort = "",
}) => {
  "ObjectID": objectId,
  "BrowseFlag": metadata ? "BrowseMetadata" : "BrowseDirectChildren",
  "Filter": filter,
  "StartingIndex": "$start",
  "RequestedCount": "$count",
  "SortCriteria": sort,
};

Map<String, String> searchArgs(
  String containerId,
  String criteria, {
  int start = 0,
  int count = 200,
  String filter = "*",
  String sort = "",
}) => {
  "ContainerID": containerId,
  "SearchCriteria": criteria,
  "Filter": filter,
  "StartingIndex": "$start",
  "RequestedCount": "$count",
  "SortCriteria": sort,
};

/// A quoted string for a search criteria (UPnP escapes `"` and `\`).
String searchLiteral(String value) => '"${value.replaceAll(r"\", r"\\").replaceAll('"', r'\"')}"';

/// Criteria for objects of a class, optionally whose title contains [term].
String searchCriteria(String upnpClass, {bool derived = true, String? term}) {
  final cls = "upnp:class ${derived ? "derivedfrom" : "="} ${searchLiteral(upnpClass)}";
  if (term == null || term.trim().isEmpty) return cls;
  return "$cls and dc:title contains ${searchLiteral(term.trim())}";
}

/// The UPnP error in a SOAP fault body, or null when it isn't one.
DlnaFault? parseFault(String body) {
  XmlDocument doc;
  try {
    doc = XmlDocument.parse(body.trim());
  } on XmlException {
    return null;
  }
  if (_descendants(doc, "Fault").isEmpty) return null;
  final code = int.tryParse(_descendants(doc, "errorCode").firstOrNull?.innerText.trim() ?? "");
  final description =
      _descendants(doc, "errorDescription").firstOrNull?.innerText.trim() ??
      _descendants(doc, "faultstring").firstOrNull?.innerText.trim() ??
      "UPnP error";
  return DlnaFault(code, description);
}

/// The answer of `Browse` or `Search`.
/// Relative `res`/art addresses resolve against [base] (the control URL).
DlnaBrowseResult parseBrowseResponse(String soap, {Uri? base}) {
  final doc = _parse(soap, "The media server's answer");
  final fault = parseFault(soap);
  if (fault != null) throw fault;
  final result = _descendants(doc, "Result").firstOrNull;
  if (result == null) throw const DlnaException("The media server's answer has no listing.");
  final objects = parseDidl(result.innerText, base: base);
  final returned = int.tryParse(_descendants(doc, "NumberReturned").firstOrNull?.innerText.trim() ?? "");
  final total = int.tryParse(_descendants(doc, "TotalMatches").firstOrNull?.innerText.trim() ?? "") ?? 0;
  return DlnaBrowseResult(objects: objects, numberReturned: returned ?? objects.length, totalMatches: total);
}

/// The capabilities `GetSearchCapabilities` answered: an empty set when the
/// server can't search, `{"*"}` when it searches on anything.
Set<String> parseSearchCapabilities(String soap) {
  final doc = _parse(soap, "The media server's answer");
  final caps = _descendants(doc, "SearchCaps").firstOrNull?.innerText ?? "";
  return caps.split(",").map((c) => c.trim()).where((c) => c.isNotEmpty).toSet();
}

// ---------------------------------------------------------------------------
// DIDL-Lite

/// Prefixes some servers use without declaring them.
const _knownPrefixes = {
  "dc": "http://purl.org/dc/elements/1.1/",
  "upnp": "urn:schemas-upnp-org:metadata-1-0/upnp/",
  "dlna": "urn:schemas-dlna-org:metadata-1-0/",
  "sec": "http://www.sec.co.kr/",
  "pv": "http://www.pv.com/pvns/",
  "av": "urn:schemas-sony-com:av",
};

String _declareMissingPrefixes(String didl) {
  final start = didl.indexOf("<DIDL-Lite");
  if (start < 0) return didl;
  final open = start + "<DIDL-Lite".length;
  final end = didl.indexOf(">", open);
  if (end < 0) return didl;
  final root = didl.substring(open, end);
  final missing = _knownPrefixes.entries
      .where((p) => !root.contains("xmlns:${p.key}=") && RegExp("(<|/|\\s)${p.key}:").hasMatch(didl))
      .map((p) => ' xmlns:${p.key}="${p.value}"')
      .join();
  if (missing.isEmpty) return didl;
  return didl.substring(0, open) + missing + didl.substring(open);
}

Duration? parseDidlDuration(String? text) {
  if (text == null) return null;
  final parts = text.trim().split(":");
  if (parts.length != 3) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final secParts = parts[2].split(".");
  final s = int.tryParse(secParts[0]);
  if (h == null || m == null || s == null || m > 59 || s > 59) return null;
  var ms = 0;
  if (secParts.length > 1) {
    final digits = RegExp(r"^\d+").stringMatch(secParts[1]) ?? "";
    ms = int.tryParse(digits.padRight(3, "0").substring(0, 3)) ?? 0;
  }
  return Duration(hours: h, minutes: m, seconds: s, milliseconds: ms);
}

int? _positiveInt(String? s) {
  final n = int.tryParse(s?.trim() ?? "");
  return (n != null && n > 0) ? n : null;
}

/// Reads a DIDL-Lite document (the decoded text of `<Result>`).
/// [base] resolves relative `res`/art addresses.
List<DidlObject> parseDidl(String didl, {Uri? base}) {
  if (didl.trim().isEmpty) return const [];
  final doc = _parse(_declareMissingPrefixes(didl.trim()), "The listing");
  final out = <DidlObject>[];
  for (final node in doc.rootElement.childElements) {
    final isContainer = node.name.local == "container";
    if (!isContainer && node.name.local != "item") continue;
    final id = node.getAttribute("id")?.trim() ?? "";
    if (id.isEmpty) continue;

    Uri? resolve(String raw) {
      final t = raw.trim();
      if (t.isEmpty) return null;
      return base == null ? Uri.tryParse(t) : resolveDlnaUrl(base, t);
    }

    final performers = <String>[];
    String? albumArtist;
    for (final a in _children(node, "artist")) {
      final role = (a.getAttribute("role") ?? "").trim().toLowerCase();
      final name = a.innerText.trim();
      if (name.isEmpty) continue;
      if (role == "albumartist") {
        albumArtist ??= name;
      } else if ((role.isEmpty || role == "performer" || role == "artist") && !performers.contains(name)) {
        performers.add(name);
      }
    }
    albumArtist ??= _textOrNull(node, "albumArtist");

    final genres = <String>[];
    for (final g in _children(node, "genre")) {
      final name = g.innerText.trim();
      if (name.isNotEmpty && name.toLowerCase() != "unknown" && !genres.contains(name)) genres.add(name);
    }

    final resources = <DidlResource>[];
    for (final r in _children(node, "res")) {
      final uri = resolve(r.innerText);
      if (uri == null) continue;
      resources.add(
        DidlResource(
          uri: uri,
          protocolInfo: r.getAttribute("protocolInfo") ?? "",
          duration: parseDidlDuration(r.getAttribute("duration")),
          size: _positiveInt(r.getAttribute("size")),
          bitrate: _positiveInt(r.getAttribute("bitrate")),
          sampleFrequency: _positiveInt(r.getAttribute("sampleFrequency")),
          bitsPerSample: _positiveInt(r.getAttribute("bitsPerSample")),
          channels: _positiveInt(r.getAttribute("nrAudioChannels")),
        ),
      );
    }

    final art = _children(node, "albumArtURI").map((a) => resolve(a.innerText)).nonNulls.firstOrNull;

    out.add(
      DidlObject(
        id: id,
        parentId: node.getAttribute("parentID")?.trim() ?? "",
        refId: node.getAttribute("refID")?.trim().isEmpty ?? true ? null : node.getAttribute("refID")!.trim(),
        isContainer: isContainer,
        title: _text(node, "title"),
        upnpClass: _text(node, "class"),
        childCount: int.tryParse(node.getAttribute("childCount") ?? ""),
        creator: _textOrNull(node, "creator"),
        artists: performers,
        albumArtist: albumArtist,
        album: _textOrNull(node, "album"),
        genres: genres,
        trackNumber: _positiveInt(_text(node, "originalTrackNumber")),
        discNumber: _positiveInt(_text(node, "originalDiscNumber")),
        date: _textOrNull(node, "date"),
        albumArtUri: art,
        resources: resources,
      ),
    );
  }
  return out;
}

// ---------------------------------------------------------------------------
// SSDP

const ssdpAddress = "239.255.255.250";
const ssdpPort = 1900;

String buildMSearch({String searchTarget = dlnaMediaServerDeviceType, int mx = 2}) =>
    "M-SEARCH * HTTP/1.1\r\n"
    "HOST: $ssdpAddress:$ssdpPort\r\n"
    'MAN: "ssdp:discover"\r\n'
    "MX: $mx\r\n"
    "ST: $searchTarget\r\n"
    "USER-AGENT: Diapason UPnP/1.1\r\n"
    "\r\n";

/// The `LOCATION` header of an SSDP answer or announcement, when it is an
/// HTTP address.
Uri? parseSsdpLocation(String datagram) {
  for (final line in datagram.split(RegExp(r"\r?\n"))) {
    final colon = line.indexOf(":");
    if (colon <= 0) continue;
    if (line.substring(0, colon).trim().toLowerCase() != "location") continue;
    final uri = Uri.tryParse(line.substring(colon + 1).trim());
    if (uri != null && (uri.isScheme("http") || uri.isScheme("https")) && uri.host.isNotEmpty) return uri;
  }
  return null;
}

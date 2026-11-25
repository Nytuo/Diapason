// StreamAudioSource is marked experimental in just_audio; it is the only way to serve generated audio.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:diapason/services/hifi/dsd/byte_source.dart';
import 'package:diapason/services/hifi/dsd/dsd_container.dart';
import 'package:diapason/services/hifi/dsd/sacd.dart';
import 'package:diapason/services/hifi/dsd/virtual_wav.dart';
import 'package:diapason/services/hifi/hifi_platform.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger("DsdAudioSource");

/// Containers handled here.
const dsdContainers = {"dsf", "dff", "iso"};

bool isDsdContainer(String? container) => dsdContainers.contains(container?.toLowerCase());

/// How a DSD track reaches the player.
enum DsdDelivery {
  /// The player opens the file itself (mpv: ffmpeg decodes DSD to 352.8 kHz PCM, or DST).
  native,

  /// Converted here to 24-bit PCM at 88.2 kHz.
  pcm,

  /// Packed here as DoP (24-bit PCM carrying the DSD bits), for a bit-perfect output.
  dop,

  /// A DST track of a SACD image, re-wrapped as DSDIFF-DST for the player's decoder (mpv/ffmpeg).
  dstWrapped,
}

class DsdUnsupportedException implements Exception {
  DsdUnsupportedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Picks the delivery; throws [DsdUnsupportedException] for DST where the player has no DST decoder.
DsdDelivery chooseDsdDelivery({
  required HifiBackend backend,
  required bool bitPerfect,
  required String dsdMode,
  required bool dst,
  required int channels,
  required bool sacd,
}) {
  final mpv = backend == HifiBackend.mpv;
  if (dst) {
    if (!mpv) throw DsdUnsupportedException("DST-compressed DSD needs ffmpeg's DST decoder (Linux and Windows only)");
    return sacd ? DsdDelivery.dstWrapped : DsdDelivery.native;
  }
  if (mpv && bitPerfect && dsdMode == "dop" && channels == 2) return DsdDelivery.dop;
  if (mpv && !sacd) return DsdDelivery.native;
  return DsdDelivery.pcm;
}

/// What the signal path panel shows for a DSD track.
class DsdTrackInfo {
  const DsdTrackInfo({
    required this.container,
    required this.dsdRate,
    required this.channels,
    required this.dst,
    required this.delivery,
    this.outputRate,
  });

  /// `dsf`, `dff` or `sacd`.
  final String container;
  final int dsdRate;
  final int channels;
  final bool dst;
  final DsdDelivery delivery;

  /// PCM rate handed to the player (88.2 kHz for converted DSD, DSD/16 for DoP); null when the player decodes.
  final int? outputRate;
}

/// DSD info per queue item id, for the signal path panel.
final Map<String, DsdTrackInfo> dsdTrackInfo = {};

/// `file:///…/disc.iso#sacd=3`: track 3 of a SACD image (see `LocalBackend`).
int? sacdTrackOf(Uri uri) {
  final fragment = uri.fragment;
  if (!fragment.startsWith("sacd=")) return null;
  return int.tryParse(fragment.substring(5));
}

/// A remote file downloaded to a temporary file, readable while it grows.
class _ProgressiveDownload {
  _ProgressiveDownload(this.file, this.length);

  final File file;
  final int length;
  int received = 0;
  Object? error;
  final _progress = StreamController<void>.broadcast();

  static Future<_ProgressiveDownload> start(Uri uri, Map<String, String>? headers) async {
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, "dsd_${uri.toString().hashCode.toUnsigned(32)}.part"));
    final client = http.Client();
    final request = http.Request("GET", uri)..headers.addAll(headers ?? const {});
    final response = await client.send(request);
    if (response.statusCode != 200 || response.contentLength == null) {
      client.close();
      throw HttpException("DSD download: HTTP ${response.statusCode}", uri: uri);
    }
    final download = _ProgressiveDownload(file, response.contentLength!);
    final sink = file.openSync(mode: FileMode.write);
    response.stream.listen(
      (chunk) {
        sink.writeFromSync(chunk);
        download.received += chunk.length;
        download._progress.add(null);
      },
      onError: (Object e) {
        download.error = e;
        download._progress.add(null);
        sink.closeSync();
        client.close();
      },
      onDone: () {
        sink.closeSync();
        client.close();
        download._progress.add(null);
      },
      cancelOnError: true,
    );
    return download;
  }

  Future<void> waitFor(int offset) async {
    final target = min(offset, length);
    while (received < target) {
      if (error != null) throw error!;
      await _progress.stream.first.timeout(const Duration(seconds: 30));
    }
  }
}

class _ProgressiveByteSource implements ByteSource {
  _ProgressiveByteSource(this._download) : _file = _download.file.openSync();

  final _ProgressiveDownload _download;
  final RandomAccessFile _file;

  @override
  int get length => _download.length;

  @override
  Uint8List read(int offset, int count) {
    final available = min(_download.received, length);
    if (offset >= available || count <= 0) return Uint8List(0);
    _file.setPositionSync(offset);
    return _file.readSync(min(count, available - offset));
  }

  @override
  void close() => _file.closeSync();
}

/// A DSD track (DSF, DFF or a SACD image track) served to just_audio as a WAV (PCM or DoP) or as DSDIFF-DST,
/// produced on demand for each range the player asks for.
class DsdAudioSource extends StreamAudioSource {
  DsdAudioSource._({
    required this.info,
    required ByteSource Function() open,
    this.sacdTrack,
    _ProgressiveDownload? download,
    super.tag,
  }) : _open = open,
       _download = download;

  final DsdTrackInfo info;
  final ByteSource Function() _open;
  final int? sacdTrack;
  final _ProgressiveDownload? _download;
  List<SacdDstFrame>? _dstFrames;

  /// Opens [uri] (a `file:` path, or `http(s):` downloaded progressively) and decides how to deliver it. Returns
  /// null when the player should open the original URI itself ([DsdDelivery.native]); the info is still recorded
  /// under [queueItemId].
  static Future<DsdAudioSource?> create({
    required Uri uri,
    Map<String, String>? headers,
    required String queueItemId,
    required HifiBackend backend,
    required bool bitPerfect,
    required String dsdMode,
    dynamic tag,
  }) async {
    final track = sacdTrackOf(uri);
    _ProgressiveDownload? download;
    ByteSource Function() open;
    if (uri.isScheme("file")) {
      final path = uri.toFilePath();
      open = () => FileByteSource(path);
    } else {
      if (track != null) throw DsdUnsupportedException("SACD images are only read from local files");
      download = await _ProgressiveDownload.start(uri, headers);
      // Headers (DSDIFF chunks before the audio) are small; 1 MiB covers any real file.
      await download.waitFor(1 << 20);
      final d = download;
      open = () => _ProgressiveByteSource(d);
    }

    final DsdTrackInfo info;
    final probe = open();
    try {
      if (track != null) {
        final image = SacdImage.open(probe);
        final t = image.area.tracks.where((t) => t.number == track).firstOrNull;
        if (t == null) throw DsdUnsupportedException("the image has no track $track");
        final dst = t.encoding == SacdEncoding.dst;
        final delivery = chooseDsdDelivery(
          backend: backend,
          bitPerfect: bitPerfect,
          dsdMode: dsdMode,
          dst: dst,
          channels: 2,
          sacd: true,
        );
        info = _info("sacd", dsd64Rate, 2, dst, delivery);
      } else {
        final header = tryParseDsd(probe);
        if (header == null) throw DsdUnsupportedException("not a DSF or DSDIFF file");
        final delivery = chooseDsdDelivery(
          backend: backend,
          bitPerfect: bitPerfect,
          dsdMode: dsdMode,
          dst: header.dst,
          channels: header.channels,
          sacd: false,
        );
        info = _info(header.container.name, header.sampleRate, header.channels, header.dst, delivery);
      }
    } finally {
      probe.close();
    }
    dsdTrackInfo[queueItemId] = info;
    _log.info("DSD track ${info.container} ${dsdRateName(info.dsdRate)}: ${info.delivery.name}");
    if (info.delivery == DsdDelivery.native) return null;
    return DsdAudioSource._(info: info, open: open, sacdTrack: track, download: download, tag: tag);
  }

  static DsdTrackInfo _info(String container, int rate, int channels, bool dst, DsdDelivery delivery) => DsdTrackInfo(
    container: container,
    dsdRate: rate,
    channels: channels,
    dst: dst,
    delivery: delivery,
    outputRate: switch (delivery) {
      DsdDelivery.pcm => 88200,
      DsdDelivery.dop => rate ~/ 16,
      _ => null,
    },
  );

  DsdSource _dsdSource(ByteSource bytes) {
    if (sacdTrack == null) return openDsd(bytes);
    final image = SacdImage.open(bytes);
    return SacdTrackReader(image, image.area.tracks.firstWhere((t) => t.number == sacdTrack));
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final bytes = _open();
    if (info.delivery == DsdDelivery.dstWrapped) {
      final image = SacdImage.open(bytes);
      final stream = SacdDstStream(
        image,
        image.area.tracks.firstWhere((t) => t.number == sacdTrack),
        scanned: _dstFrames,
      );
      _dstFrames = stream.frames;
      final from = start ?? 0;
      final to = end ?? stream.length;
      return StreamAudioResponse(
        rangeRequestsSupported: true,
        sourceLength: stream.length,
        contentLength: to - from,
        offset: from,
        contentType: "audio/x-dff",
        stream: _guarded(Stream.fromIterable(stream.range(from, to)), image.close),
      );
    }
    final source = _dsdSource(bytes);
    final WavProducer producer = info.delivery == DsdDelivery.dop ? DopWavProducer(source) : PcmWavProducer(source);
    final from = start ?? 0;
    final to = min(end ?? producer.byteLength, producer.byteLength);
    return StreamAudioResponse(
      rangeRequestsSupported: true,
      sourceLength: producer.byteLength,
      contentLength: to - from,
      offset: from,
      contentType: "audio/wav",
      stream: _guarded(virtualWavRange(producer, from, to, waitFor: _download?.waitFor), source.close),
    );
  }
}

/// Closes the file behind [stream] however it ends: done, error, or cancelled by the player (a seek).
Stream<List<int>> _guarded(Stream<List<int>> stream, void Function() close) async* {
  try {
    yield* stream;
  } finally {
    close();
  }
}

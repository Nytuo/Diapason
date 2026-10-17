import 'dart:convert';
import 'dart:io';

/// A stand-in for the yt-dlp executable: a shell script that answers like the
/// real one (JSON for searches, URLs for `--print`) without touching the
/// network, so tests are fast, repeatable and run offline.
///
/// The test steers it by writing a mode ("ok", "bot", "unavailable", "network",
/// "slow", "garbage") and reads back every invocation from [calls].
class FakeYtDlp {
  FakeYtDlp._(this.dir, this.script);

  final Directory dir;
  final File script;

  static bool get supported => !Platform.isWindows;

  static Future<FakeYtDlp> create(Directory parent, {String version = '2099.01.01'}) async {
    final dir = await Directory('${parent.path}/fake-ytdlp').create(recursive: true);
    final script = File('${dir.path}/yt-dlp');
    await script.writeAsString(_script(version));
    await Process.run('chmod', ['755', script.path]);
    final fake = FakeYtDlp._(dir, script);
    await fake.setMode('ok');
    return fake;
  }

  String get path => script.path;

  Future<void> setMode(String mode) => File('${dir.path}/mode.txt').writeAsString(mode);

  File get _callsFile => File('${dir.path}/calls.log');

  /// Every invocation as a list of arguments, oldest first (`--version` probes included).
  List<List<String>> get calls {
    if (!_callsFile.existsSync()) return const [];
    return const LineSplitter()
        .convert(_callsFile.readAsStringSync())
        .where((l) => l.isNotEmpty)
        .map((l) => l.split('\u001f').where((a) => a.isNotEmpty).toList())
        .toList();
  }

  /// Invocations that did real work, i.e. not the `--version` probe.
  List<List<String>> get operations => calls.where((c) => !c.contains('--version')).toList();

  /// Start/end markers written by slow calls, for checking how many ran at once.
  List<String> get timeline => File('${dir.path}/timeline.log').existsSync()
      ? const LineSplitter().convert(File('${dir.path}/timeline.log').readAsStringSync())
      : const [];

  void clearCalls() {
    if (_callsFile.existsSync()) _callsFile.deleteSync();
  }

  static String _script(String version) =>
      '''#!/bin/sh
DIR=\$(dirname "\$0")
printf '%s\\037' "\$@" >> "\$DIR/calls.log"; echo >> "\$DIR/calls.log"
MODE=\$(cat "\$DIR/mode.txt" 2>/dev/null || echo ok)

for a in "\$@"; do [ "\$a" = "--version" ] && { echo $version; exit 0; }; done

case "\$MODE" in
  bot)         echo "ERROR: [youtube] x: Sign in to confirm you're not a bot" >&2; exit 1;;
  unavailable) echo "ERROR: [youtube] x: Video unavailable" >&2; exit 1;;
  network)     echo "ERROR: [youtube] x: Unable to download webpage: Temporary failure in name resolution" >&2; exit 1;;
  slow)        echo "start \$\$" >> "\$DIR/timeline.log"; sleep 0.6; echo "end \$\$" >> "\$DIR/timeline.log";;
  garbage)     echo "this is not json"; exit 0;;
esac

OP=other
OUT=""
PREV=""
for a in "\$@"; do
  case "\$a" in
    ytsearch*) OP=search;;
    --playlist-end) OP=playlist;;
    %\\(url\\)s) OP=stream;;
    --write-info-json) OP=download;;
  esac
  [ "\$PREV" = "-o" ] && OUT="\$a"
  PREV="\$a"
done
if [ "\$OP" = other ]; then
  for a in "\$@"; do [ "\$a" = "-J" ] && OP=lookup; done
fi

case "\$OP" in
  search|playlist)
    cat <<'JSON'
{"entries":[
 {"id":"dQw4w9WgXcQ","title":"Never Gonna Give You Up","channel":"Rick Astley - Topic","duration":212.0},
 {"id":"UCxxxxxxxxxxxxxxxxxxxxxx","title":"A channel, not a video"},
 {"id":"abc","title":"too short an id"},
 {"id":"9bZkp7q19f0","title":"Gangnam Style","uploader":"officialpsy","duration":252}
]}
JSON
    ;;
  download)
    # The id is the last argument's v= parameter; the output template is the one after -o.
    for a in "\$@"; do LAST="\$a"; done
    VID="\${LAST##*v=}"
    BASE=\$(printf '%s' "\$OUT" | sed -e "s/%(id)s/\$VID/" -e "s/%(ext)s/m4a/")
    printf 'fake audio for %s' "\$VID" > "\$BASE"
    DIRO=\$(dirname "\$OUT")
    cat > "\$DIRO/\$VID.info.json" <<INFO
{"id":"\$VID","title":"Never Gonna Give You Up","artist":"Rick Astley","album":"Whenever You Need Somebody","track_number":1,"release_year":1987,"duration":212}
INFO
    ;;
  lookup)
    echo '{"id":"jNQXAC9IVRw","title":"Me at the zoo","channel":"jawed","duration":19}'
    ;;
  stream)
    echo "https://rr1---sn-test.googlevideo.com/videoplayback?id=abc"
    echo "m4a"
    ;;
  *)
    echo "{}"
    ;;
esac
''';
}

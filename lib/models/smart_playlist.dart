import 'dart:convert';

enum SmartField {
  title("Title"),
  artist("Artist"),
  album("Album"),
  genre("Genre"),
  year("Year"),
  favorite("Favorite"),
  playCount("Play count");

  const SmartField(this.label);
  final String label;

  bool get isNumeric => this == SmartField.year || this == SmartField.playCount;
  bool get isBool => this == SmartField.favorite;
}

enum SmartOp {
  contains("contains"),
  equals("is"),
  notEquals("is not"),
  greaterThan("greater than"),
  lessThan("less than");

  const SmartOp(this.label);
  final String label;
}

class SmartRule {
  SmartRule({required this.field, required this.op, required this.value});

  SmartField field;
  SmartOp op;
  String value;

  Map<String, dynamic> toJson() => {"field": field.name, "op": op.name, "value": value};

  factory SmartRule.fromJson(Map<String, dynamic> j) => SmartRule(
    field: SmartField.values.byName(j["field"] as String),
    op: SmartOp.values.byName(j["op"] as String),
    value: j["value"] as String? ?? "",
  );

  SmartRule copy() => SmartRule(field: field, op: op, value: value);
}

enum SmartSort {
  title("Title"),
  artist("Artist"),
  album("Album"),
  year("Year"),
  playCount("Play count"),
  random("Random");

  const SmartSort(this.label);
  final String label;
}

class SmartPlaylist {
  SmartPlaylist({
    required this.id,
    required this.name,
    this.matchAll = true,
    List<SmartRule>? rules,
    this.sort = SmartSort.title,
    this.descending = false,
    this.limit,
  }) : rules = rules ?? [];

  final String id;
  String name;

  bool matchAll;
  List<SmartRule> rules;
  SmartSort sort;
  bool descending;
  int? limit;

  Map<String, dynamic> toJson() => {
    "id": id,
    "name": name,
    "matchAll": matchAll,
    "rules": rules.map((r) => r.toJson()).toList(),
    "sort": sort.name,
    "descending": descending,
    "limit": limit,
  };

  String encode() => jsonEncode(toJson());

  factory SmartPlaylist.fromJson(Map<String, dynamic> j) => SmartPlaylist(
    id: j["id"] as String,
    name: j["name"] as String? ?? "Smart Playlist",
    matchAll: j["matchAll"] as bool? ?? true,
    rules: (j["rules"] as List? ?? [])
        .map((e) => SmartRule.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    sort: SmartSort.values.byName(j["sort"] as String? ?? "title"),
    descending: j["descending"] as bool? ?? false,
    limit: j["limit"] as int?,
  );

  factory SmartPlaylist.decode(String s) => SmartPlaylist.fromJson(Map<String, dynamic>.from(jsonDecode(s) as Map));

  SmartPlaylist copy() => SmartPlaylist.decode(encode());
}

import 'dart:convert';

class TvProfile {
  const TvProfile({required this.id, required this.name, required this.colorValue, this.sourceIds = const []});

  final String id;
  final String name;
  final int colorValue;
  final List<String> sourceIds;

  String get initial => name.trim().isEmpty ? "?" : name.trim().substring(0, 1).toUpperCase();

  TvProfile copyWith({String? name, int? colorValue, List<String>? sourceIds}) => TvProfile(
    id: id,
    name: name ?? this.name,
    colorValue: colorValue ?? this.colorValue,
    sourceIds: sourceIds ?? this.sourceIds,
  );

  Map<String, dynamic> toJson() => {"id": id, "name": name, "color": colorValue, "sources": sourceIds};

  String encode() => jsonEncode(toJson());

  factory TvProfile.fromJson(Map<String, dynamic> json) => TvProfile(
    id: json["id"] as String,
    name: (json["name"] as String?) ?? "Profile",
    colorValue: (json["color"] as num?)?.toInt() ?? defaultColors.first,
    sourceIds: ((json["sources"] as List?) ?? const []).cast<String>(),
  );

  factory TvProfile.decode(String json) => TvProfile.fromJson(jsonDecode(json) as Map<String, dynamic>);

  static const defaultColors = <int>[
    0xFF1E88E5, // blue
    0xFFE53935, // red
    0xFF43A047, // green
    0xFFFB8C00, // orange
    0xFF8E24AA, // purple
    0xFF00ACC1, // teal
    0xFFD81B60, // pink
    0xFF6D4C41, // brown
  ];

  @override
  bool operator ==(Object other) =>
      other is TvProfile &&
      other.id == id &&
      other.name == name &&
      other.colorValue == colorValue &&
      _sameList(other.sourceIds, sourceIds);

  @override
  int get hashCode => Object.hash(id, name, colorValue, Object.hashAll(sourceIds));

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

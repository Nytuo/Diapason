import 'package:dartx/dartx.dart';
import 'package:isar_community/isar.dart';

import 'package:isar_community_generator/src/object_info.dart';

String generateSchema(ObjectInfo object) {
  var code = 'const ${object.dartName.capitalize()}Schema = ';
  if (!object.isEmbedded) {
    code += 'CollectionSchema(';
  } else {
    code += 'Schema(';
  }

  final properties = object.objectProperties
      .mapIndexed(
        (i, e) => "r'${e.isarName}': ${_generatePropertySchema(object, i)}",
      )
      .join(',');

  code +=
      '''
    name: r'${object.isarName}',
    id: ${webSafeIntLiteral(object.id)},
    properties: {$properties},

    estimateSize: ${object.estimateSizeName},
    serialize: ${object.serializeName},
    deserialize: ${object.deserializeName},
    deserializeProp: ${object.deserializePropName},''';

  if (!object.isEmbedded) {
    final indexes = object.indexes
        .map((e) => "r'${e.name}': ${_generateIndexSchema(e)}")
        .join(',');
    final links = object.links
        .map((e) => "r'${e.isarName}': ${_generateLinkSchema(object, e)}")
        .join(',');
    final embeddedSchemas = object.embeddedDartNames.entries
        .map((e) => "r'${e.key}': ${e.value.capitalize()}Schema")
        .join(',');

    code +=
        '''
      idName: r'${object.idProperty.isarName}',
      indexes: {$indexes},
      links: {$links},
      embeddedSchemas: {$embeddedSchemas},

      getId: ${object.getIdName},
      getLinks: ${object.getLinksName},
      attach: ${object.attachName},
      version: '${Isar.version}',
    ''';
  }

  return '$code);';
}

/// Diapason: schema ids are 64-bit hashes, and dart2js rejects integer
/// literals that a JS double can't represent exactly, which breaks the web
/// build. Ids outside the safe range are written as a const expression built
/// from two 32-bit halves: the VM evaluates it to the exact same 64-bit value
/// (wrapping like the original literal), while dart2js accepts it (with a
/// truncated value, which is harmless: Isar is never opened on the web).
String webSafeIntLiteral(int value) {
  const maxSafe = 9007199254740991; // 2^53 - 1
  if (value >= -maxSafe && value <= maxSafe) {
    return '$value';
  }
  final hi = (value >> 32) & 0xFFFFFFFF;
  final lo = value & 0xFFFFFFFF;
  String hex(int v) => '0x${v.toRadixString(16).toUpperCase()}';
  return '(${hex(hi)} << 32 | ${hex(lo)})';
}

String _generatePropertySchema(ObjectInfo object, int index) {
  final property = object.objectProperties[index];
  var enumMap = '';
  if (property.isEnum) {
    enumMap = 'enumMap: ${property.enumValueMapName(object)},';
  }
  var target = '';
  if (property.targetIsarName != null) {
    target = "target: r'${property.targetIsarName}',";
  }
  return '''
  PropertySchema(
    id: $index,
    name: r'${property.isarName}',
    type: IsarType.${property.isarType.name},
    $enumMap
    $target
  )
  ''';
}

String _generateIndexSchema(ObjectIndex index) {
  final properties = index.properties
      .map((e) {
        return '''
      IndexPropertySchema(
        name: r'${e.property.isarName}',
        type: IndexType.${e.type.name},
        caseSensitive: ${e.caseSensitive},
      )''';
      })
      .join(',');

  return '''
    IndexSchema(
      id: ${webSafeIntLiteral(index.id)},
      name: r'${index.name}',
      unique: ${index.unique},
      replace: ${index.replace},
      properties: [$properties],
    )''';
}

String _generateLinkSchema(ObjectInfo object, ObjectLink link) {
  var linkName = '';
  if (link.isBacklink) {
    linkName = "linkName: r'${link.targetLinkIsarName}',";
  }
  return '''
    LinkSchema(
      id: ${webSafeIntLiteral(link.id(object.isarName))},
      name: r'${link.isarName}',
      target: r'${link.targetCollectionIsarName}',
      single: ${link.isSingle},
      $linkName
    )''';
}

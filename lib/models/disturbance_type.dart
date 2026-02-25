class DisturbanceTypeGroup {
  const DisturbanceTypeGroup({
    required this.code,
    required this.name,
    required this.types,
  });

  final String code;
  final String name;
  final List<DisturbanceType> types;
}

class DisturbanceType {
  const DisturbanceType({
    required this.code,
    required this.name,
    this.note,
  });

  final String code;
  final String name;
  final String? note;
}

class SelectedDisturbanceType {
  const SelectedDisturbanceType({
    required this.groupCode,
    required this.groupName,
    required this.typeCode,
    required this.typeName,
  });

  final String groupCode;
  final String groupName;
  final String typeCode;
  final String typeName;

  Map<String, dynamic> toJson() => {
        'groupCode': groupCode,
        'groupName': groupName,
        'typeCode': typeCode,
        'typeName': typeName,
      };

  factory SelectedDisturbanceType.fromJson(Map<String, dynamic> json) {
    return SelectedDisturbanceType(
      groupCode: json['groupCode'] as String,
      groupName: json['groupName'] as String,
      typeCode: json['typeCode'] as String,
      typeName: json['typeName'] as String,
    );
  }

  String get display => '$groupName → $typeName';
}

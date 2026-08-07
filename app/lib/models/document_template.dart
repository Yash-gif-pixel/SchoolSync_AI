/// A school's own form, described as a field list.
///
/// Mirrors `api/app/services/templates.py`. The template is the single source
/// of truth for one document type: extraction builds its schema from it,
/// validation derives rules from each field's type, and commit routes by the
/// template's target.
library;

enum FieldType {
  text,
  longtext,
  date,
  number,
  phone,
  email,
  choice,
  grade;

  static FieldType parse(String? v) => FieldType.values.firstWhere(
        (t) => t.name == v,
        orElse: () => FieldType.text,
      );

  String get label => switch (this) {
        FieldType.text => 'Text',
        FieldType.longtext => 'Long text',
        FieldType.date => 'Date',
        FieldType.number => 'Number',
        FieldType.phone => 'Phone',
        FieldType.email => 'Email',
        FieldType.choice => 'Choice',
        FieldType.grade => 'Class / grade',
      };

  /// What the reviewer is told this type will be checked for.
  String get rule => switch (this) {
        FieldType.text => 'Copied as written',
        FieldType.longtext => 'May span several lines',
        FieldType.date => 'Read as dd/mm/yyyy',
        FieldType.number => 'Must be numeric',
        FieldType.phone => 'Must be a 10-digit Indian mobile',
        FieldType.email => 'Must be a valid email address',
        FieldType.choice => 'Must be one of the listed options',
        FieldType.grade => 'Must be a class the school runs',
      };
}

enum TemplateTarget {
  student,
  leaveRequest,
  dataOnly;

  static TemplateTarget parse(String? v) => switch (v) {
        'student' => TemplateTarget.student,
        'leave_request' => TemplateTarget.leaveRequest,
        _ => TemplateTarget.dataOnly,
      };

  String get wire => switch (this) {
        TemplateTarget.student => 'student',
        TemplateTarget.leaveRequest => 'leave_request',
        TemplateTarget.dataOnly => 'data_only',
      };

  String get label => switch (this) {
        TemplateTarget.student => 'Creates a student record',
        TemplateTarget.leaveRequest => 'Creates a leave request',
        TemplateTarget.dataOnly => 'Stored as data only',
      };

  String get shortLabel => switch (this) {
        TemplateTarget.student => 'Student',
        TemplateTarget.leaveRequest => 'Leave',
        TemplateTarget.dataOnly => 'Data',
      };
}

/// Destinations a field may write to. `__class` is special: a grade number
/// resolved to a class at commit time.
const studentColumns = <String>[
  '__class',
  'full_name',
  'date_of_birth',
  'gender',
  'guardian_name',
  'guardian_phone',
  'address',
  'previous_school',
  'admission_date',
  'roll_no',
];

const leaveColumns = <String>['from_date', 'to_date', 'reason'];

String columnLabel(String col) => switch (col) {
      '__class' => 'Class to place them in',
      'full_name' => 'Student name',
      'date_of_birth' => 'Date of birth',
      'gender' => 'Gender',
      'guardian_name' => 'Guardian name',
      'guardian_phone' => 'Guardian phone',
      'address' => 'Address',
      'previous_school' => 'Previous school',
      'admission_date' => 'Admission date',
      'roll_no' => 'Roll number',
      'from_date' => 'Leave starts',
      'to_date' => 'Leave ends',
      'reason' => 'Reason',
      _ => col,
    };

class TemplateField {
  TemplateField({
    required this.key,
    required this.label,
    required this.type,
    this.required = false,
    this.mapsTo,
    this.description,
    this.options,
  });

  String key;
  String label;
  FieldType type;
  bool required;
  String? mapsTo;
  String? description;
  List<String>? options;

  TemplateField copy() => TemplateField(
        key: key,
        label: label,
        type: type,
        required: required,
        mapsTo: mapsTo,
        description: description,
        options: options == null ? null : List.of(options!),
      );

  factory TemplateField.fromMap(Map<String, dynamic> m) => TemplateField(
        key: (m['key'] ?? '') as String,
        label: (m['label'] ?? '') as String,
        type: FieldType.parse(m['type'] as String?),
        required: (m['required'] ?? false) as bool,
        mapsTo: m['maps_to'] as String?,
        description: m['description'] as String?,
        options: (m['options'] as List?)?.cast<String>(),
      );

  Map<String, dynamic> toMap() => {
        'key': key,
        'label': label,
        'type': type.name,
        'required': required,
        if (mapsTo != null && mapsTo!.isNotEmpty) 'maps_to': mapsTo,
        if (description != null && description!.isNotEmpty) 'description': description,
        if (options != null && options!.isNotEmpty) 'options': options,
      };
}

class DocumentTemplate {
  DocumentTemplate({
    required this.id,
    required this.name,
    required this.target,
    required this.fields,
    this.description,
    this.samplePath,
    this.isBuiltin = false,
    this.isActive = true,
  });

  final String id;
  String name;
  String? description;
  TemplateTarget target;
  List<TemplateField> fields;
  String? samplePath;
  final bool isBuiltin;
  bool isActive;

  int get requiredCount => fields.where((f) => f.required).length;

  factory DocumentTemplate.fromMap(Map<String, dynamic> m) => DocumentTemplate(
        id: (m['id'] ?? '') as String,
        name: (m['name'] ?? '') as String,
        description: m['description'] as String?,
        target: TemplateTarget.parse(m['target'] as String?),
        samplePath: m['sample_path'] as String?,
        isBuiltin: (m['is_builtin'] ?? false) as bool,
        isActive: (m['is_active'] ?? true) as bool,
        fields: ((m['fields'] ?? const []) as List)
            .map((f) => TemplateField.fromMap(f as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toPayload() => {
        'name': name,
        'description': description,
        'target': target.wire,
        'fields': fields.map((f) => f.toMap()).toList(),
        'sample_path': samplePath,
        'is_active': isActive,
      };
}

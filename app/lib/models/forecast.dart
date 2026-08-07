/// Predictive staffing.
library;

class ForecastCard {
  const ForecastCard({
    required this.severity,
    required this.headline,
    required this.because,
    required this.date,
    this.department,
    this.event,
    this.weekday,
    this.probability,
    this.expectedAbsences,
    this.absorbable,
    this.recurring = false,
    this.weekdays = const [],
  });

  final String severity; // critical | warning
  final String headline;
  final String because;
  final String date;
  final String? department;
  final String? event;
  final String? weekday;
  final double? probability;
  final double? expectedAbsences;
  final int? absorbable;
  final bool recurring;
  final List<String> weekdays;

  bool get isCritical => severity == 'critical';

  factory ForecastCard.fromMap(Map<String, dynamic> m) => ForecastCard(
        severity: (m['severity'] ?? 'warning') as String,
        headline: (m['headline'] ?? '') as String,
        because: (m['because'] ?? '') as String,
        date: (m['date'] ?? '') as String,
        department: m['department'] as String?,
        event: m['event'] as String?,
        weekday: m['weekday'] as String?,
        probability: (m['probability'] as num?)?.toDouble(),
        expectedAbsences: (m['expected_absences'] as num?)?.toDouble(),
        absorbable: (m['absorbable'] as num?)?.toInt(),
        recurring: (m['recurring'] ?? false) as bool,
        weekdays: ((m['weekdays'] ?? const []) as List).cast<String>(),
      );
}

class ForecastDay {
  const ForecastDay({
    required this.date,
    required this.weekday,
    required this.expectedAbsences,
    required this.weekdayMultiplier,
    required this.eventTeachers,
    required this.events,
    required this.departments,
  });

  final String date;
  final String weekday;
  final double expectedAbsences;
  final double weekdayMultiplier;
  final int eventTeachers;
  final List<String> events;
  final List<Map<String, dynamic>> departments;

  /// "07 Aug" for the chart axis.
  String get shortDate {
    final d = DateTime.tryParse(date);
    if (d == null) return date;
    const months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${months[d.month]}';
  }

  String get dayInitial => weekday.isEmpty ? '?' : weekday[0];

  factory ForecastDay.fromMap(Map<String, dynamic> m) => ForecastDay(
        date: (m['date'] ?? '') as String,
        weekday: (m['weekday'] ?? '') as String,
        expectedAbsences: (m['expected_absences'] as num?)?.toDouble() ?? 0,
        weekdayMultiplier: (m['weekday_multiplier'] as num?)?.toDouble() ?? 1,
        eventTeachers: (m['event_teachers'] ?? 0) as int,
        events: ((m['events'] ?? const []) as List).cast<String>(),
        departments: ((m['departments'] ?? const []) as List)
            .cast<Map<String, dynamic>>(),
      );
}

class StaffingForecast {
  const StaffingForecast({
    required this.days,
    required this.cards,
    required this.criticalCount,
    required this.warningCount,
    required this.method,
    required this.weekdayEffects,
    required this.observedDays,
    required this.observedAbsences,
    required this.overallRate,
    this.hasTimetable = true,
    this.note,
  });

  final List<ForecastDay> days;
  final List<ForecastCard> cards;
  final int criticalCount;
  final int warningCount;
  final String method;
  final Map<String, double> weekdayEffects;
  final int observedDays;
  final int observedAbsences;
  final double overallRate;
  final bool hasTimetable;
  final String? note;

  double get peakExpected =>
      days.isEmpty ? 1 : days.map((d) => d.expectedAbsences).reduce((a, b) => a > b ? a : b);

  factory StaffingForecast.fromMap(Map<String, dynamic> m) {
    final rates = (m['rates'] ?? const {}) as Map<String, dynamic>;
    final wk = (rates['by_weekday'] ?? const {}) as Map<String, dynamic>;
    return StaffingForecast(
      criticalCount: (m['critical_count'] ?? 0) as int,
      warningCount: (m['warning_count'] ?? 0) as int,
      method: (m['method'] ?? '') as String,
      hasTimetable: (m['has_timetable'] ?? true) as bool,
      note: m['note'] as String?,
      observedDays: (rates['observed_days'] ?? 0) as int,
      observedAbsences: (rates['observed_absences'] ?? 0) as int,
      overallRate: (rates['overall_daily_rate'] as num?)?.toDouble() ?? 0,
      weekdayEffects: {
        for (final e in wk.entries) e.key: (e.value as num).toDouble(),
      },
      days: ((m['days'] ?? const []) as List)
          .map((d) => ForecastDay.fromMap(d as Map<String, dynamic>))
          .toList(),
      cards: ((m['cards'] ?? const []) as List)
          .map((c) => ForecastCard.fromMap(c as Map<String, dynamic>))
          .toList(),
    );
  }
}

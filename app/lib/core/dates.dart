/// Day-month-year is how dates are written on these forms, so it is how they
/// are shown and typed in the app. ISO is a storage format, not a reading
/// format — showing a reviewer "2014-03-10" when they wrote "10/03/2014" reads
/// as though the AI reversed it, even when the parse was correct.
library;

class Dates {
  const Dates._();

  static const dateFields = {'date_of_birth', 'admission_date'};

  static bool isDateField(String name) => dateFields.contains(name);

  /// "2014-03-10" -> "10/03/2014". Returns the input unchanged if it isn't ISO.
  static String isoToDisplay(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    return '${_pad(d.day)}/${_pad(d.month)}/${d.year}';
  }

  /// "10/03/2014" -> "2014-03-10". Null when it can't be read as a real date.
  ///
  /// Accepts /, -, . and | as separators, and a two-digit year (interpreted as
  /// 20xx up to ten years ahead, 19xx beyond that — so 26 is 2026 but 79 is
  /// 1979). Rejects impossible dates like 31/02 rather than rolling them over.
  static String? displayToIso(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    final t = text.trim();

    // Already ISO — accept it so a pasted value still works.
    final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(t);
    if (iso != null) {
      return _build(
        int.parse(iso.group(1)!),
        int.parse(iso.group(2)!),
        int.parse(iso.group(3)!),
      );
    }

    final m = RegExp(r'^(\d{1,2})\s*[/\-.|]\s*(\d{1,2})\s*[/\-.|]\s*(\d{2,4})$')
        .firstMatch(t);
    if (m == null) return null;

    final day = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    var year = int.parse(m.group(3)!);
    if (year < 100) {
      final cutoff = (DateTime.now().year % 100) + 10;
      year += year <= cutoff ? 2000 : 1900;
    }
    return _build(year, month, day);
  }

  /// Null unless the components form a real calendar date.
  static String? _build(int year, int month, int day) {
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    final d = DateTime(year, month, day);
    if (d.year != year || d.month != month || d.day != day) return null;
    return '$year-${_pad(month)}-${_pad(day)}';
  }

  static String _pad(int n) => n.toString().padLeft(2, '0');
}

/// Facts about the school that the client needs locally.
///
/// Mirrors `api/app/services/validation.py`. The server is the real gate —
/// this only powers the pre-check that disables the commit button early, so if
/// the two ever drift the worst case is a button that enables and then gets a
/// clear rejection from the API.
library;

class School {
  const School._();

  static const minGrade = 1;
  static const maxGrade = 10;

  /// Grades 1–5 have no lab periods; see PRIMARY_CURRICULUM in seed.py.
  static const primaryGrades = {1, 2, 3, 4, 5};

  static bool isValidGrade(int? g) =>
      g != null && g >= minGrade && g <= maxGrade;

  static String get gradeRangeLabel => '$minGrade–$maxGrade';
}

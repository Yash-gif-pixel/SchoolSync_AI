/// Build-time configuration.
///
/// The Supabase anon key is public by design — it ships inside the web bundle
/// and is safe to commit. RLS is what protects the data (see db/002_rls.sql).
/// The service_role key must NEVER appear in this app.
///
/// Phase 5 overrides these at build time:
///   flutter build web --dart-define=API_BASE_URL=https://api.example.com
class AppConfig {
  const AppConfig._();

  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://cnkpjapwjbwwfgrgtojt.supabase.co',
  );

  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNua3BqYXB3amJ3d2Zncmd0b2p0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYwMjYxNDEsImV4cCI6MjEwMTYwMjE0MX0.YuAL3Gl4KJdl4CHUkkxIHNIB6B8yzK_GhCqj9AQkYfY',
  );

  static const apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );

  /// Where this app is being served from, for building links that get pasted
  /// elsewhere — invite links, mainly.
  ///
  /// Read at runtime rather than baked in, so a link generated on the deployed
  /// host does not tell the recipient to visit localhost. `Uri.base.origin`
  /// alone is not safe: it throws a StateError on any non-http scheme, which
  /// is what the test VM (`file:`) and a desktop build both are.
  static String get appOrigin {
    final base = Uri.base;
    if (base.scheme == 'http' || base.scheme == 'https') return base.origin;
    return const String.fromEnvironment(
      'APP_BASE_URL',
      defaultValue: 'http://127.0.0.1:5000',
    );
  }
}

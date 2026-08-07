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
}

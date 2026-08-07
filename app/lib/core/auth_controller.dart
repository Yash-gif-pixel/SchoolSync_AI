import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/profile.dart';

/// Combined session + profile.
///
/// The router needs both: the session decides signed-in vs not, and the
/// profile's role decides which dashboard to land on. Named AppAuthState
/// because supabase_flutter already exports an `AuthState`.
class AppAuthState {
  const AppAuthState({
    this.session,
    this.profile,
    this.loading = true,
    this.error,
  });

  final Session? session;
  final Profile? profile;
  final bool loading;
  final String? error;

  bool get signedIn => session != null;

  /// True once we know enough to route: either signed out, or signed in
  /// with a profile loaded.
  bool get resolved => !loading && (session == null || profile != null);

  AppAuthState copyWith({bool? loading, String? error, bool clearError = false}) =>
      AppAuthState(
        session: session,
        profile: profile,
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
      );
}

class AuthController extends Notifier<AppAuthState> {
  StreamSubscription<AuthState>? _sub;

  SupabaseClient get _sb => Supabase.instance.client;

  @override
  AppAuthState build() {
    _sub = _sb.auth.onAuthStateChange.listen(_onAuthChange);
    ref.onDispose(() => _sub?.cancel());

    final existing = _sb.auth.currentSession;
    if (existing == null) return const AppAuthState(loading: false);

    // Session restored from local storage — fetch its profile.
    Future.microtask(() => _loadProfile(existing));
    return AppAuthState(session: existing, loading: true);
  }

  void _onAuthChange(AuthState data) {
    final session = data.session;
    if (session == null) {
      state = const AppAuthState(loading: false);
    } else if (state.profile?.id != session.user.id) {
      state = AppAuthState(session: session, loading: true);
      _loadProfile(session);
    }
  }

  Future<void> _loadProfile(Session session) async {
    try {
      final row = await _sb
          .from('profiles')
          .select('id, full_name, role, is_approver, employee_code, '
              'department_id, departments(name)')
          .eq('id', session.user.id)
          .maybeSingle();

      if (row == null) {
        state = AppAuthState(
          session: session,
          loading: false,
          error: 'Signed in, but no profile row exists for this account.',
        );
        return;
      }
      state = AppAuthState(
        session: session,
        profile: Profile.fromMap(row),
        loading: false,
      );
    } catch (e) {
      state = AppAuthState(session: session, loading: false, error: '$e');
    }
  }

  Future<String?> signIn(String email, String password) async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      await _sb.auth.signInWithPassword(email: email.trim(), password: password);
      return null; // _onAuthChange continues from here
    } on AuthException catch (e) {
      state = const AppAuthState(loading: false).copyWith(error: e.message);
      return e.message;
    } catch (e) {
      state = const AppAuthState(loading: false).copyWith(error: '$e');
      return '$e';
    }
  }

  Future<void> signOut() async {
    await _sb.auth.signOut();
    state = const AppAuthState(loading: false);
  }
}

final authControllerProvider =
    NotifierProvider<AuthController, AppAuthState>(AuthController.new);

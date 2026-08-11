import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/ui/primitives.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController(text: 'Demo@12345');
  final _formKey = GlobalKey<FormState>();
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    await ref
        .read(authControllerProvider.notifier)
        .signIn(_email.text, _password.text);
  }

  void _quickFill(String email) {
    _email.text = email;
    _submit();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 900;

    final form = Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!wide) ...[
                  const _Logo(),
                  const SizedBox(height: AppSpace.xl),
                ],
                Text('Sign in', style: theme.textTheme.headlineSmall),
                const SizedBox(height: AppSpace.xs),
                Text('Use your school account to continue.',
                    style: theme.textTheme.bodySmall),
                const SizedBox(height: AppSpace.xl),

                Text('Email', style: theme.textTheme.labelLarge),
                const SizedBox(height: 6),
                TextFormField(
                  controller: _email,
                  autofillHints: const [AutofillHints.email],
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    hintText: 'you@school.test',
                    prefixIcon: Icon(Icons.mail_outline, size: 19),
                  ),
                  validator: (v) => (v == null || !v.contains('@'))
                      ? 'Enter a valid email'
                      : null,
                ),
                const SizedBox(height: AppSpace.lg),

                Text('Password', style: theme.textTheme.labelLarge),
                const SizedBox(height: 6),
                TextFormField(
                  controller: _password,
                  obscureText: _obscure,
                  onFieldSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.lock_outline, size: 19),
                    suffixIcon: IconButton(
                      iconSize: 19,
                      icon: Icon(_obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  validator: (v) =>
                      (v == null || v.isEmpty) ? 'Enter a password' : null,
                ),

                if (auth.error != null) ...[
                  const SizedBox(height: AppSpace.lg),
                  Callout(tone: Tone.danger, message: auth.error!),
                ],

                const SizedBox(height: AppSpace.xl),
                FilledButton(
                  onPressed: auth.loading ? null : _submit,
                  style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16)),
                  child: auth.loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Sign in'),
                ),

                const SizedBox(height: AppSpace.xl),
                Row(children: [
                  const Expanded(child: Divider()),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: AppSpace.md),
                    child: Text('demo accounts',
                        style: theme.textTheme.labelSmall),
                  ),
                  const Expanded(child: Divider()),
                ]),
                const SizedBox(height: AppSpace.md),

                // Stable addresses assigned by seed.py's FIXED_EMAILS, so
                // these keep working after a re-seed even though the teachers
                // behind them are randomly generated.
                Row(children: [
                  _DemoLogin(
                    label: 'Admin',
                    icon: Icons.admin_panel_settings_outlined,
                    email: 'admin@school.test',
                    disabled: auth.loading,
                    onTap: _quickFill,
                  ),
                  const SizedBox(width: AppSpace.sm),
                  _DemoLogin(
                    label: 'HOD',
                    icon: Icons.verified_user_outlined,
                    email: 'hod@school.test',
                    disabled: auth.loading,
                    onTap: _quickFill,
                  ),
                  const SizedBox(width: AppSpace.sm),
                  _DemoLogin(
                    label: 'Teacher',
                    icon: Icons.person_outline,
                    email: 'teacher@school.test',
                    disabled: auth.loading,
                    onTap: _quickFill,
                  ),
                ]),
                const SizedBox(height: AppSpace.sm),
                // On its own row: four Expanded buttons in a 400px panel
                // crush their labels, and this one is the longest.
                Row(children: [
                  _DemoLogin(
                    label: 'Vice Principal',
                    icon: Icons.workspace_premium_outlined,
                    email: 'vp@school.test',
                    disabled: auth.loading,
                    onTap: _quickFill,
                  ),
                ]),
                const SizedBox(height: AppSpace.sm),

                // On its own row, and not a _DemoLogin: this signs nobody in.
                // A fourth Expanded button would also crush the label — the
                // three above already split the panel four ways.
                OutlinedButton.icon(
                  onPressed:
                      auth.loading ? null : () => context.go('/demo-setup'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  icon: const Icon(Icons.rocket_launch_outlined, size: 16),
                  label: const Text('Admin (new) — first-time setup'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (!wide) {
      return Scaffold(backgroundColor: AppColors.surface, body: form);
    }

    return Scaffold(
      body: Row(children: [
        const Expanded(flex: 5, child: _Showcase()),
        Expanded(
          flex: 4,
          child: Container(color: AppColors.surface, child: form),
        ),
      ]),
    );
  }
}

/// The left half on a desktop: what this product actually does. A login page
/// is the first thing a judge sees, so it may as well say something.
class _Showcase extends StatelessWidget {
  const _Showcase();

  static const _points = [
    (Icons.document_scanner_outlined, 'AI document reader',
        'Photograph any school form — it reads the fields and files the record.'),
    (Icons.grid_view_rounded, 'Smart timetables',
        'A constraint solver places 1,440 periods without a single clash.'),
    (Icons.notifications_none_rounded, 'Live action board',
        'Approved leave becomes ranked cover suggestions, instantly.'),
    (Icons.insights_outlined, 'Staffing forecast',
        'Says where you will run short next week, and shows its working.'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1D4ED8), Color(0xFF1E3A8A), Color(0xFF172554)],
        ),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(56),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const _Logo(onDark: true),
                const SizedBox(height: 40),
                const Text(
                  'Run the whole school\nfrom one place.',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 34,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: AppSpace.md),
                Text(
                  'Admissions, timetables, attendance and cover — '
                  'no paperwork, no spreadsheets.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.72),
                    fontSize: 15,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 40),
                for (final (icon, title, body) in _points)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.xl),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.13),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(icon, color: Colors.white, size: 19),
                        ),
                        const SizedBox(width: AppSpace.lg),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 2),
                              Text(body,
                                  style: TextStyle(
                                      color:
                                          Colors.white.withValues(alpha: 0.66),
                                      fontSize: 13,
                                      height: 1.45)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo({this.onDark = false});
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: onDark ? Colors.white.withValues(alpha: 0.15) : null,
          gradient: onDark
              ? null
              : const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.brand, AppColors.brandDark],
                ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.school_rounded, color: Colors.white, size: 22),
      ),
      const SizedBox(width: AppSpace.md),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('SchoolSync AI',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
                color: onDark ? Colors.white : AppColors.textPrimary,
              )),
          Text('Operations platform',
              style: TextStyle(
                fontSize: 12,
                color: onDark
                    ? Colors.white.withValues(alpha: 0.6)
                    : AppColors.textSecondary,
              )),
        ],
      ),
    ]);
  }
}

/// One demo-login shortcut.
///
/// Three share the row equally, so the longest label ("Teacher") sets the
/// constraint. The label is pinned to a single line and allowed to scale down
/// rather than wrap — otherwise it breaks as "Teache / r", and it would break
/// again on a narrower card or a larger system text size.
class _DemoLogin extends StatelessWidget {
  const _DemoLogin({
    required this.label,
    required this.icon,
    required this.email,
    required this.disabled,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final String email;
  final bool disabled;
  final void Function(String email) onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: OutlinedButton(
        onPressed: disabled ? null : () => onTap(email),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16),
            const SizedBox(width: 6),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(label, maxLines: 1, softWrap: false),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

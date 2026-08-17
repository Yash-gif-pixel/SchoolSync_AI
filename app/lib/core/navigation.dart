import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Leaving a screen that might have been arrived at directly.
///
/// Every detail screen in this app is reachable two ways: pushed from the list
/// it belongs to, and typed straight into the address bar. On the web the
/// second is not a curiosity — it is what a bookmark, a shared link, and above
/// all a page refresh all do.
///
/// `Navigator.pop` only works for the first. Arriving by URL leaves nothing
/// underneath, so popping either throws or empties the app to a blank page.
/// This closes the screen the way the situation allows, and makes sure the
/// outcome is still reported when there is no caller left to report it.
void closeScreen(
  BuildContext context, {
  required String fallback,
  String? result,
}) {
  // maybeOf, not of: the widget tests render these screens standalone under a
  // plain MaterialApp, and `of` throws when there is no router above.
  final router = GoRouter.maybeOf(context);

  if (router == null) {
    Navigator.of(context).maybePop(result);
    return;
  }

  if (router.canPop()) {
    router.pop(result);
    return;
  }

  // Nothing behind us. The caller that would have shown this message does not
  // exist, so say it here — the app-level ScaffoldMessenger keeps a SnackBar
  // alive across the navigation that follows.
  if (result != null && result.isNotEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
  }
  context.go(fallback);
}

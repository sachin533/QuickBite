import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../state/auth_controller.dart';

/// Sign-in with explicit loading / invalid-credential / network-error /
/// session-expired states and keyboard-friendly form behaviour.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, this.pendingRoute});

  /// Route to open after a successful sign-in (deep link across reload).
  final String? pendingRoute;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _DemoAccount {
  const _DemoAccount(this.label, this.email, this.password);
  final String label;
  final String email;
  final String password;
}

const _demoAccounts = [
  _DemoAccount('Customer · Maya', 'maya@quickbite.dev', 'demo12345'),
  _DemoAccount('Customer · Arjun', 'arjun@quickbite.dev', 'demo12345'),
  _DemoAccount('Admin', 'admin@quickbite.dev', 'admin12345'),
];

class _SignInScreenState extends State<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscure = true;
  ApiException? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final form = _formKey.currentState;
    if (form == null || !form.validate()) return;
    final auth = context.read<AuthController>();
    setState(() => _error = null);
    try {
      await auth.signIn(
        _emailController.text,
        _passwordController.text,
      );
      if (!mounted) return;
      if (auth.isSignedIn) {
        // If a RouteGuard hosts this screen it already swapped in the
        // protected child (mounted went false); otherwise build a fresh
        // stack rooted at the deep link (or the home shell).
        Navigator.of(context).pushNamedAndRemoveUntil(
          widget.pendingRoute ?? '/',
          (route) => false,
        );
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final signingIn = auth.signingIn;
    final theme = Theme.of(context);
    final expired = auth.sessionExpired;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                elevation: 0,
                color: theme.colorScheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Semantics(
                          header: true,
                          child: Text(
                            'QuickBite',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Sign in to browse menus and track orders',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 20),
                        if (expired) ...[
                          Material(
                            color: theme.colorScheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                children: [
                                  const Icon(Icons.timer_outlined, size: 20),
                                  const SizedBox(width: 8),
                                  const Expanded(
                                    child: Text(
                                      'Your session expired. Please sign in '
                                      'again.',
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () => context
                                        .read<AuthController>()
                                        .signOut(),
                                    child: const Text('Dismiss'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        TextFormField(
                          controller: _emailController,
                          enabled: !signingIn,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.email],
                          decoration: const InputDecoration(
                            labelText: 'Email',
                            prefixIcon: Icon(Icons.email_outlined),
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) {
                            final v = value?.trim() ?? '';
                            if (v.isEmpty) return 'Email is required';
                            if (!v.contains('@')) {
                              return 'Enter a valid email address';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _passwordController,
                          enabled: !signingIn,
                          obscureText: _obscure,
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: (_) => _submit(),
                          autofillHints: const [AutofillHints.password],
                          decoration: InputDecoration(
                            labelText: 'Password',
                            prefixIcon: const Icon(Icons.lock_outline),
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              tooltip: _obscure
                                  ? 'Show password'
                                  : 'Hide password',
                              onPressed: () =>
                                  setState(() => _obscure = !_obscure),
                              icon: Icon(_obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined),
                            ),
                          ),
                          validator: (value) => (value == null || value.isEmpty)
                              ? 'Password is required'
                              : null,
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          Semantics(
                            liveRegion: true,
                            container: true,
                            child: Material(
                              color: _error!.kind == ApiErrorKind.network ||
                                      _error!.kind == ApiErrorKind.timeout
                                  ? theme.colorScheme.tertiaryContainer
                                  : theme.colorScheme.errorContainer,
                              borderRadius: BorderRadius.circular(8),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  children: [
                                    Icon(
                                      _error!.kind == ApiErrorKind.network ||
                                              _error!.kind ==
                                                  ApiErrorKind.timeout
                                          ? Icons.cloud_off
                                          : Icons.error_outline,
                                      size: 20,
                                      color: _error!.kind ==
                                                  ApiErrorKind.network ||
                                              _error!.kind ==
                                                  ApiErrorKind.timeout
                                          ? theme
                                              .colorScheme.onTertiaryContainer
                                          : theme.colorScheme.onErrorContainer,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        _error!.userMessage,
                                        style: TextStyle(
                                          color: _error!.kind ==
                                                      ApiErrorKind.network ||
                                                  _error!.kind ==
                                                      ApiErrorKind.timeout
                                              ? theme.colorScheme
                                                  .onTertiaryContainer
                                              : theme.colorScheme
                                                  .onErrorContainer,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: signingIn ? null : _submit,
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: signingIn
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('Sign in'),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'Seeded demo accounts (tap to fill):',
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final account in _demoAccounts)
                              ActionChip(
                                avatar: const Icon(Icons.person_outline,
                                    size: 18),
                                label: Text(account.label),
                                onPressed: signingIn
                                    ? null
                                    : () {
                                        setState(() => _error = null);
                                        _emailController.text = account.email;
                                        _passwordController.text =
                                            account.password;
                                      },
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

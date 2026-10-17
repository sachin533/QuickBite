import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_exception.dart';
import '../core/theme.dart';
import '../state/auth_controller.dart';
import '../widgets/brand.dart';
import '../widgets/food_image.dart';

/// Two-column sign-in (reference layout 1): a compact form on the left and a
/// large circular orange graphic with real food photography on the right.
///
/// Performance note: this screen renders on its own. It never waits on the
/// restaurant list, the food catalogue, order history or any optional
/// service, so first paint is a single local request away from the API.
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

const _rememberEmailKey = 'quickbite.remembered_email';

/// Reference photograph for the login graphic — bundled with the app so the
/// page paints instantly and works offline.
const _loginPhoto = 'assets/food/chicken_dum_biryani.jpg';

class _SignInScreenState extends State<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscure = true;
  bool _rememberEmail = true;
  ApiException? _error;

  @override
  void initState() {
    super.initState();
    // Prefill the remembered address (never the password).
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreEmail());
  }

  Future<void> _restoreEmail() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_rememberEmailKey);
      if (saved != null && saved.isNotEmpty && mounted) {
        _emailController.text = saved;
      }
    } catch (_) {
      // Preferences are best-effort; the form still works without them.
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _remember(String email) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_rememberEmail && email.isNotEmpty) {
        await prefs.setString(_rememberEmailKey, email);
      } else {
        await prefs.remove(_rememberEmailKey);
      }
    } catch (_) {
      // Best effort.
    }
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
      await _remember(_emailController.text.trim());
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

  void _info(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final signingIn = auth.signingIn;

    return Scaffold(
      backgroundColor: Brand.warmBg,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 800;
            if (wide) {
              return Row(
                children: [
                  Expanded(flex: 5, child: _buildFormColumn(context, signingIn)),
                  Expanded(flex: 5, child: const _LoginGraphic(compact: false)),
                ],
              );
            }
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _LoginGraphic(compact: true),
                  const SizedBox(height: 20),
                  _buildForm(context, signingIn),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildFormColumn(BuildContext context, bool signingIn) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: _buildForm(context, signingIn),
        ),
      ),
    );
  }

  Widget _buildForm(BuildContext context, bool signingIn) {
    final theme = Theme.of(context);
    final expired = context.watch<AuthController>().sessionExpired;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const QuickBiteLogo(),
        const SizedBox(height: 22),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  'Login',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.6,
                  ),
                ),
              ),
            ),
            TextButton(
              onPressed: signingIn
                  ? null
                  : () => _info(
                        'Accounts are created by QuickBite ops in this demo. '
                        'Use one of the seeded accounts below to sign in.',
                      ),
              child: const Text('Sign Up'),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          'Welcome back — sign in to browse menus and track your orders.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: Brand.inkSoft),
        ),
        const SizedBox(height: 20),
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _emailController,
                enabled: !signingIn,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(
                  labelText: 'Email',
                  hintText: 'you@example.com',
                  prefixIcon: Icon(Icons.email_outlined),
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
              const SizedBox(height: 14),
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
                  suffixIcon: IconButton(
                    tooltip: _obscure ? 'Show password' : 'Hide password',
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(_obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                  ),
                ),
                validator: (value) => (value == null || value.isEmpty)
                    ? 'Password is required'
                    : null,
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 0,
          children: [
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              runSpacing: 0,
              children: [
                Checkbox(
                  value: _rememberEmail,
                  visualDensity: VisualDensity.compact,
                  onChanged: signingIn
                      ? null
                      : (value) => setState(
                            () => _rememberEmail = value ?? false,
                          ),
                ),
                GestureDetector(
                  onTap: signingIn
                      ? null
                      : () => setState(
                            () => _rememberEmail = !_rememberEmail,
                          ),
                  child: const Text('Remember my email'),
                ),
              ],
            ),
            TextButton(
              onPressed: signingIn
                  ? null
                  : () => _info(
                        'Password resets are handled by QuickBite ops in this '
                        'demo — no self-service reset is available yet.',
                      ),
              child: const Text('Forgot password?'),
            ),
          ],
        ),
        if (expired) ...[
          const SizedBox(height: 12),
          _NoticeCard(
            icon: Icons.timer_outlined,
            background: theme.colorScheme.secondaryContainer,
            foreground: theme.colorScheme.onSecondaryContainer,
            message: 'Your session expired. Please sign in again.',
            action: TextButton(
              onPressed: () => context.read<AuthController>().signOut(),
              child: const Text('Dismiss'),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          _NoticeCard(
            icon: _error!.kind == ApiErrorKind.network ||
                    _error!.kind == ApiErrorKind.timeout
                ? Icons.cloud_off
                : Icons.error_outline,
            background: _error!.kind == ApiErrorKind.network ||
                    _error!.kind == ApiErrorKind.timeout
                ? theme.colorScheme.tertiaryContainer
                : theme.colorScheme.errorContainer,
            foreground: _error!.kind == ApiErrorKind.network ||
                    _error!.kind == ApiErrorKind.timeout
                ? theme.colorScheme.onTertiaryContainer
                : theme.colorScheme.onErrorContainer,
            message: _error!.userMessage,
          ),
        ],
        const SizedBox(height: 18),
        Semantics(
          button: true,
          label: 'Sign in',
          child: FilledButton(
            onPressed: signingIn ? null : _submit,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 15),
            ),
            child: signingIn
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Sign in'),
          ),
        ),
        const SizedBox(height: 22),
        Text(
          'Seeded demo accounts — tap one to fill the form',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: Brand.inkSoft),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final account in _demoAccounts)
              ActionChip(
                avatar: const Icon(Icons.person_outline, size: 18),
                label: Text(account.label),
                onPressed: signingIn
                    ? null
                    : () {
                        setState(() => _error = null);
                        _emailController.text = account.email;
                        _passwordController.text = account.password;
                      },
              ),
          ],
        ),
      ],
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.background,
    required this.foreground,
    required this.message,
    this.action,
  });

  final IconData icon;
  final Color background;
  final Color foreground;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      container: true,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Icon(icon, size: 20, color: foreground),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: foreground),
                ),
              ),
              ?action,
            ],
          ),
        ),
      ),
    );
  }
}

/// The orange graphic panel: a large circular plate of real food photography
/// on a warm gradient, with brand copy underneath.
class _LoginGraphic extends StatelessWidget {
  const _LoginGraphic({required this.compact});

  /// true → slim stacked banner for phones; false → full-height panel.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (compact) {
      // The banner grows with the text scale so the copy and rating pills
      // always fit inside it instead of spilling past the gradient.
      final scale = MediaQuery.textScalerOf(context)
          .scale(1.0)
          .clamp(1.0, 1.6)
          .toDouble();
      return Container(
        height: 138 + (scale - 1.0) * 84,
        decoration: BoxDecoration(
          gradient: Brand.heroGradient,
          borderRadius: BorderRadius.circular(22),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned(
              right: -30,
              top: -40,
              child: _ring(size: 130, alpha: 0.16),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  ClipOval(
                    child: SizedBox(
                      width: 108,
                      height: 108,
                      child: FoodImage(
                        url: _loginPhoto,
                        icon: Icons.ramen_dining_rounded,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Fresh kitchens, delivered fast.',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 12,
                          runSpacing: 4,
                          children: const [
                            MetaPill(
                              icon: Icons.star_rounded,
                              label: '4.6 avg',
                              onDark: true,
                              color: Colors.white,
                            ),
                            MetaPill(
                              icon: Icons.schedule_rounded,
                              label: '20–35 min',
                              onDark: true,
                              color: Colors.white,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight =
            constraints.maxHeight.isFinite ? constraints.maxHeight : 720.0;
        // Leave room for the headline (and, when there is space, the body
        // copy and the proof pills) so the panel never overflows.
        final plate =
            (availableHeight * 0.42).clamp(150.0, 340.0).toDouble();
        final roomy = availableHeight >= 700;

        return Container(
          decoration: const BoxDecoration(gradient: Brand.heroGradient),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Positioned(top: -70, right: -50, child: _ring(size: 260, alpha: 0.14)),
              Positioned(bottom: -90, left: -60, child: _ring(size: 300, alpha: 0.10)),
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: plate,
                        height: plate,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.18),
                              blurRadius: 40,
                              offset: const Offset(0, 18),
                            ),
                          ],
                        ),
                        padding: const EdgeInsets.all(12),
                        child: ClipOval(
                          child: FoodImage(
                            url: _loginPhoto,
                            icon: Icons.ramen_dining_rounded,
                          ),
                        ),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        'Delicious food,\ndelivered fast.',
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                          height: 1.15,
                        ),
                      ),
                      if (roomy) ...[
                        const SizedBox(height: 10),
                        Text(
                          'Hot kitchens near you, live order tracking and '
                          'checkout in under a minute.',
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.white.withValues(alpha: 0.9)),
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 18,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: const [
                            MetaPill(
                              icon: Icons.star_rounded,
                              label: '4.6 average rating',
                              onDark: true,
                              color: Colors.white,
                            ),
                            MetaPill(
                              icon: Icons.schedule_rounded,
                              label: '20–35 min delivery',
                              onDark: true,
                              color: Colors.white,
                            ),
                            MetaPill(
                              icon: Icons.payments_outlined,
                              label: 'INR pricing',
                              onDark: true,
                              color: Colors.white,
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _ring({required double size, required double alpha}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: alpha),
          width: 18,
        ),
      ),
    );
  }
}

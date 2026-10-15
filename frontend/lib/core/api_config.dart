/// Compile-time configuration.
///
/// `API_BASE_URL` is public build configuration (not a secret), supplied with
/// `--dart-define=API_BASE_URL=...`:
///
///   flutter run  -d chrome --dart-define=API_BASE_URL=http://localhost:8000
///   flutter run  -d emulator --dart-define=API_BASE_URL=http://10.0.2.2:8000
///   flutter build web --dart-define=API_BASE_URL=http://localhost:8000
class ApiConfig {
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8000',
  );
}

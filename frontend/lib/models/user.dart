class UserSummary {
  const UserSummary({
    required this.id,
    required this.email,
    required this.fullName,
    required this.role,
  });

  final String id;
  final String email;
  final String fullName;
  final String role;

  bool get isAdmin => role == 'admin';

  factory UserSummary.fromJson(Object? json) {
    final map = json as Map<String, dynamic>;
    return UserSummary(
      id: map['id'] as String,
      email: map['email'] as String? ?? '',
      fullName: map['full_name'] as String? ?? '',
      role: map['role'] as String? ?? 'customer',
    );
  }
}

/// POST /api/v1/auth/login response.
class LoginSession {
  const LoginSession({
    required this.accessToken,
    required this.expiresIn,
    required this.expiresAt,
    required this.role,
    required this.user,
  });

  final String accessToken;
  final int expiresIn;
  final String expiresAt;
  final String role;
  final UserSummary user;

  factory LoginSession.fromJson(Map<String, dynamic> json) => LoginSession(
        accessToken: json['access_token'] as String,
        expiresIn: (json['expires_in'] as num?)?.toInt() ?? 0,
        expiresAt: json['expires_at'] as String? ?? '',
        role: json['role'] as String? ?? 'customer',
        user: UserSummary.fromJson(json['user']),
      );
}

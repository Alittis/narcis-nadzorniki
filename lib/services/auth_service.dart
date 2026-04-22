import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class AuthResult {
  const AuthResult({required this.success, this.user, this.message});

  final bool success;
  final String? user;
  final String? message;
}

class AuthService {
  AuthService({http.Client? client, Uri? endpoint})
      : _client = client ?? http.Client(),
        _endpoint = endpoint ??
            Uri.parse(
              'https://storitve.igea.si/narcis/ords/narcis/test/auth',
            );

  final http.Client _client;
  final Uri _endpoint;

  Future<AuthResult> login(String email, String password) async {
    try {
      final response = await _client.get(
        _endpoint,
        headers: {'username': email.trim()},
      ).timeout(const Duration(seconds: 15));

      final body = response.body.isEmpty
          ? const <String, dynamic>{}
          : jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200 && body['authenticated'] == true) {
        return AuthResult(
          success: true,
          user: body['user'] as String? ?? email.trim(),
        );
      }
      return AuthResult(
        success: false,
        message: body['message'] as String? ?? 'Prijava ni uspela.',
      );
    } on TimeoutException {
      return const AuthResult(
        success: false,
        message: 'Strežnik se ne odziva.',
      );
    } catch (_) {
      return const AuthResult(
        success: false,
        message: 'Napaka pri povezavi s strežnikom.',
      );
    }
  }
}

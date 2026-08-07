import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/forecast.dart';
import 'config.dart';

class ForecastRepository {
  const ForecastRepository();

  Future<StaffingForecast> staffing({int horizonDays = 21}) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    final bearer = token == null ? null : 'Bearer $token';

    final res = await http.get(
      Uri.parse('${AppConfig.apiBaseUrl}/forecast/staffing')
          .replace(queryParameters: {'horizon_days': '$horizonDays'}),
      headers: {'Authorization': ?bearer},
    ).timeout(const Duration(seconds: 90));

    if (res.statusCode >= 400) {
      throw Exception(switch (res.statusCode) {
        401 => 'Please sign in again.',
        _ => 'Could not load the forecast (${res.statusCode}).',
      });
    }
    return StaffingForecast.fromMap(
      jsonDecode(res.body) as Map<String, dynamic>,
    );
  }
}

final forecastRepositoryProvider =
    Provider<ForecastRepository>((_) => const ForecastRepository());

final staffingForecastProvider = FutureProvider<StaffingForecast>((ref) async {
  return ref.read(forecastRepositoryProvider).staffing();
});

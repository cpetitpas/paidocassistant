import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'logging_service.dart';

class PurchaseService {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final LoggingService _loggingService = LoggingService();
  static const String _trialStartKey = "trial_start";
  static const String _lifetimeKey = "lifetime_purchase";
  static const String _subscriptionExpiryKey = "subscription_expiry";

  Future<void> startTrial() async {
    final startDate = DateTime.now().toIso8601String();
    await _storage.write(key: _trialStartKey, value: startDate);
    _loggingService.log("Trial started at $startDate");
  }

  Future<void> setTrialStart(String startDate) async {
    await _storage.write(key: _trialStartKey, value: startDate);
    _loggingService.log("Trial start set to $startDate");
  }

  Future<String?> getTrialStart() async {
    return await _storage.read(key: _trialStartKey);
  }

  Future<bool> isTrialActive() async {
    final startStr = await _storage.read(key: _trialStartKey);
    if (startStr == null) return false;
    final startDate = DateTime.parse(startStr);
    return DateTime.now().isBefore(startDate.add(const Duration(days: 14)));
  }

  Future<int> remainingTrialDays() async {
    final startStr = await _storage.read(key: _trialStartKey);
    if (startStr == null) return 0;
    final startDate = DateTime.parse(startStr);
    final diff = DateTime.now().difference(startDate).inDays;
    return (14 - diff).clamp(0, 14); // min 0, max 14
  }

  Future<bool> hasLifetime() async {
    final value = await _storage.read(key: _lifetimeKey);
    return value == "true";
  }

  Future<void> setLifetime(bool purchased) async {
    await _storage.write(key: _lifetimeKey, value: purchased.toString());
    _loggingService.log("Lifetime purchase set to $purchased");
  }

  Future<DateTime?> subscriptionExpiry() async {
    final expiryStr = await _storage.read(key: _subscriptionExpiryKey);
    if (expiryStr == null) return null;
    return DateTime.parse(expiryStr);
  }

  Future<void> extendSubscription({required int days}) async {
    final now = DateTime.now();
    final currentExpiry = await subscriptionExpiry();
    final newExpiry = (currentExpiry != null && currentExpiry.isAfter(now)
            ? currentExpiry
            : now)
        .add(Duration(days: days));
    await _storage.write(
        key: _subscriptionExpiryKey, value: newExpiry.toIso8601String());
    _loggingService.log("Subscription extended to $newExpiry");
  }

  Future<bool> hasValidSubscription() async {
    final expiry = await subscriptionExpiry();
    return expiry != null && DateTime.now().isBefore(expiry);
  }

  Future<bool> isEntitled() async {
    return await hasLifetime() || await hasValidSubscription() || await isTrialActive();
  }
}
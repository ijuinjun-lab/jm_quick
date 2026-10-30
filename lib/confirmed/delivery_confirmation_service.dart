import 'test_mail_page.dart';

/// Reuses the authenticated callable transport; never accesses Firestore directly.
class DeliveryConfirmationService {
  DeliveryConfirmationService({TestMailService? transport})
    : transport = transport ?? TestMailService();
  final TestMailService transport;
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> data) =>
      transport.call(name, data);
}

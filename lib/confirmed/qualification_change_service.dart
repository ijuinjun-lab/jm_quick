abstract class QualificationChangeService {
  Future<Map<String, dynamic>> getQualifications(
    String eventId,
    String participantId,
  );
  Future<void> changeQualification(Map<String, dynamic> request);
}

abstract class QualificationNoticeService {
  Future<Map<String, dynamic>> previewNotice(Map<String, dynamic> request);
  Future<Map<String, dynamic>> sendNotice(Map<String, dynamic> request);
  Future<void> reviewDelivery(Map<String, dynamic> request);
}

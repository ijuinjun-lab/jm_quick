abstract class QualificationChangeService {
  Future<Map<String, dynamic>> getQualifications(
    String eventId,
    String participantId,
  );
  Future<void> changeQualification(Map<String, dynamic> request);
}

enum EventStatus {
  registration('正式登録期間'),
  awaitingConfirmation('受付中'),
  confirmation('参加予定確認期間'),
  eventDay('開催当日'),
  ended('終了');

  const EventStatus(this.label);
  final String label;
}

EventStatus calculateEventStatus({
  required DateTime now,
  required DateTime startAt,
  DateTime? endAt,
  required DateTime registrationDeadline,
  required DateTime confirmationSendAt,
}) {
  final effectiveEnd = endAt ?? startAt.add(const Duration(hours: 4));
  final eventDayStart = DateTime(startAt.year, startAt.month, startAt.day);
  if (!now.isBefore(effectiveEnd)) return EventStatus.ended;
  if (!now.isBefore(eventDayStart)) return EventStatus.eventDay;
  if (!now.isBefore(confirmationSendAt)) return EventStatus.confirmation;
  if (!now.isBefore(registrationDeadline)) {
    return EventStatus.awaitingConfirmation;
  }
  return EventStatus.registration;
}

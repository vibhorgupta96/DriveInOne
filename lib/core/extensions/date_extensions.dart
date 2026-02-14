import 'package:intl/intl.dart';

extension DateTimeExtensions on DateTime {
  String get timelineGroupLabel {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(year, month, day);

    final diff = today.difference(date).inDays;

    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff < 7) return DateFormat('EEEE').format(this);
    if (year == now.year) return DateFormat('MMMM d').format(this);
    return DateFormat('MMMM d, yyyy').format(this);
  }

  DateTime get dateOnly => DateTime(year, month, day);

  bool isSameDay(DateTime other) =>
      year == other.year && month == other.month && day == other.day;
}

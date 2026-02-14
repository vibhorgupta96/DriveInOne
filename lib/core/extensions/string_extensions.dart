extension StringExtensions on String? {
  bool get isNullOrEmpty => this == null || this!.isEmpty;
  bool get isNotNullOrEmpty => !isNullOrEmpty;
  String orDefault(String defaultValue) => isNullOrEmpty ? defaultValue : this!;
}

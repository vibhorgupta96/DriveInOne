import 'package:equatable/equatable.dart';

/// A provider-resolved media endpoint and the headers required to read it.
///
/// Some providers return short-lived signed URLs with no headers, while
/// others expose stable API URLs that require a bearer token.
class ResolvedMedia extends Equatable {
  final Uri uri;
  final Map<String, String> headers;

  const ResolvedMedia({required this.uri, this.headers = const {}});

  @override
  List<Object?> get props => [uri, headers];
}

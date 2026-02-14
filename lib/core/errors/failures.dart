import 'package:equatable/equatable.dart';

abstract class Failure extends Equatable {
  final String message;
  const Failure({required this.message});

  @override
  List<Object?> get props => [message];
}

class AuthFailure extends Failure {
  const AuthFailure({required super.message});
}

class SyncFailure extends Failure {
  const SyncFailure({required super.message});
}

class ApiFailure extends Failure {
  final int? statusCode;
  const ApiFailure({required super.message, this.statusCode});

  @override
  List<Object?> get props => [message, statusCode];
}

class StorageFailure extends Failure {
  const StorageFailure({required super.message});
}

class FaceRecognitionFailure extends Failure {
  const FaceRecognitionFailure({required super.message});
}

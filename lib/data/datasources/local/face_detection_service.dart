import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../../../core/utils/logger.dart';

class FaceDetectionException implements Exception {
  final String message;
  final Object cause;

  const FaceDetectionException(this.message, this.cause);

  @override
  String toString() => '$message: $cause';
}

class DetectedFace {
  final Rect boundingBox;
  final Point<double>? leftEye;
  final Point<double>? rightEye;
  final double? headEulerAngleY;
  final double? headEulerAngleZ;

  const DetectedFace({
    required this.boundingBox,
    this.leftEye,
    this.rightEye,
    this.headEulerAngleY,
    this.headEulerAngleZ,
  });

  /// Rotation angle (degrees) to make the eyes horizontal.
  /// Positive = clockwise tilt of the face.
  double? get eyeRotationDegrees {
    if (leftEye == null || rightEye == null) return null;
    return atan2(rightEye!.y - leftEye!.y, rightEye!.x - leftEye!.x) *
        180.0 /
        pi;
  }
}

class FaceDetectionService {
  late FaceDetector _faceDetector;

  FaceDetectionService() {
    _faceDetector = _createDetector();
  }

  FaceDetector _createDetector() {
    return FaceDetector(
      options: FaceDetectorOptions(
        enableLandmarks: true,
        enableContours: false,
        enableClassification: false,
        enableTracking: false,
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.15,
      ),
    );
  }

  Future<void> _reinitializeDetector() async {
    try {
      await _faceDetector.close();
    } catch (_) {}
    _faceDetector = _createDetector();
  }

  DetectedFace _toDetectedFace(Face face) {
    final leftEyeLandmark = face.landmarks[FaceLandmarkType.leftEye];
    final rightEyeLandmark = face.landmarks[FaceLandmarkType.rightEye];

    return DetectedFace(
      boundingBox: face.boundingBox,
      leftEye: leftEyeLandmark != null
          ? Point<double>(
              leftEyeLandmark.position.x.toDouble(),
              leftEyeLandmark.position.y.toDouble(),
            )
          : null,
      rightEye: rightEyeLandmark != null
          ? Point<double>(
              rightEyeLandmark.position.x.toDouble(),
              rightEyeLandmark.position.y.toDouble(),
            )
          : null,
      headEulerAngleY: face.headEulerAngleY,
      headEulerAngleZ: face.headEulerAngleZ,
    );
  }

  /// Detects faces in an image from bytes.
  Future<List<DetectedFace>> detectFaces(
    Uint8List imageBytes, {
    required int imageWidth,
    required int imageHeight,
  }) async {
    try {
      final inputImage = InputImage.fromBytes(
        bytes: imageBytes,
        metadata: InputImageMetadata(
          size: Size(imageWidth.toDouble(), imageHeight.toDouble()),
          rotation: InputImageRotation.rotation0deg,
          format: InputImageFormat.nv21,
          bytesPerRow: imageWidth,
        ),
      );

      final faces = await _faceDetector.processImage(inputImage);
      return faces.map(_toDetectedFace).toList();
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('precondition')) {
        AppLogger.warning(
          'Face detector precondition failed (bytes), recreating detector and retrying once',
        );
        try {
          await _reinitializeDetector();
          final inputImage = InputImage.fromBytes(
            bytes: imageBytes,
            metadata: InputImageMetadata(
              size: Size(imageWidth.toDouble(), imageHeight.toDouble()),
              rotation: InputImageRotation.rotation0deg,
              format: InputImageFormat.nv21,
              bytesPerRow: imageWidth,
            ),
          );
          final faces = await _faceDetector.processImage(inputImage);
          return faces.map(_toDetectedFace).toList();
        } catch (retryError) {
          AppLogger.error('Face detection retry failed', error: retryError);
          throw FaceDetectionException(
            'Face detection retry failed',
            retryError,
          );
        }
      }
      AppLogger.error('Face detection failed', error: e);
      throw FaceDetectionException('Face detection failed', e);
    }
  }

  /// Detects faces from a file path (more reliable for decoded images).
  Future<List<DetectedFace>> detectFacesFromFile(String filePath) async {
    try {
      final inputImage = InputImage.fromFilePath(filePath);
      final faces = await _faceDetector.processImage(inputImage);
      return faces.map(_toDetectedFace).toList();
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('precondition')) {
        AppLogger.warning(
          'Face detector precondition failed (file), recreating detector and retrying once',
        );
        try {
          await _reinitializeDetector();
          final inputImage = InputImage.fromFilePath(filePath);
          final faces = await _faceDetector.processImage(inputImage);
          return faces.map(_toDetectedFace).toList();
        } catch (retryError) {
          AppLogger.error(
            'Face detection from file retry failed',
            error: retryError,
          );
          throw FaceDetectionException(
            'Face detection from file retry failed',
            retryError,
          );
        }
      }
      AppLogger.error('Face detection from file failed', error: e);
      throw FaceDetectionException('Face detection from file failed', e);
    }
  }

  void dispose() {
    _faceDetector.close();
  }
}

import 'dart:typed_data';
import 'dart:ui';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../../../core/utils/logger.dart';

class FaceDetectionService {
  late final FaceDetector _faceDetector;

  FaceDetectionService() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableLandmarks: false,
        enableContours: false,
        enableClassification: false,
        enableTracking: false,
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.1,
      ),
    );
  }

  /// Detects faces in an image from bytes.
  /// Returns list of bounding boxes as Rect.
  Future<List<Rect>> detectFaces(Uint8List imageBytes, {
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
      return faces.map((face) => face.boundingBox).toList();
    } catch (e) {
      AppLogger.error('Face detection failed', error: e);
      return [];
    }
  }

  /// Detects faces from a file path (more reliable for decoded images).
  Future<List<Rect>> detectFacesFromFile(String filePath) async {
    try {
      final inputImage = InputImage.fromFilePath(filePath);
      final faces = await _faceDetector.processImage(inputImage);
      return faces.map((face) => face.boundingBox).toList();
    } catch (e) {
      AppLogger.error('Face detection from file failed', error: e);
      return [];
    }
  }

  void dispose() {
    _faceDetector.close();
  }
}

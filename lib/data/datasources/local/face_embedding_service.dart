import 'dart:math';
import 'dart:typed_data';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import '../../../core/constants/app_constants.dart';
import '../../../core/utils/logger.dart';

class FaceEmbeddingService {
  Interpreter? _interpreter;
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;

  Future<void> initialize() async {
    try {
      _interpreter = await Interpreter.fromAsset(
        'assets/models/mobilefacenet.tflite',
      );
      _isInitialized = true;
      AppLogger.info('MobileFaceNet model loaded successfully');
    } catch (e) {
      AppLogger.error('Failed to load MobileFaceNet model', error: e);
      rethrow;
    }
  }

  /// Takes cropped face image bytes, returns 192-dim L2-normalized embedding.
  Future<List<double>> getEmbedding(Uint8List croppedFaceBytes) async {
    if (!_isInitialized || _interpreter == null) {
      throw StateError('FaceEmbeddingService not initialized');
    }

    final input = _preprocessFace(croppedFaceBytes);
    final output = List.filled(
      AppConstants.faceEmbeddingDimension,
      0.0,
    ).reshape([1, AppConstants.faceEmbeddingDimension]);

    _interpreter!.run(input, output);

    final embedding = List<double>.from(output[0] as List);
    return _l2Normalize(embedding);
  }

  /// Convert embedding to bytes for DB storage.
  static Uint8List embeddingToBytes(List<double> embedding) {
    final float32List = Float32List.fromList(
      embedding.map((e) => e.toDouble()).toList(),
    );
    return float32List.buffer.asUint8List();
  }

  /// Convert bytes from DB back to embedding.
  static List<double> bytesToEmbedding(Uint8List bytes) {
    final float32List = bytes.buffer.asFloat32List();
    return float32List.toList();
  }

  Float32List _preprocessFace(Uint8List bytes) {
    final image = img.decodeImage(bytes);
    if (image == null) {
      throw ArgumentError('Failed to decode face image');
    }

    const size = AppConstants.faceInputSize;
    final resized = img.copyResize(image, width: size, height: size);
    final float32 = Float32List(1 * size * size * 3);

    int idx = 0;
    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        final pixel = resized.getPixel(x, y);
        float32[idx++] = (pixel.r / 127.5) - 1.0;
        float32[idx++] = (pixel.g / 127.5) - 1.0;
        float32[idx++] = (pixel.b / 127.5) - 1.0;
      }
    }
    return float32;
  }

  List<double> _l2Normalize(List<double> vec) {
    final norm = sqrt(vec.fold(0.0, (sum, v) => sum + v * v));
    if (norm == 0) return vec;
    return vec.map((v) => v / norm).toList();
  }

  void dispose() {
    _interpreter?.close();
    _isInitialized = false;
  }
}

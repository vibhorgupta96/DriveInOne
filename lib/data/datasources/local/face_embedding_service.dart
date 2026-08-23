import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart' show rootBundle;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import '../../../core/constants/app_constants.dart';
import '../../../core/utils/logger.dart';

class FaceEmbeddingService {
  Interpreter? _interpreter;
  bool _isInitialized = false;
  int _inputSize = AppConstants.faceInputSize;
  int _embeddingDim = AppConstants.faceEmbeddingDimension;

  bool get isInitialized => _isInitialized;
  int get inputSize => _inputSize;
  int get embeddingDimension => _embeddingDim;

  Future<void> initialize() async {
    try {
      // Surface a clear error when the model file is missing from assets.
      try {
        await rootBundle.load('assets/models/mobilefacenet.tflite');
      } on FlutterError catch (_) {
        throw StateError(
          'Missing face model asset: assets/models/mobilefacenet.tflite. '
          'Add the model file under assets/models/ and rebuild the app.',
        );
      }

      _interpreter = await Interpreter.fromAsset(
        'assets/models/mobilefacenet.tflite',
      );

      final inputShape = _interpreter!.getInputTensor(0).shape;
      final outputShape = _interpreter!.getOutputTensor(0).shape;
      _inputSize = inputShape[1];
      _embeddingDim = outputShape[1];

      _isInitialized = true;
      AppLogger.info(
        'MobileFaceNet loaded: input=$inputShape, output=$outputShape',
      );
    } catch (e) {
      AppLogger.error('Failed to load MobileFaceNet model', error: e);
      rethrow;
    }
  }

  Future<List<double>> getEmbedding(Uint8List croppedFaceBytes) async {
    if (!_isInitialized || _interpreter == null) {
      throw StateError('FaceEmbeddingService not initialized');
    }

    final inputTensor = _interpreter!.getInputTensor(0);
    final outputTensor = _interpreter!.getOutputTensor(0);
    final expectedInputShape = inputTensor.shape;
    final expectedOutputShape = outputTensor.shape;

    final flatInput = _preprocessFace(croppedFaceBytes);
    final input = flatInput.reshape([1, _inputSize, _inputSize, 3]);
    final output = List.filled(_embeddingDim, 0.0).reshape([1, _embeddingDim]);

    try {
      _interpreter!.run(input, output);
    } catch (e) {
      AppLogger.error(
        'Face embedding inference failed '
        '(inputShape=$expectedInputShape, outputShape=$expectedOutputShape, '
        'flatInputLen=${flatInput.length}, modelInputSize=$_inputSize, embeddingDim=$_embeddingDim)',
        error: e,
      );
      rethrow;
    }

    final embedding = List<double>.from(output[0] as List);
    return _l2Normalize(embedding);
  }

  static Uint8List embeddingToBytes(List<double> embedding) {
    final float32List = Float32List.fromList(
      embedding.map((e) => e.toDouble()).toList(),
    );
    return float32List.buffer.asUint8List();
  }

  static List<double> bytesToEmbedding(Uint8List bytes) {
    if (bytes.lengthInBytes % Float32List.bytesPerElement != 0) {
      throw ArgumentError.value(
        bytes.lengthInBytes,
        'bytes.lengthInBytes',
        'Embedding byte length must be a multiple of '
            '${Float32List.bytesPerElement}',
      );
    }
    final float32List = bytes.buffer.asFloat32List(
      bytes.offsetInBytes,
      bytes.lengthInBytes ~/ Float32List.bytesPerElement,
    );
    return float32List.toList();
  }

  Float32List _preprocessFace(Uint8List bytes) {
    final image = img.decodeImage(bytes);
    if (image == null) {
      throw ArgumentError('Failed to decode face image');
    }

    final size = _inputSize;
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

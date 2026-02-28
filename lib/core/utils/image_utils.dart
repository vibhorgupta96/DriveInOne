import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

class ImageUtils {
  static img.Image? decodeImageBytes(Uint8List bytes) {
    return img.decodeImage(bytes);
  }

  /// Crops a face region from [imageBytes] with an optional [padding] ratio
  /// that expands the bounding box on every side (0.4 = 40 % of face size).
  static Uint8List cropFace(
    Uint8List imageBytes,
    int left,
    int top,
    int width,
    int height, {
    double padding = 0.0,
  }) {
    final image = img.decodeImage(imageBytes);
    if (image == null) return imageBytes;

    final padX = (width * padding).round();
    final padY = (height * padding).round();

    final clampedLeft = (left - padX).clamp(0, image.width - 1);
    final clampedTop = (top - padY).clamp(0, image.height - 1);
    final clampedWidth = (width + padX * 2).clamp(1, image.width - clampedLeft);
    final clampedHeight =
        (height + padY * 2).clamp(1, image.height - clampedTop);

    final cropped = img.copyCrop(
      image,
      x: clampedLeft,
      y: clampedTop,
      width: clampedWidth,
      height: clampedHeight,
    );
    return Uint8List.fromList(img.encodePng(cropped));
  }

  /// Crops, optionally rotates to align eyes horizontally, then returns the
  /// face chip as PNG bytes ready for the embedding model.
  ///
  /// [eyeAngleDegrees] is the tilt angle of the eye-line in the *original*
  /// image coordinate space (positive = clockwise).  When provided the crop
  /// is rotated so the eyes become horizontal — exactly what MobileFaceNet
  /// expects.
  static Uint8List cropAndAlignFace(
    Uint8List imageBytes, {
    required int left,
    required int top,
    required int width,
    required int height,
    double padding = 0.0,
    double? eyeAngleDegrees,
  }) {
    final image = img.decodeImage(imageBytes);
    if (image == null) return imageBytes;

    final padX = (width * padding).round();
    final padY = (height * padding).round();

    final cl = (left - padX).clamp(0, image.width - 1);
    final ct = (top - padY).clamp(0, image.height - 1);
    final cw = (width + padX * 2).clamp(1, image.width - cl);
    final ch = (height + padY * 2).clamp(1, image.height - ct);

    var cropped = img.copyCrop(image, x: cl, y: ct, width: cw, height: ch);

    if (eyeAngleDegrees != null && eyeAngleDegrees.abs() > 0.5) {
      cropped = img.copyRotate(cropped, angle: -eyeAngleDegrees);
      // After rotation the canvas grows; re-center-crop to the original
      // aspect ratio so the face stays centred.
      final dw = cropped.width - cw;
      final dh = cropped.height - ch;
      if (dw > 0 || dh > 0) {
        final nx = (dw ~/ 2).clamp(0, cropped.width - 1);
        final ny = (dh ~/ 2).clamp(0, cropped.height - 1);
        final nw = min(cw, cropped.width - nx);
        final nh = min(ch, cropped.height - ny);
        cropped = img.copyCrop(cropped, x: nx, y: ny, width: nw, height: nh);
      }
    }

    return Uint8List.fromList(img.encodePng(cropped));
  }

  static Float32List preprocessFaceForModel(Uint8List faceBytes,
      {int size = 112}) {
    final image = img.decodeImage(faceBytes);
    if (image == null) return Float32List(size * size * 3);

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
}

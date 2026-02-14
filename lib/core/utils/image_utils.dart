import 'dart:typed_data';
import 'package:image/image.dart' as img;

class ImageUtils {
  static img.Image? decodeImageBytes(Uint8List bytes) {
    return img.decodeImage(bytes);
  }

  static Uint8List cropFace(Uint8List imageBytes, int left, int top, int width, int height) {
    final image = img.decodeImage(imageBytes);
    if (image == null) return imageBytes;

    final clampedLeft = left.clamp(0, image.width - 1);
    final clampedTop = top.clamp(0, image.height - 1);
    final clampedWidth = width.clamp(1, image.width - clampedLeft);
    final clampedHeight = height.clamp(1, image.height - clampedTop);

    final cropped = img.copyCrop(
      image,
      x: clampedLeft,
      y: clampedTop,
      width: clampedWidth,
      height: clampedHeight,
    );
    return Uint8List.fromList(img.encodePng(cropped));
  }

  static Float32List preprocessFaceForModel(Uint8List faceBytes, {int size = 112}) {
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

import 'package:flutter/material.dart';
import '../../../core/enums/provider_type.dart';
import '../../../core/theme/app_colors.dart';

class ProviderIcon extends StatelessWidget {
  final ProviderType providerType;
  final double size;

  const ProviderIcon({super.key, required this.providerType, this.size = 24});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _getColor().withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(size / 4),
      ),
      child: Center(
        child: Icon(_getIcon(), size: size * 0.6, color: Colors.white),
      ),
    );
  }

  IconData _getIcon() {
    switch (providerType) {
      case ProviderType.google:
        return Icons.cloud;
      case ProviderType.onedrive:
        return Icons.cloud_queue;
      case ProviderType.dropbox:
        return Icons.cloud_circle;
    }
  }

  Color _getColor() {
    switch (providerType) {
      case ProviderType.google:
        return AppColors.googleDrive;
      case ProviderType.onedrive:
        return AppColors.oneDrive;
      case ProviderType.dropbox:
        return AppColors.dropbox;
    }
  }
}

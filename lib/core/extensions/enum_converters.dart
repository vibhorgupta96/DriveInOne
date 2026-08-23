import '../../data/database/tables/accounts_table.dart';
import '../../data/database/tables/media_items_table.dart';
import '../enums/media_type.dart';
import '../enums/provider_type.dart';

extension ProviderTypeConversion on ProviderType {
  ProviderTypeEnum toDbEnum() {
    switch (this) {
      case ProviderType.google:
        return ProviderTypeEnum.google;
      case ProviderType.onedrive:
        return ProviderTypeEnum.onedrive;
      case ProviderType.dropbox:
        return ProviderTypeEnum.dropbox;
    }
  }
}

extension ProviderTypeEnumConversion on ProviderTypeEnum {
  ProviderType toDomain() {
    switch (this) {
      case ProviderTypeEnum.google:
        return ProviderType.google;
      case ProviderTypeEnum.onedrive:
        return ProviderType.onedrive;
      case ProviderTypeEnum.dropbox:
        return ProviderType.dropbox;
    }
  }
}

extension MediaTypeConversion on MediaType {
  MediaTypeEnum toDbEnum() {
    switch (this) {
      case MediaType.photo:
        return MediaTypeEnum.photo;
      case MediaType.video:
        return MediaTypeEnum.video;
    }
  }
}

extension MediaTypeEnumConversion on MediaTypeEnum {
  MediaType toDomain() {
    switch (this) {
      case MediaTypeEnum.photo:
        return MediaType.photo;
      case MediaTypeEnum.video:
        return MediaType.video;
    }
  }
}

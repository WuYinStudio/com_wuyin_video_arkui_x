import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

/** 相机枚举占位。 */
export namespace camera {
  export enum CameraPosition {
    CAMERA_POSITION_BACK = 0,
    CAMERA_POSITION_FRONT = 1,
    CAMERA_POSITION_UNSPECIFIED = 2
  }
}

/**
 * 相机拍照兼容层。
 * Android / iOS 相机由原生 Bridge 提供；未接桥前返回空结果并提示用户。
 */
export namespace cameraPicker {
  export enum PickerMediaType {
    PHOTO = 'photo',
    VIDEO = 'video'
  }

  export interface PickerProfile {
    cameraPosition?: camera.CameraPosition;
    saveUri?: string;
    videoDuration?: number;
  }

  export interface PickerResult {
    resultUri: string;
    mediaType: PickerMediaType;
  }

  export async function pick(context: common.UIAbilityContext,
    mediaTypes: PickerMediaType[], profile?: PickerProfile): Promise<PickerResult> {
    // 跨平台回退：相机能力未接原生桥时，改从系统相册选择图片。
    try {
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const result: photoAccessHelper.PhotoSelectResult = await picker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE
      });
      if (result.photoUris.length > 0) {
        return { resultUri: result.photoUris[0], mediaType: PickerMediaType.PHOTO };
      }
    } catch (_) {
    }
    return { resultUri: '', mediaType: mediaTypes.length > 0 ? mediaTypes[0] : PickerMediaType.PHOTO };
  }
}

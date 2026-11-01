# Gallery UI fixtures

`gallery-orange-1s.mp4` is a generated 160 × 160, one-second orange H.264 video without audio or personal content. It is test data, outside the app resources.

From `ios-native`, regenerate it with an existing FFmpeg installation:

```sh
ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i 'color=c=0xff6b4a:s=160x160:r=10' -t 1 -an \
  -c:v libx264 -pix_fmt yuv420p -movflags +faststart \
  tests/fixtures/gallery-orange-1s.mp4
```

Choose an owned, booted test Simulator explicitly, then add the bundled public Yapper brand image and the video to its Photos library:

```sh
xcrun simctl list devices booted
GALLERY_SIMULATOR_ID='<owned Simulator UDID>'
xcrun simctl addmedia "$GALLERY_SIMULATOR_ID" \
  YapperNative/OriginalAssets/Brand/apple-icon.png \
  tests/fixtures/gallery-orange-1s.mp4
```

`NativeInteractionRegressionTests.testNativeGalleryCancelAndSelectedPhotoKeepDraftWithoutSending` and `testNativeGallerySelectedVideoKeepsDraftWithoutSending` select these media through the actual system picker. They preserve the draft, verify the attachment preview, and remove the attachment without sending. The photo test also cancels the picker before selection and again with an existing attachment. The tests use anonymous app fixtures; no login or live account is needed.

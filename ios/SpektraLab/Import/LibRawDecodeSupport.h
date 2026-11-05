#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Decode a camera RAW container with the same pinned LibRaw build and
/// processing policy as the Mac/Windows engine.
///
/// Core Image only supports the camera formats Apple ships profiles for, and
/// that set differs between macOS and iOS. It can also expose an embedded
/// preview instead of the sensor frame. This is the fallback for those files:
/// full-resolution AHD, camera white balance, no automatic brightening, and
/// linear ProPhoto RGB (three float32 channels, top row first).
///
/// An opaque decoded frame. It owns three float32 channels per pixel, top row
/// first, in linear ProPhoto RGB. Release it with `SPKLibRawFrameFree` after
/// the last read; the pointer returned by `SPKLibRawFramePixels` is borrowed.
typedef void *SPKLibRawFrameRef;

/// `aspect` is long edge over short edge; 0 leaves the frame uncropped. The
/// crop preserves the frame's orientation (portrait uses the reciprocal).
SPKLibRawFrameRef _Nullable SPKLibRawDecode(NSData *data,
                                            NSString * _Nullable filenameExtension,
                                            NSInteger maxLongEdge,
                                            double aspect,
                                            NSInteger *width,
                                            NSInteger *height);

const float * _Nullable SPKLibRawFramePixels(SPKLibRawFrameRef frame);
void SPKLibRawFrameFree(SPKLibRawFrameRef _Nullable frame);

/// The failure from the last `SPKLibRawDecode` on this thread. Never NULL.
const char *SPKLibRawLastError(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

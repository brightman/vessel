#ifdef __OBJC__
#import <UIKit/UIKit.h>
#else
#ifndef FOUNDATION_EXPORT
#if defined(__cplusplus)
#define FOUNDATION_EXPORT extern "C"
#else
#define FOUNDATION_EXPORT extern
#endif
#endif
#endif

#import "opus.h"
#import "opus_custom.h"
#import "opus_defines.h"
#import "opus_multistream.h"
#import "opus_projection.h"
#import "opus_types.h"

FOUNDATION_EXPORT double BRRecorderOpusVersionNumber;
FOUNDATION_EXPORT const unsigned char BRRecorderOpusVersionString[];


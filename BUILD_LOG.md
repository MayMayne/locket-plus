# build

```
Tweak/LPExport.m:95:87: error: no known class method for selector 'videoInstruction'
   95 |     AVMutableVideoCompositionInstruction *ins = [AVMutableVideoCompositionInstruction videoInstruction];
      |                                                                                       ^~~~~~~~~~~~~~~~
Tweak/LPExport.m:149:25: error: use of undeclared identifier 'AVFileTypeMP4'; did you mean 'AVFileTypeMPEG4'?
  149 |     ex.outputFileType = AVFileTypeMP4;
      |                         ^~~~~~~~~~~~~
      |                         AVFileTypeMPEG4
/Applications/Xcode_26.6.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk/System/Library/Frameworks/AVFoundation.framework/Headers/AVMediaFormat.h:346:29: note: 'AVFileTypeMPEG4' declared here
  346 | AVF_EXPORT AVFileType const AVFileTypeMPEG4 API_AVAILABLE(macos(10.7), ios(4.0), tvos(9.0), watchos(1.0), visionos(1.0));
      |                             ^
2 errors generated.
Tweak/LPFriend.m:76:29: warning: performSelector may cause a leak because its selector is unknown [-Warc-performSelector-leaks]
   76 |     return FIRApp ? [FIRApp performSelector:NSSelectorFromString(@"defaultApp")] : nil;
      |                             ^
Tweak/LPFriend.m:76:45: note: used here
   76 |     return FIRApp ? [FIRApp performSelector:NSSelectorFromString(@"defaultApp")] : nil;
      |                                             ^
1 warning generated.
exit=1

```

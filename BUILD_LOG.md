# build

```
Tweak/LPFriend.m:55:29: warning: performSelector may cause a leak because its selector is unknown [-Warc-performSelector-leaks]
   55 |     return FIRApp ? [FIRApp performSelector:NSSelectorFromString(@"defaultApp")] : nil;
      |                             ^
Tweak/LPFriend.m:55:45: note: used here
   55 |     return FIRApp ? [FIRApp performSelector:NSSelectorFromString(@"defaultApp")] : nil;
      |                                             ^
1 warning generated.
==> build/LocketPlus.dylib
Non-fat file: build/LocketPlus.dylib is architecture: arm64
build/LocketPlus.dylib: code object is not signed at all
exit=0

```

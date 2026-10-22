# build

```
Tweak/LPFriend.m:76:29: warning: performSelector may cause a leak because its selector is unknown [-Warc-performSelector-leaks]
   76 |     return FIRApp ? [FIRApp performSelector:NSSelectorFromString(@"defaultApp")] : nil;
      |                             ^
Tweak/LPFriend.m:76:45: note: used here
   76 |     return FIRApp ? [FIRApp performSelector:NSSelectorFromString(@"defaultApp")] : nil;
      |                                             ^
1 warning generated.
==> build/LocketPlus.dylib
Non-fat file: build/LocketPlus.dylib is architecture: arm64
Executable=/Users/runner/work/locket-plus/locket-plus/build/LocketPlus.dylib
Identifier=LocketPlus-55554944e03d65a4c73b3ff7a7a5c12199cb92ea
Format=Mach-O thin (arm64)
exit=0

```

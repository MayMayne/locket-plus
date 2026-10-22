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
Identifier=LocketPlus-55554944ea2ef1cd2cf639588e92d832b1ddc10a
Format=Mach-O thin (arm64)
exit=0

```

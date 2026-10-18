# build

```
Tweak/LPFriend.m:55:29: warning: performSelector may cause a leak because its selector is unknown [-Warc-performSelector-leaks]
   55 |     return FIRApp ? [FIRApp performSelector:NSSelectorFromString(@"defaultApp")] : nil;
      |                             ^
Tweak/LPFriend.m:55:45: note: used here
   55 |     return FIRApp ? [FIRApp performSelector:NSSelectorFromString(@"defaultApp")] : nil;
      |                                             ^
1 warning generated.
ld: warning: Could not find or use auto-linked framework 'CoreAudioTypes': framework 'CoreAudioTypes' not found
ld: warning: Could not find or use auto-linked framework 'UIUtilities': framework 'UIUtilities' not found
Undefined symbols for architecture arm64:
  "_LPInstallCrashHandler", referenced from:
      ___LPInit_block_invoke_2 in LPEntry-e34c88.o
ld: symbol(s) not found for architecture arm64
clang: error: linker command failed with exit code 1 (use -v to see invocation)
exit=1

```

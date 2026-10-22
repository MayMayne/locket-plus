# build

```
Tweak/LPCommon.m:133:51: warning: capturing 'retry' strongly in this block is likely to lead to a retain cycle [-Warc-retain-cycles]
  133 |                        dispatch_get_main_queue(), retry);
      |                                                   ^~~~~
Tweak/LPCommon.m:128:5: note: block will be retained by the captured object
  128 |     retry = ^{
      |     ^~~~~
1 warning generated.
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
Identifier=LocketPlus-55554944e8f7ef6656293421baaf16e2f19aafdb
Format=Mach-O thin (arm64)
exit=0

```

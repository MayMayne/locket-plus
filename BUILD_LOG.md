# build

```
Tweak/LPCommon.m:286:51: warning: capturing 'retry' strongly in this block is likely to lead to a retain cycle [-Warc-retain-cycles]
  286 |                        dispatch_get_main_queue(), retry);
      |                                                   ^~~~~
Tweak/LPCommon.m:278:5: note: block will be retained by the captured object
  278 |     retry = ^{
      |     ^~~~~
1 warning generated.
==> build/LocketPlus.dylib
Non-fat file: build/LocketPlus.dylib is architecture: arm64
Executable=/Users/runner/work/locket-plus/locket-plus/build/LocketPlus.dylib
Identifier=LocketPlus-55554944a9acefb357ea303f86292bdeb25b9526
Format=Mach-O thin (arm64)
exit=0

```

# build

```
Tweak/LPCommon.m:285:51: warning: capturing 'retry' strongly in this block is likely to lead to a retain cycle [-Warc-retain-cycles]
  285 |                        dispatch_get_main_queue(), retry);
      |                                                   ^~~~~
Tweak/LPCommon.m:277:5: note: block will be retained by the captured object
  277 |     retry = ^{
      |     ^~~~~
1 warning generated.
==> build/LocketPlus.dylib
Non-fat file: build/LocketPlus.dylib is architecture: arm64
Executable=/Users/runner/work/locket-plus/locket-plus/build/LocketPlus.dylib
Identifier=LocketPlus-55554944e190702df57a3ad39f6a8879ba5034e4
Format=Mach-O thin (arm64)
exit=0

```

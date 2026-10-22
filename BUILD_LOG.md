# build

```
Tweak/LPCommon.m:289:51: warning: capturing 'retry' strongly in this block is likely to lead to a retain cycle [-Warc-retain-cycles]
  289 |                        dispatch_get_main_queue(), retry);
      |                                                   ^~~~~
Tweak/LPCommon.m:281:5: note: block will be retained by the captured object
  281 |     retry = ^{
      |     ^~~~~
1 warning generated.
Tweak/LPMedia.m:93:31: error: no visible @interface for 'LPConfig' declares the selector 'obj:'
   93 |     id v = [[LPConfig shared] obj:@"exportPresetLadder"];
      |             ~~~~~~~~~~~~~~~~~ ^~~
1 error generated.
exit=1

```

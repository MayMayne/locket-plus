# build

```
Tweak/LPFriend.m:76:29: warning: performSelector may cause a leak because its selector is unknown [-Warc-performSelector-leaks]
   76 |     return FIRApp ? [FIRApp performSelector:NSSelectorFromString(@"defaultApp")] : nil;
      |                             ^
Tweak/LPFriend.m:76:45: note: used here
   76 |     return FIRApp ? [FIRApp performSelector:NSSelectorFromString(@"defaultApp")] : nil;
      |                                             ^
1 warning generated.
Tweak/LPNotes.m:16:29: warning: function 'LPNotesSample' has internal linkage but is not defined [-Wundefined-internal]
   16 | static NSArray<NSString *> *LPNotesSample(NSArray<NSString *> *src, NSUInteger n);
      |                             ^
Tweak/LPNotes.m:340:22: note: used here
  340 |     NSArray *picks = LPNotesSample(LPNotesPresets(), 6);
      |                      ^
1 warning generated.
ld: warning: Could not find or use auto-linked framework 'CoreAudioTypes': framework 'CoreAudioTypes' not found
ld: warning: Could not find or use auto-linked framework 'UIUtilities': framework 'UIUtilities' not found
Undefined symbols for architecture arm64:
  "_LPNotesSample", referenced from:
      -[LPNotesAccessory rebuild] in LPNotes-9fc733.o
ld: symbol(s) not found for architecture arm64
clang: error: linker command failed with exit code 1 (use -v to see invocation)
exit=1

```

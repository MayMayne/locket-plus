# build

```
Tweak/LPExplorer.m:170:6: error: redefinition of 'LPOpenExplorer'
  170 | void LPOpenExplorer(UIViewController *host) {
      |      ^
Tweak/LPExplorer.m:156:6: note: previous definition is here
  156 | void LPOpenExplorer(UIViewController *host) {
      |      ^
1 error generated.
Tweak/LPFriend.m:76:29: warning: performSelector may cause a leak because its selector is unknown [-Warc-performSelector-leaks]
   76 |     return FIRApp ? [FIRApp performSelector:NSSelectorFromString(@"defaultApp")] : nil;
      |                             ^
Tweak/LPFriend.m:76:45: note: used here
   76 |     return FIRApp ? [FIRApp performSelector:NSSelectorFromString(@"defaultApp")] : nil;
      |                                             ^
1 warning generated.
Tweak/LPNotes.m:337:22: error: call to undeclared function 'LPNotesSample'; ISO C99 and later do not support implicit function declarations [-Wimplicit-function-declaration]
  337 |     NSArray *picks = LPNotesSample(LPNotesPresets(), 6);
      |                      ^
Tweak/LPNotes.m:337:22: note: did you mean 'LPNotesSave'?
Tweak/LPNotes.m:159:13: note: 'LPNotesSave' declared here
  159 | static void LPNotesSave(NSArray<NSString *> *notes) {
      |             ^
Tweak/LPNotes.m:337:22: error: implicit conversion of 'int' to 'NSArray *' is disallowed with ARC
  337 |     NSArray *picks = LPNotesSample(LPNotesPresets(), 6);
      |                      ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Tweak/LPNotes.m:337:14: error: incompatible integer to pointer conversion initializing 'NSArray *__strong' with an expression of type 'int' [-Wint-conversion]
  337 |     NSArray *picks = LPNotesSample(LPNotesPresets(), 6);
      |              ^       ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
3 errors generated.
exit=1

```

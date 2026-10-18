# build

```
Tweak/LPFriend.m:55:29: warning: performSelector may cause a leak because its selector is unknown [-Warc-performSelector-leaks]
   55 |     return FIRApp ? [FIRApp performSelector:NSSelectorFromString(@"defaultApp")] : nil;
      |                             ^
Tweak/LPFriend.m:55:45: note: used here
   55 |     return FIRApp ? [FIRApp performSelector:NSSelectorFromString(@"defaultApp")] : nil;
      |                                             ^
Tweak/LPFriend.m:97:75: warning: format specifies type 'long' but the argument has type 'NSString *' [-Wformat]
   96 |             LPAddFriendLog([NSString stringWithFormat:@"[replay %ld] -> HTTP %ld body=%@ err=%@",
      |                                                                              ~~~
      |                                                                              %@
   97 |                             (long)[(NSHTTPURLResponse *)resp statusCode], LPTrunc(data, 700),
      |                                                                           ^~~~~~~~~~~~~~~~~~
Tweak/LPFriend.m:96:95: warning: more '%' conversions than data arguments [-Wformat-insufficient-args]
   96 |             LPAddFriendLog([NSString stringWithFormat:@"[replay %ld] -> HTTP %ld body=%@ err=%@",
      |                                                                                              ~^
3 warnings generated.
Tweak/LPProfile.m:414:10: error: call to undeclared function 'LPIsProfileMenu'; ISO C99 and later do not support implicit function declarations [-Wimplicit-function-declaration]
  414 |     if (!LPIsProfileMenu(self)) return;
      |          ^
1 error generated.
exit=1

```

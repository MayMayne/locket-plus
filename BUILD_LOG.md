# build

```
Tweak/LPCommon.m:46:10: error: property 'plist' not found on object of type 'LPConfig *'
   46 |     self.plist = [d isKindOfClass:[NSDictionary class]] ? d : @{};
      |          ^
Tweak/LPCommon.m:50:17: error: property 'plist' not found on object of type 'LPConfig *'
   50 |     id v = self.plist[key];
      |                 ^
Tweak/LPCommon.m:50:22: error: array subscript is not an integer
   50 |     id v = self.plist[key];
      |                      ^~~~
Tweak/LPCommon.m:54:17: error: property 'plist' not found on object of type 'LPConfig *'
   54 |     id v = self.plist[key];
      |                 ^
Tweak/LPCommon.m:54:22: error: array subscript is not an integer
   54 |     id v = self.plist[key];
      |                      ^~~~
Tweak/LPCommon.m:58:17: error: property 'plist' not found on object of type 'LPConfig *'
   58 |     id v = self.plist[key];
      |                 ^
Tweak/LPCommon.m:58:22: error: array subscript is not an integer
   58 |     id v = self.plist[key];
      |                      ^~~~
Tweak/LPCommon.m:61:47: error: property 'plist' not found on object of type 'LPConfig *'
   61 | - (id)obj:(NSString *)key { return key ? self.plist[key] : nil; }
      |                                               ^
Tweak/LPCommon.m:61:52: error: array subscript is not an integer
   61 | - (id)obj:(NSString *)key { return key ? self.plist[key] : nil; }
      |                                                    ^~~~
Tweak/LPCommon.m:151:50: error: no visible @interface for 'LPConfig' declares the selector 'plist'
  151 |     NSMutableDictionary *m = [[[LPConfig shared] plist] mutableCopy] ?: [NSMutableDictionary dictionary];
      |                                ~~~~~~~~~~~~~~~~~ ^~~~~
10 errors generated.
Tweak/LPEntry.m:31:9: error: call to undeclared function 'LPWriteCrashText'; ISO C99 and later do not support implicit function declarations [-Wimplicit-function-declaration]
   31 |         LPWriteCrashText([NSString stringWithFormat:@"\n=== INSTALL FAILED ===\n%@\n",
      |         ^
1 error generated.
exit=1

```

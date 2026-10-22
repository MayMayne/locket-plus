# build

```
Tweak/LPSideload.m:304:9: error: call to undeclared function 'mkdir'; ISO C99 and later do not support implicit function declarations [-Wimplicit-function-declaration]
  304 |         mkdir(base, 0755);
      |         ^
Tweak/LPSideload.m:304:9: error: declaration of 'mkdir' must be imported from module 'Darwin.POSIX.sys.stat' before it is required
/Applications/Xcode_26.6.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk/usr/include/sys/stat.h:385:9: note: declaration here is not visible
  385 | int     mkdir(const char *, mode_t);
      |         ^
Tweak/LPSideload.m:304:9: warning: a function declaration without a prototype is deprecated in all versions of C and is treated as a zero-parameter prototype in C23, conflicting with a previous declaration [-Wdeprecated-non-prototype]
  304 |         mkdir(base, 0755);
      |         ^
/Applications/Xcode_26.6.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk/usr/include/sys/stat.h:385:9: note: conflicting prototype is here
  385 | int     mkdir(const char *, mode_t);
      |         ^
Tweak/LPSideload.m:304:9: error: conflicting types for 'mkdir'
  304 |         mkdir(base, 0755);
      |         ^
/Applications/Xcode_26.6.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk/usr/include/sys/stat.h:385:9: note: previous declaration is here
  385 | int     mkdir(const char *, mode_t);
      |         ^
1 warning and 3 errors generated.
exit=1

```

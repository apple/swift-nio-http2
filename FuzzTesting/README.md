# FuzzTesting

This subpackage build binaries to be use with Fuzz testing.

NOTE: The Swift toolchain distributed with Xcode do not include the fuzzing
support, so for macOS, one needs to install the swift.org toolchain and use that
instead.

To build on macOS:

```
xcrun \
  --toolchain swift \
  swift build -c debug -Xswiftc -sanitize=fuzzer,address -Xswiftc -parse-as-library
```

To build on linux:

```
swift build -c debug -Xswiftc -sanitize=fuzzer,address -Xswiftc -parse-as-library
```

Then the binaries will be found in `.build/debug`.

Note: You can also use `-c release` to build/test in release instead as that
could find different issues.

In this directory you will also find a `do_build.sh` script.  By default it
builds for both _debug_ and _release_. You can also pass `--run-regressions` to
have it run the the build against the previous failcases to check for
regressions.

When issues are found:

1. Make sure you add a file to `FailCases` subdirectory so regressions can
   easily be watched for.

2. Consider adding them to the unit tests as well. This can provide even
   better regression testing.

This infrastructure was originally developed for Swift Protobuf, and has been
adapted for SwiftNIO HTTP/2.

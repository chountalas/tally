## llama.framework provenance

- Source: `https://github.com/ggml-org/llama.cpp/releases/download/b8771/llama-b8771-xcframework.zip`
- Imported slice: `build-apple/llama.xcframework/macos-arm64_x86_64/llama.framework`
- Runtime binary SHA-256: `0c5c767e0fff2055bfc12ec8db6e9499b2f98423039723fe03a14a28ae6f4b2c`
- Reason: macOS-only local Gemma inference for Tally
- License: MIT; see `Vendor/llama-framework-LICENSE.txt`

Replace this framework by downloading a newer `llama.cpp` Apple XCFramework release and swapping the macOS slice in `Vendor/llama.framework`.

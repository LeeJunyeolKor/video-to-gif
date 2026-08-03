# Video to GIF

macOS 영역 녹화 또는 MOV 파일을 12 FPS, 최대 960px GIF로 저장합니다.

## 개발 실행

```sh
swift run
```

첫 녹화 때 요청되는 화면 기록 권한을 허용하세요.

## 로컬 앱 빌드

```sh
./scripts/build-app.sh
open dist/VideoToGIF.app
```

결과물은 `dist/VideoToGIF.app`입니다. 다른 Mac에 배포하기 전에는 `Resources/Info.plist`의 번들 ID와 버전을 확정하세요.

## 외부 배포

Apple Developer Program의 `Developer ID Application` 인증서가 필요합니다.

```sh
VIDEO_TO_GIF_SIGN_IDENTITY="Developer ID Application: 이름 (TEAM_ID)" ./scripts/build-app.sh
ditto -c -k --keepParent dist/VideoToGIF.app dist/VideoToGIF-notary.zip
xcrun notarytool store-credentials "VideoToGIF-notary" --apple-id "APPLE_ID" --team-id "TEAM_ID"
xcrun notarytool submit dist/VideoToGIF-notary.zip --keychain-profile "VideoToGIF-notary" --wait
xcrun stapler staple dist/VideoToGIF.app
ditto -c -k --keepParent dist/VideoToGIF.app dist/VideoToGIF.zip
spctl --assess --type execute --verbose dist/VideoToGIF.app
```

배포 파일은 공증 티켓이 포함된 `dist/VideoToGIF.zip`입니다.

- [Apple: Mac 소프트웨어 패키징](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- [Apple: macOS 소프트웨어 공증](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

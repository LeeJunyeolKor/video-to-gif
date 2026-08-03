# Video to GIF

macOS 영역 녹화 또는 MOV 파일을 12 FPS, 최대 960px GIF로 저장합니다.

## 개발 실행

```sh
swift run
```

첫 녹화 때 요청되는 화면 기록 권한을 허용하세요.

## 팀 공유용 빌드

```sh
./scripts/build-app.sh
```

`dist/VideoToGIF.zip`을 팀원에게 공유하세요. 현재 빌드는 Apple Silicon Mac용입니다.

팀원은 압축을 푼 뒤 앱을 Control-클릭하여 `열기`를 선택하고, 첫 녹화 때 화면 기록 권한을 허용해야 합니다.

버전을 배포할 때마다 `Resources/Info.plist`의 `CFBundleShortVersionString`과 `CFBundleVersion`을 올리세요.

```sh
open dist/VideoToGIF.app
```

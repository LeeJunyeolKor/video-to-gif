# Video to GIF

macOS 영역·전체 화면 녹화 또는 MOV 파일을 GIF로 저장합니다.

## 개발 실행

```sh
swift run
```

첫 녹화 때 요청되는 화면 기록 권한을 허용하세요.

영역 선택 중 원하는 모니터를 더블클릭하거나 Enter를 누르면 해당 화면 전체를 녹화합니다.

다른 앱을 사용하는 중에는 메뉴 막대의 녹화 아이콘으로 영역 녹화를 시작하고 중지할 수 있습니다.

`⌃⌘G`를 누르면 첫 번에는 영역을 선택하고, 이후에는 최근 영역에서 바로 녹화합니다. 녹화 중에 다시 누르면 중지합니다.

## 팀 공유용 빌드

```sh
./scripts/build-app.sh
```

`dist/VideoToGIF.zip`을 팀원에게 공유하세요. 현재 빌드는 Apple Silicon Mac용입니다.

팀원은 압축을 푼 뒤 앱을 Control-클릭하여 `열기`를 선택하고, 첫 녹화 때 화면 기록 권한을 허용해야 합니다.

GitHub Release를 만들려면 버전 태그를 푸시하세요. 태그 버전으로 앱을 빌드해 `VideoToGIF.zip`을 자동 첨부합니다.

```sh
git tag v0.1.0
git push origin v0.1.0
```

```sh
open dist/VideoToGIF.app
```

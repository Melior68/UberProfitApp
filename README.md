# Uber & 99 Profit Auto (iOS + Android)

Monitor automático de lucratividade para motoristas de aplicativo (Uber Driver & 99 Motorista).

## Estrutura do Projeto

```text
UberProfitApp/
├── .github/workflows/
│   └── build-ipa.yml              # Build automático iOS no macOS-latest (XcodeGen + xcodebuild)
├── Sources/
│   ├── UberProfitApp/             # App Principal iOS (Swift 6 / SwiftUI - Arquitetura MVVM)
│   │   ├── App/                   # Entry point e configurações (AppConfiguration, UberProfitApp)
│   │   ├── Models/                # Regras de cálculo e modelos de dados (ProfitCalculator)
│   │   ├── Services/              # Serviços (UDP, Áudio Keep-Alive, Voz, PiP, Notificações, Persistência)
│   │   ├── ViewModels/            # Estado e lógica da interface (ContentViewModel)
│   │   ├── Views/                 # Telas SwiftUI (ContentView, SubViews)
│   │   └── Resources/             # Info.plist e ícones do app
│   └── ScreenReaderExtension/     # Extensão ReplayKit (OCR Vision + envio UDP 127.0.0.1:9876)
├── android/                       # Projeto Android (Kotlin / Gradle)
├── releases/                      # Arquivos .ipa e .apk gerados (ignorados no Git)
│   ├── android/
│   └── ios/
└── project.yml                    # Especificação XcodeGen do projeto iOS
```

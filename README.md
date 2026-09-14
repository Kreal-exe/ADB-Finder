# Android Drop

Нативное macOS-приложение (Cocoa/Objective-C) для переноса файлов на Android по ADB перетаскиванием.

Перетащите файлы или папки в окно приложения — они уйдут на подключённое Android-устройство через `adb push`. Никакого iTunes-подобного клиента, никакого Android File Transfer — просто окно и drag-n-drop.

## Возможности

- Drag-and-drop файлов и папок из Finder прямо в окно приложения
- Автоматическое определение подключённого устройства (опрос `adb devices`)
- Кнопка Browse для выбора и просмотра папки назначения на устройстве
- Пути передаются в `adb shell` одной экранированной командой — корректно обрабатываются пробелы, юникод, скобки и прочая пунктуация
- Ошибки создания папок на устройстве показываются с реальным выводом ADB, а не общей заглушкой
- Лог работы пишется в `~/Library/Logs/AndroidDrop.log`

## Требования

- macOS 12.0 (Monterey) или новее
- Xcode Command Line Tools (для сборки из исходников)
- [Android Platform Tools (adb)](https://developer.android.com/tools/releases/platform-tools) — приложение ищет `adb` по очереди в:
  1. `/opt/homebrew/bin/adb`
  2. `/usr/local/bin/adb`
  3. `~/Library/Android/sdk/platform-tools/adb`
  4. `/usr/bin/adb`
  5. `adb` в `$PATH`

Быстрее всего поставить adb через Homebrew:

```bash
brew install android-platform-tools
```

- На самом Android-устройстве должна быть включена **отладка по USB** (Настройки → Для разработчиков → Отладка по USB), устройство должно быть подключено по USB (или Wi-Fi ADB) и авторизовано.

## Сборка

```bash
git clone git@github.com:Blunt0FF/AndroidDrop.git
cd AndroidDrop
./build.command
```

Скрипт соберёт `Android Drop.app` в корне репозитория (иконка генерируется из `AndroidDropIcon.png`). Готовое приложение можно перетащить в `/Applications`.

Либо забрать готовую сборку из [Releases](../../releases) — без установки Xcode.

## Использование

1. Запустите `Android Drop.app`.
2. Подключите Android-устройство по USB и разрешите отладку.
3. Дождитесь, пока приложение определит устройство.
4. При необходимости нажмите **Browse**, чтобы выбрать папку на устройстве, либо впишите путь вручную.
5. Перетащите файлы или папки в окно — передача начнётся автоматически.

Если что-то пошло не так — смотрите `~/Library/Logs/AndroidDrop.log`.

## Лицензия

[MIT](LICENSE)

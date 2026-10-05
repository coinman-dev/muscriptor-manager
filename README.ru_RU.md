[English](/README.md) | [Русский](/README.ru_RU.md)

# MuScriptor Manager

Менеджеры на PowerShell и Bash для установки, обновления и запуска [MuScriptor](https://github.com/MuScriptor/muscriptor) в Windows и Linux с определением видеокарты NVIDIA и загрузкой моделей с Hugging Face.

Менеджер не связан с MuScriptor, Hugging Face, NVIDIA или PyTorch.

## Возможности

- Устанавливает `uv`, Python 3.12, MuScriptor и подходящую сборку PyTorch.
- Содержит `muscriptor_manager.ps1` для Windows и `muscriptor_manager.sh` для Linux.
- Определяет поколение видеокарты NVIDIA, версию драйвера и совместимость с CUDA.
- Поддерживает модели MuScriptor `small`, `medium` и `large`.
- Скачивает модели, только когда их нет, и проверяет состояние кэша.
- Заранее, до первой транскрипции, скачивает модель определения темпа, которая нужна MuScriptor 0.3.0 и новее, и хранит её в папке установки.
- Запрашивает токен Hugging Face, когда он нужен; токен не сохраняется, пока не указан `-SaveToken`.
- Перед загрузкой проверяет доступ к моделям Hugging Face с ограниченным доступом и вместо трассировки HTTP-ошибок даёт прямую ссылку на страницу, где его можно получить.
- Запускает веб-интерфейс в текущей консоли или в фоне.
- Использует UTF-8 для вывода Python в консолях Windows с устаревшими кодовыми страницами.
- Пересоздаёт окружение Python в Windows, если оно перестало запускаться, и сохраняет скачанные модели.
- Записывает папку установки в переменную `Muscriptor`, проверяет окружение в ней перед повторным использованием и удаляет запись при удалении.
- После успешной установки добавляет выбранную папку в `PATH` текущего пользователя и убирает её оттуда при удалении.

## Требования

- Windows 10 или Windows 11 с Windows PowerShell 5.1 или PowerShell 7+ либо дистрибутив Linux с Bash 4+.
- Доступ в интернет для первой установки и загрузки моделей.
- Видеокарта NVIDIA и актуальный драйвер для ускорения через CUDA. Режим CPU поддерживается, но работает заметно медленнее.

## Быстрый запуск в Windows

Откройте PowerShell в папке со скриптом и выполните:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\muscriptor_manager.ps1
```

При запуске из Total Commander используйте приложенную командную обёртку: файловые ассоциации Windows PowerShell могут отбрасывать аргументы `.ps1`:

```text
muscriptor_manager.cmd -DownloadAll
muscriptor_manager.cmd -Help
```

Обёртка ждёт нажатия клавиши, прежде чем Total Commander закроет окно с выводом.

При первой установке скрипт предлагает `D:\Muscriptor`, если есть диск `D:`, иначе `C:\Muscriptor`. При необходимости введите другую папку. После успешной установки менеджер записывает эту папку в переменную окружения `Muscriptor` и перед повторным использованием проверяет в ней исполняемые файлы Python и MuScriptor. Чтобы сохранить `Muscriptor` как системную переменную, запустите PowerShell от имени администратора; иначе она сохраняется для текущего пользователя.

Если окружение в выбранной папке перестало запускаться, например после переноса диска на другой компьютер или в другой профиль Windows, менеджер пересоздаёт его и сохраняет скачанные модели. Укажите эту папку через `-Directory` или введите её в ответ на запрос.

Веб-интерфейс доступен по адресу `http://127.0.0.1:8222/`. Сервер, запущенный в консоли, останавливается по `Ctrl+C`.

## Быстрый запуск в Linux

Сделайте Bash-менеджер исполняемым и запустите его:

```bash
chmod +x muscriptor_manager.sh
./muscriptor_manager.sh
```

При первой установке скрипт предлагает `~/.local/share/muscriptor`. При необходимости введите другую папку. После успешной установки менеджер сохраняет `Muscriptor` в `~/.config/muscriptor-manager/installation.sh`, сам загружает этот файл и подключает его через `.bashrc`. Сервер доступен по адресу `http://127.0.0.1:8222/`; сервер, запущенный в консоли, останавливается по `Ctrl+C`.

## Команды Windows

```powershell
# Показать видеокарту, драйвер и рекомендуемую сборку PyTorch CUDA
.\muscriptor_manager.ps1 -GpuInfo

# Только установить или восстановить окружение
.\muscriptor_manager.ps1 -Install

# Обновить MuScriptor и выбранную сборку PyTorch CUDA
.\muscriptor_manager.ps1 -Update

# Запустить конкретную модель
.\muscriptor_manager.ps1 -Model small
.\muscriptor_manager.ps1 -Model medium
.\muscriptor_manager.ps1 -Model large

# Скачать модели без запуска сервера
.\muscriptor_manager.ps1 -Download -Model medium
.\muscriptor_manager.ps1 -DownloadAll

# Запустить в фоне, посмотреть состояние, затем остановить
.\muscriptor_manager.ps1 -Start
.\muscriptor_manager.ps1 -Status
.\muscriptor_manager.ps1 -Stop

# Использовать конкретную папку установки
.\muscriptor_manager.ps1 -Directory 'D:\Muscriptor' -Model large

# Удалить окружение, кэш, журналы, запись в PATH и папку установки
.\muscriptor_manager.ps1 -Uninstall
```

Все доступные параметры показывает `.\muscriptor_manager.ps1 -Help`.

## Команды Linux

```bash
# Показать видеокарту, драйвер и рекомендуемую сборку PyTorch CUDA
./muscriptor_manager.sh --gpu-info

# Только установить или восстановить окружение
./muscriptor_manager.sh --install

# Обновить MuScriptor и выбранную сборку PyTorch CUDA
./muscriptor_manager.sh --update

# Запустить конкретную модель или стартовать в фоне
./muscriptor_manager.sh --model medium
./muscriptor_manager.sh --model small --start

# Скачать модели без запуска сервера
./muscriptor_manager.sh --download --model medium
./muscriptor_manager.sh --download-all

# Посмотреть состояние фонового сервера и остановить его
./muscriptor_manager.sh --status
./muscriptor_manager.sh --stop

# Использовать конкретную папку установки
./muscriptor_manager.sh --directory /mnt/models/muscriptor --model large

# Удалить окружение, кэш, журналы, запись PATH для Bash и папку установки
./muscriptor_manager.sh --uninstall
```

Все доступные параметры показывает `./muscriptor_manager.sh --help`.

`-Uninstall` и `--uninstall` удаляют папку установки, только если в ней нет ничего, кроме окружения, кэша, журналов и файлов состояния самого менеджера. Папка с посторонними файлами остаётся на месте, и менеджер сообщает об этом.

## Обновление MuScriptor

Новая установка получает последний выпуск MuScriptor из PyPI. Уже установленная копия остаётся на своей версии, пока вы её не обновите:

```powershell
.\muscriptor_manager.ps1 -Update
```

```bash
./muscriptor_manager.sh --update
```

Скачанные модели сохраняются. Перед обновлением остановите фоновый сервер через `-Stop` или `--stop`.

MuScriptor 0.3.0 и новее определяет темп и доли с помощью дополнительной модели размером около 80 МБ. Менеджер скачивает её вместе с выбранной моделью и хранит в папке установки, поэтому первой транскрипции не приходится загружать её самой.

## Токен Hugging Face

Для загрузки некоторых моделей нужен токен Hugging Face с правом чтения. При необходимости скрипт запрашивает его сам:

```powershell
.\muscriptor_manager.ps1 -Token hf_your_token_here -Download -Model large
```

В Windows указывайте `-SaveToken`, только если действительно хотите сохранить токен в пользовательской переменной окружения `HF_TOKEN`. В Linux указывайте `--save-token`, только если действительно хотите сохранить токен в пользовательском файле настроек с правами 600. Не добавляйте в Git токены, кэши, журналы и локальные папки установки.

## Примечания о CUDA

Менеджер выбирает сборку PyTorch по вычислительным возможностям видеокарты (compute capability) и установленному драйверу NVIDIA.

- RTX 20xx, 30xx и 40xx получают самую новую сборку CUDA, которую поддерживает их драйвер.
- RTX 50xx требует сборку `cu130` и драйвер NVIDIA версии `580.65` или новее.
- Видеокарты Pascal, например GTX 1070 Ti, используют `cu126`, если драйвер это позволяет.

Скрипты устанавливают среду выполнения PyTorch CUDA, но не драйвер NVIDIA. Когда менеджер просит обновить драйвер, возьмите его на [странице загрузки драйверов NVIDIA](https://www.nvidia.com/Download/index.aspx) или установите пакет драйвера NVIDIA из своего дистрибутива Linux.

## Разработка

Перед отправкой изменений выполните:

```powershell
Invoke-ScriptAnalyzer -Path .\muscriptor_manager.ps1
```

```bash
shellcheck muscriptor_manager.sh
bash -n muscriptor_manager.sh
```

GitHub Actions при каждом push и pull request проверяет разбор PowerShell, запускает PSScriptAnalyzer, проверяет синтаксис Bash и запускает ShellCheck.

## Лицензия

Проект распространяется по [лицензии MIT](LICENSE).

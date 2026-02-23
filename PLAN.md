# kanata-bar: macOS menu bar app для kanata

Нативное Swift/AppKit приложение для управления kanata из menu bar.
Замена kanata-tray с решением проблем process lifecycle на macOS.

## Мотивация

kanata-tray (Go) имеет фундаментальные проблемы на macOS:
- `exec.CommandContext` шлёт **SIGKILL** (не SIGTERM) — нельзя перехватить
- macOS `sudo` не пробрасывает сигналы child-процессу
- Требуется wrapper script + фоновый монитор как костыль
- `osascript 'with administrator privileges'` — пароль без TouchID (если вызвано из не-Apple бинарника)

Swift `Process.terminate()` шлёт SIGTERM — проблема orphan-процессов **исчезает**.

## Архитектура

### Два режима privilege escalation

#### Гибридная архитектура: sudo start + XPC stop (primary) ✅ ПРОВЕРЕНО

```
                     Start: sudo kanata (user session → TCC dialog works)
┌─────────────────┐ ─────────────────────────────────────► ┌──────────────┐
│   kanata-bar    │                                        │   kanata     │
│  (user, tray)   │  Stop: XPC → kill(pid, SIGTERM)        │   (root)     │
│                 │ ──► ┌──────────────────┐ ──────────► │              │
│  NSStatusItem   │     │ kanata-bar-helper │               │              │
│  TCP :5829      │     │ (root, on-demand) │               │              │
└─────────────────┘     └──────────────────┘               └──────────────┘
```

**Почему гибрид**: root daemon (helper) не может триггерить TCC диалог (macOS ограничение для uid=0). Запуск kanata должен идти из user session для Input Monitoring.

- **Start**: App запускает `sudo kanata` (user session → TCC диалог появляется, одобрение одноразовое)
- **Stop**: App → XPC → Helper (root) → `kill(pid, SIGTERM)` → чистое завершение
- **Helper**: on-demand launchd daemon (MachServices), запускается при первом XPC-подключении
- **Регистрация**: `SMAppService.daemon()` → одобрение в System Settings → Login Items (одноразовое)
- sudoers NOPASSWD нужен для `sudo kanata` (генерируется модулем kanata-darwin)

**Проверено ✅**: ad-hoc signing (`codesign -s -`) работает с SMAppService. Developer ID не нужен.

#### Только sudoers (fallback, без SMAppService)

```
┌─────────────────┐      sudo          ┌──────────────────┐
│   kanata-bar    │ ──────────────────► │     kanata       │
│  (user, tray)   │  Process("sudo",   │  (root)          │
│                 │   "kanata", ...)    │                  │
│  NSStatusItem   │                    │                  │
│  TCP :5829      │  sudo kill → TERM  │                  │
└─────────────────┘                    └──────────────────┘
```

- Start и Stop через `sudo` — не нужен helper
- NOPASSWD sudoers entry (генерируется модулем kanata-darwin)
- Не нужен wrapper, не нужен монитор — Swift `Process` управляет lifecycle напрямую
- TouchID через PAM (`pam_tid.so`) если sudoers без NOPASSWD

## Компоненты

### 1. Menu bar UI (~100 строк)

```swift
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
// Иконка текущего слоя из PNG файлов
// Menu: Start / Stop / Reload / Quit
```

- `NSStatusItem` с иконкой текущего слоя
- Контекстное меню: Start, Stop, Reload, разделитель, Quit
- Start/Stop меняют состояние и обновляют menu item (enabled/disabled)
- Иконки слоёв — PNG файлы (генерируются модулем kanata-darwin, как сейчас)

### 2. TCP клиент для layer tracking (~80 строк)

- Подключение к kanata TCP API (порт 5829, настраивается)
- Парсинг JSON: `{"LayerChange":{"new":"nav"}}`
- При смене слоя — обновление иконки в menu bar
- Реконнект при обрыве (kanata restart)
- Foundation `NWConnection` или просто `Socket`

### 3. Process management (~100 строк)

**Start** (из app, user session — TCC работает):
```swift
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
p.arguments = [kanataPath, "-c", configPath, "--port", "\(port)"]
try p.run()
// Find kanata PID via pgrep (sudo execs kanata as child)
```

**Stop** (через XPC helper — root может kill любой процесс):
```swift
let conn = NSXPCConnection(machServiceName: "com.kanata-bar.helper", options: .privileged)
proxy.sendSignal(SIGTERM, toProcessID: kanataPID) { ... }
// SIGKILL fallback after 3s timeout
```

### 4. XPC helper daemon (~50 строк)

Минимальный root daemon — только процессные операции:

```swift
@objc protocol HelperProtocol {
    func sendSignal(_ sig: Int32, toProcessID pid: Int32,
                    withReply reply: @escaping (Bool, String) -> Void)
    func isProcessAlive(_ pid: Int32, withReply reply: @escaping (Bool) -> Void)
}
```

- **Не запускает kanata** (TCC требует user session)
- Предоставляет root-операции: `kill(pid, signal)`, проверка процесса
- On-demand через MachServices — запускается при первом XPC-подключении
- Embedded Info.plist (`-sectcreate __TEXT __info_plist`) обязателен

### 5. Конфигурация

Конфиг через CLI аргументы (как kanata-tray) или TOML:
- `--kanata-path` — путь к kanata binary
- `--config` — путь к kanata.kbd
- `--port` — TCP порт (default: 5829)
- `--icons-dir` — директория с PNG иконками слоёв
- `--mode` — `smappservice` | `sudoers` (default: auto-detect)

## Сборка и подпись

### Code signing ✅ ПРОВЕРЕНО

**Ad-hoc signing работает с SMAppService.** Developer ID не требуется.

- system swiftc (`/usr/bin/swiftc`) — Nix swiftc не подходит (другая code signature, ломает TCC/BTM)
- `codesign -s -` (ad-hoc) — достаточно для SMAppService daemon registration
- `TeamIdentifier=not set` — не блокирует SMAppService
- Helper binary должен иметь **embedded Info.plist** (`-sectcreate __TEXT __info_plist`)
- LaunchDaemon plist должен содержать `AssociatedBundleIdentifiers` с bundle ID приложения

### Сборка

```bash
# Компиляция
/usr/bin/swiftc -O -o kanata-bar Sources/*.swift \
  -framework AppKit -framework Network
# Helper с embedded Info.plist
/usr/bin/swiftc -O -o kanata-bar-helper Sources/Helper/*.swift \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker helper-info.plist
# Ad-hoc подпись
codesign -s - -f --identifier com.kanata-bar kanata-bar.app
```

- Activation script собирает app bundle и компилирует при изменении source
- Nix swiftc не используется (как с type-char)

### App bundle (для SMAppService)

SMAppService требует .app bundle structure:
```
kanata-bar.app/
  Contents/
    Info.plist
    MacOS/
      kanata-bar
      kanata-bar-helper    # privileged helper binary
    Library/
      LaunchDaemons/
        com.kanata-bar.helper.plist
    Resources/
      icons/               # layer icon PNGs
```

Activation script собирает bundle из скомпилированных бинарников.

### Для sudoers mode

App bundle не обязателен — достаточно standalone binary.
Может работать как простой бинарник с `NSStatusItem`.
macOS позволяет menu bar apps без .app bundle (LSUIElement через Info.plist или программно).

## Интеграция с kanata-darwin

### Новые опции модуля

```nix
services.kanata = {
  # ... existing options ...
  tray.package  # заменяется на:
  bar.enable = true;                  # использовать kanata-bar вместо kanata-tray
  bar.mode = "sudoers";              # "smappservice" | "sudoers" (default: "sudoers")
  bar.icons.labels = { ... };         # существующие опции иконок
  bar.icons.font = pkgs.nerd-fonts...;
};
```

### Или отдельный flake

```
~/workspace/kanata-bar/
├── flake.nix
├── Sources/
│   ├── main.swift
│   ├── StatusBarController.swift
│   ├── KanataConnection.swift
│   ├── ProcessManager.swift
│   └── Helper/
│       ├── main.swift
│       └── HelperProtocol.swift
└── Resources/
    └── Info.plist
```

## Поэтапный план

### Этап 1: Прототип ✅ ГОТОВ
- [x] SMAppService с ad-hoc signed binary — **работает!**
- [x] XPC коммуникация app ↔ helper (uid=0) — **работает!**
- [x] TCC эксперимент: helper (root daemon) не может триггерить TCC → **start через sudo из app**
- [x] Helper: минимальный — `sendSignal(pid)` + `isProcessAlive(pid)`, on-demand через MachServices
- [x] App: `sudo kanata` start (user session, TCC dialog), XPC stop (SIGTERM + SIGKILL fallback)
- [x] App: NSStatusItem + menu (Start/Stop/Register/Unregister/Quit)
- [x] Quit останавливает kanata перед выходом
- [x] App: TCP клиент для layer tracking (KanataClient)
- [x] App: динамическая смена иконки при смене слоя (onLayerChange → updateIcon)
- **Результат**: нативное управление kanata, чистый SIGTERM, без wrapper-костылей

### Этап 2: Standalone отладка ✅ ГОТОВ
- [x] Протестировать TCP layer tracking + смену иконок с реальным kanata
- [x] Sudoers fallback: start и stop полностью через sudo (без helper/SMAppService)
- [x] Auto-detect: SMAppService если helper зарегистрирован, иначе sudoers
- [x] Reload через kanata TCP API
- [x] Single-instance guard (NSRunningApplication)
- **Результат**: полностью рабочее standalone приложение, оба режима работают

### Этап 3: Улучшения
- [ ] Autostart (launchd agent, как сейчас)
- [ ] Лог-вьюер в меню (последние N строк stderr)
- [ ] Уведомления при crash/restart
- [ ] Dark/light mode для иконок (если нужно — текущие уже адаптивные)

### Этап 4: Интеграция с kanata-darwin
- [ ] Перенос из Tests/ в Sources/ (cleanup)
- [ ] Интеграция в kanata-darwin модуль (опции `bar.*`)

## Оценка сложности

| Компонент | Строк кода | Сложность |
|---|---|---|
| NSStatusItem + menu | ~100 | Низкая |
| TCP client (layer tracking) | ~80 | Низкая |
| Process management (sudoers) | ~60 | Низкая |
| XPC helper (SMAppService) | ~150 | Средняя |
| App bundle assembly | ~50 (bash) | Низкая |
| Nix module integration | ~30 | Низкая |
| **Итого (MVP, sudoers)** | **~250** | **Низкая** |
| **Итого (полный, + SMAppService)** | **~450** | **Средняя** |

## Результаты экспериментов

### Эксперимент 1: SMAppService + ad-hoc signing ✅

Тест: `Tests/SMAppServiceTest/` — минимальный app bundle с privileged helper.

- **Ad-hoc signing работает** — `codesign -s -`, `TeamIdentifier=not set`
- **register()** бросает "Operation not permitted" — это нормальный flow
- Статус переходит в `requiresApproval` → пользователь одобряет в System Settings → `enabled`
- **Helper запускается как root** (uid=0) — проверено через XPC ping
- **XPC коммуникация работает** — `NSXPCConnection` с `.privileged`
- Одобрение одноразовое (сохраняется в BTM database)
- **Xcode не нужен** — swiftc + mkdir + codesign достаточно

Критические детали:
- Helper binary **должен** иметь embedded Info.plist (`-sectcreate __TEXT __info_plist`)
- LaunchDaemon plist **должен** содержать `AssociatedBundleIdentifiers`
- Без embedded Info.plist — статус `notFound`

### Эксперимент 2: TCC + root daemon ❌ → гибрид ✅

Попытка запустить kanata из helper (root daemon):
- `IOHIDDeviceOpen error: not permitted` — TCC блокирует даже root
- Root daemon (uid=0) **не может триггерить TCC диалог** — macOS ограничение
- sqlite3 hack для TCC.db — отвергнут (хрупко, Apple может сломать)

**Решение — гибридная архитектура:**
- **Start**: app (user session) → `sudo kanata` → TCC диалог появляется, user одобряет
- **Stop**: app → XPC → helper (root) → `kill(pid, SIGTERM)` → чистое завершение
- Helper on-demand: MachServices → launchd запускает при первом XPC-подключении
- **Протестировано**: start, stop, quit (с auto-stop), TCC одобрение — всё работает

### Эксперимент 3: TCC наследуется от responsible process

При запуске kanata-bar из терминала, TCC Input Monitoring наследуется от терминального приложения (responsible process), а не от kanata-bar:
- Из Ghostty (Input Monitoring включен) → `sudo kanata` → **работает**
- Из Terminal.app (Input Monitoring выключен) → `sudo kanata` → `IOHIDDeviceOpen error: not permitted`

В продакшене kanata-bar запускается как standalone `.app` (launchd agent / Finder) — TCC диалог появится для самого kanata-bar. Для отладки из терминала — запускать из терминала с Input Monitoring.

### Эксперимент 4: Имена процессов

- macOS `MAXCOMLEN` = 15 символов — длинные имена бинарников обрезаются в `pgrep`
- `kanata-bar` (10) и `kanata-bar-helper` (18 → 15) — различимы
- В тесте: `-t` суффикс вместо `-test` для наглядности

## Открытые вопросы

1. ~~**Ad-hoc signing + SMAppService**~~ ✅ Работает.
2. ~~**App bundle без Xcode**~~ ✅ Работает (swiftc + mkdir + codesign).
3. ~~**Helper lifecycle**~~ ✅ Helper не управляет kanata — только kill/status. On-demand через MachServices.
4. **kanata-bar как замена или дополнение к kanata-tray?** — Предлагаю: полная замена в kanata-darwin, kanata-tray остаётся как альтернатива для Linux.
5. **Пересборка и BTM** — сохраняется ли SMAppService одобрение при пересборке бинарника (CDHash меняется)?
6. **Пересборка и TCC** — сохраняется ли TCC (Input Monitoring) для kanata при `darwin-rebuild switch` (CDHash меняется)?

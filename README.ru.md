# be-btrfs — менеджер Boot Environments для btrfs

Утилита для управления загрузочными окружениями (Boot Environments) на Linux-системах
с корневой файловой системой btrfs. Интерфейс вдохновлён Oracle Solaris `beadm`.

Целевая платформа: ARM SBC (Armbian) с U-Boot, но работает на любой системе
с btrfs-корнём и загрузчиком, поддерживающим btrfs default subvolume.

## Требования

- Linux с корневой ФС на btrfs
- Корень смонтирован как default subvolume (без `subvol=` в fstab)
- btrfs-progs >= 6.1
- bash 5.2+
- Загрузчик с поддержкой btrfs (U-Boot >= 2022.07, GRUB)

## Установка

```bash
sudo install -m 755 be-btrfs.sh /usr/local/sbin/be-btrfs
sudo cp be-btrfs.conf /etc/be-btrfs.conf
```

## Быстрый старт

```bash
# Проверить совместимость системы
sudo be-btrfs check

# Создать boot environment из текущей системы
sudo be-btrfs create -d "перед обновлением" before-update

# Создать снапшот
sudo be-btrfs create before-update@snap1

# Посмотреть список
sudo be-btrfs list

# Активировать BE (применится после перезагрузки)
sudo be-btrfs activate before-update
sudo reboot

# Вернуться на оригинал
sudo be-btrfs activate <имя-оригинального-BE>
sudo reboot
```

## Команды

### Основные (beadm-совместимые)

#### create — создание BE или снапшота

```bash
# Клон текущей системы
sudo be-btrfs create myBE

# Клон с описанием и немедленной активацией
sudo be-btrfs create -a -d "тестовое окружение" test-env

# Клон из существующего снапшота или BE
sudo be-btrfs create -e my-snapshot newBE

# Создать снапшот BE (read-only)
sudo be-btrfs create myBE@backup
```

Опции:
- `-a` — активировать BE сразу после создания
- `-d описание` — добавить текстовое описание
- `-e источник` — клонировать из указанного снапшота или BE

#### destroy — удаление BE или снапшота

```bash
sudo be-btrfs destroy myBE
sudo be-btrfs destroy myBE@backup
sudo be-btrfs destroy -F myBE          # без подтверждения
sudo be-btrfs destroy -fF myBE         # + принудительное размонтирование
```

Опции:
- `-f` — принудительно размонтировать, если BE смонтирован
- `-F` — не запрашивать подтверждение

#### list — список BE и снапшотов

```bash
sudo be-btrfs list                     # только BE
sudo be-btrfs list -s                  # BE + снапшоты
sudo be-btrfs list -d                  # BE + вложенные подтомы (home, var/log, …)
sudo be-btrfs list -a                  # всё (включая snapper, timeshift)
sudo be-btrfs list -H                  # machine-readable (разделитель ;)
```

Опции:
- `-s` — показать также снапшоты (`@snap-*`)
- `-d` — показать вложенные подтомы (shared между всеми BE)
- `-a` — показать всё: BE, снапшоты, вложенные подтомы, snapper, timeshift
- `-H` — машиночитаемый формат (разделитель `;`, без заголовка)

Флаги в выводе:
- `N` — активен сейчас
- `R` — активен после перезагрузки
- `NR` — и то, и другое

#### activate — активация BE

```bash
sudo be-btrfs activate myBE           # по имени
sudo be-btrfs activate                 # интерактивный выбор
```

Активированный BE станет корневой ФС при следующей перезагрузке.

#### mount / unmount — монтирование BE

```bash
sudo be-btrfs mount myBE /mnt
ls /mnt/etc/
sudo be-btrfs unmount myBE
sudo be-btrfs unmount -f myBE         # принудительно
```

Опции unmount:
- `-f` — принудительное размонтирование (lazy unmount)

#### rename — переименование BE

```bash
sudo be-btrfs rename old-name new-name
```

### Дополнительные команды

#### snapshot / clone — работа с внешними снапшотами

```bash
# Быстрый снапшот текущей системы
sudo be-btrfs snapshot my-snap "перед экспериментом"

# Клон из своего снапшота
sudo be-btrfs clone my-snap from-snap

# Клон из snapper или timeshift (сокращённый синтаксис)
sudo be-btrfs clone snapper#42 from-snapper
sudo be-btrfs clone timeshift/2026-03-09 from-timeshift

# Клон из любого снапшота по его пути на toplevel.
# Путь можно узнать из btrfs subvolume list /:
#   btrfs subvolume list / | grep snapshots
#   → ID 291 ... path @/.snapshots/ROOT.20260309T034711+0000
# Значение из колонки «path» — это и есть аргумент для clone:
sudo be-btrfs clone @/.snapshots/ROOT.20260309T034711+0000 rollback
sudo be-btrfs clone @/.snapshots/3/snapshot from-snapper3
sudo be-btrfs clone @my-random-snap from-random
```

#### upgrade — атомарное обновление системы

```bash
sudo be-btrfs upgrade
sudo be-btrfs upgrade -d "обновление до 26.04" my-upgrade
```

Выполняет:
1. Снапшот текущей системы (страховка)
2. Клон в новый BE
3. `apt-get update && apt-get dist-upgrade` в chroot
4. Активация нового BE

При ошибке BE не активируется, предлагается удалить.

#### shell — chroot в BE

```bash
sudo be-btrfs shell myBE
# внутри chroot: установка пакетов, настройка и т.д.
exit
```

#### prune — очистка старых BE и снапшотов

```bash
sudo be-btrfs prune                    # по правилам из конфига
sudo be-btrfs prune 3                  # оставить 3 последних BE (legacy)
```

#### rescue — восстановление из rescue-образа

```bash
# Загрузиться с live-образа, смонтировать btrfs-раздел, затем:
sudo be-btrfs rescue /mnt/my-btrfs
```

#### check / status

```bash
sudo be-btrfs check                    # проверка совместимости
sudo be-btrfs status                   # текущий корень и default subvolume
```

#### APT-интеграция

```bash
sudo be-btrfs apt-hook-install         # установить хук
# Теперь при каждом apt install/upgrade автоматически создаётся снапшот
```

## Сводка опций

| Опция | Команды | Описание |
|-------|---------|----------|
| `-a` | `create` | Активировать BE сразу после создания |
| `-a` | `list` | Показать всё: BE, снапшоты, snapper, timeshift |
| `-d описание` | `create`, `upgrade` | Текстовое описание BE |
| `-d` | `list` | Показать вложенные подтомы (shared между BE) |
| `-e источник` | `create` | Клонировать из указанного снапшота или BE |
| `-f` | `destroy` | Принудительно размонтировать перед удалением |
| `-f` | `unmount` | Принудительное размонтирование (lazy unmount) |
| `-F` | `destroy` | Не запрашивать подтверждение |
| `-H` | `list` | Машиночитаемый формат (разделитель `;`) |
| `-s` | `list` | Показать также снапшоты (`@snap-*`) |

## Конфигурация

Файл: `/etc/be-btrfs.conf` (системный) или `~/.config/be-btrfs.conf` (пользовательский).

```bash
# Префиксы подтомов (по умолчанию)
#BE_PREFIX="@be-"
#SNAP_PREFIX="@snap-"

# Правила очистки для prune
# Формат: "glob:min_keep:min_age"
#   glob     — шаблон имени подтома
#   min_keep — минимальное количество, которое всегда оставлять
#   min_age  — не удалять младше этого возраста
#              суффиксы: h (часы), d (дни), w (недели), m (месяцы)
#              0 = без ограничения по возрасту
PRUNE_RULES=(
    "@be-*:5:30d"           # BE: оставлять ≥5, не удалять младше 30 дней
    "@snap-apt-*:10:7d"     # APT-снапшоты: ≥10, не младше 7 дней
    "@snap-*:20:30d"        # Прочие снапшоты: ≥20, не младше 30 дней
)
```

Правила применяются сверху вниз, первое совпавшее побеждает.
Активный BE никогда не удаляется.

## Структура на диске

```
/                         ← toplevel (subvolid=5)
├── @                     ← корневая ФС (default subvolume)
├── @snap-<name>          ← read-only снапшоты
├── @be-<name>            ← writable boot environments
├── .be-meta/             ← метаданные
│   ├── @be-<name>.desc   ← текстовые описания
│   └── previous-default  ← ID предыдущего default (для отката)
├── .snapshots/           ← snapper (если есть)
└── timeshift-btrfs/      ← timeshift (если есть)
```

## Подготовка системы

### Требования к fstab

Корень должен монтироваться **без** указания `subvol=` или `subvolid=`:

```
UUID=xxxx-xxxx  /  btrfs  defaults,noatime  0  1
```

Это позволяет `btrfs subvolume set-default` управлять тем, какой подтом
монтируется как корень.

### Вложенные подтомы

Вложенные подтомы (`@home`, `@var/log`, `@tmp`) **не клонируются** —
они остаются общими между всеми BE, как shared datasets в ZFS.
Это осознанное решение для MVP.

### Проверка готовности

```bash
sudo be-btrfs check
```

## Лицензия

GPL-3.0-or-later

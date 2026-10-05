# Kaban — бренд: логотип, иконка приложения, словесный знак

«Кабан» — это дикий кабан, поэтому знак Kaban — стеклянная голова кабана в стиле иконок macOS 26 (Liquid Glass) на тёплом коричневом фоне.
Всё собрано из векторов: геометрия написана кодом (`tools/boar.py`), PNG рендерятся из SVG через headless Chrome. Сгенерированных растровых картинок в финале нет.

![Баннер](readme/banner-light.png)

## Выбранная концепция — A «Стеклянная голова»

Рассматривали три направления, все есть в `previews/concept-sheet.png`:

| | Концепция | Итог |
|---|---|---|
| **A** | Голова анфас: уши, гребень щетины из трёх прядей, щетина на щеках, брови, пятачок, клыки | **выбрана** |
| B | Голова в профиль с гривой | характерно, но в 16–32 px силуэт превращается в «каплю» |
| C | Анфас, гребень сделан из трёх колонок канбана | отсылка к канбану читается, но спорит с кабаном и теряется на тёмном фоне |

Почему A:
- **Узнаваемость.** Силуэт симметричный и крупный, его узнают от 1024 до 32 px. Для 16 и 32 px сделан упрощённый мастер `src/kaban-icon-macos-small.svg`: голова крупнее, без щёк и бровей, глаза и ноздри больше, контур клыков толще.
- **Характер.** Клыки, щетина и брови делают его «сильным», а круглые глаза с бликами и мягкие формы — дружелюбным, не агрессивным.
- **Стекло.** Голова полупрозрачная, кремово-янтарная. У неё светлый ободок (rim), внутренний блик по верхнему краю, мягкая тень и тёмный внутренний край снизу — та же оптика, что у новых системных иконок (например, Карт).
- **Отсылка к канбану.** Гребень из трёх прядей разной высоты — тихий намёк на три колонки, но главным героем остаётся кабан.

### Палитра

| Роль | Цвет |
|---|---|
| Фон (градиент) | `#A46C43` → `#5E341C` → `#2A150A`, тёплое свечение `#E0A060` за головой |
| Голова (стекло) | `#FFEAC4` → `#D6974C`, непрозрачность 93→80 % |
| Щетина | `#DD9A5C` → `#A35C2A` |
| Пятачок | `#FFF3DC` → `#EFB673` |
| Клыки | `#FFFFFF` → `#EEE0C8`, контур `#A8743F` |
| Глаза / ноздри | `#35200F` / `#7C4223` → `#4F260E` |
| Текст (светлая тема / тёмная тема) | `#2A170B` / `#FFF1E0`, подпись `#7A5A44` / `#C8A98F` |

## Шрифт словесного знака — Onest

- **Файл:** `font/Onest[wght].ttf` (вариативный, 100–900). **Лицензия:** SIL Open Font License 1.1, текст в `font/OFL.txt`. Источник: https://github.com/google/fonts/tree/main/ofl/onest, а также https://fonts.google.com/specimen/Onest.
- **Начертание знака:** Bold 700, трекинг −2 %. Подзаголовки — Medium 500.
- **Почему Onest:**
  - это неогротеск с той же геометрией, что у SF Pro, поэтому знак не спорит с системным интерфейсом macOS;
  - он теплее и дружелюбнее Inter;
  - спокойнее широкого Unbounded и не такой «технический», как Geologica;
  - кириллица в нём родная и качественная (шрифт сделан в России), поэтому «Кабан» выглядит так же уверенно, как «Kaban».
- Во всех SVG словесный знак переведён в кривые (HarfBuzz + fontTools), так что шрифт для просмотра не нужен.

![Шрифт](previews/font-specimen.png)

## Структура папки

```
brand/
├── src/                          исходники (вектор)
│   ├── kaban-icon-master.svg         мастер иконки во весь квадрат 1024 (как холст Icon Composer)
│   ├── kaban-icon-master-dark.svg    то же, тёмный фон
│   ├── kaban-icon-macos.svg          иконка macOS: сквиркл 824 px с отступом 100 px и тенью
│   ├── kaban-icon-macos-small.svg    упрощённый мастер для 16/32 px
│   ├── kaban-icon-macos-dark.svg / -mono.svg   варианты оформления
│   ├── kaban-boar-glass.svg          стеклянная голова без фона
│   ├── kaban-avatar.svg              аватар GitHub (весь квадрат, безопасно для круглой обрезки)
│   ├── wordmark-kaban[-ru]-{light,dark}.svg   словесный знак «Kaban» / «Кабан» в кривых
│   ├── lockup-kaban[-ru]-{light,dark}.svg     иконка + словесный знак
│   ├── banner[-ru]-{light,dark}.svg           баннеры README 1280×400
│   └── layers/                       плоские слои без эффектов (для Icon Composer, Figma, Penpot)
│       00-background · 05-mane · 10-head · 20-ears-inner · 30-tusks · 40-snout · 50-eyes-nostrils · 60-highlight
├── icon/
│   ├── Kaban.icon/                   пакет Icon Composer (icon.json + Assets/*.svg)
│   ├── AppIcon.iconset/              icon_16x16 … icon_512x512@2x (10 PNG; 64 = 32@2x, 1024 = 512@2x)
│   └── Kaban.icns                    собран icnsutil, проверен (`icnsutil t` → OK)
├── github/avatar-500.png, avatar-1024.png
├── readme/
│   ├── icon-1024.png                 плоская иконка 1024 (сквиркл, прозрачный фон) — для README
│   ├── icon-1024-square.png          весь квадрат без маски
│   ├── banner-{light,dark}.png (+@2x), banner-ru-{light,dark}.png
│   └── lockup-kaban[-ru]-{light,dark}.png  (прозрачный фон, 2×)
├── previews/
│   ├── concept-sheet.png             три концепции
│   ├── size-ladder.png               512 → 16 px на светлом и тёмном фоне, с увеличенными 32/16
│   ├── appearance-variants.png       светлая / тёмная / тонированная / моно
│   ├── icon-layers.png               раскладка слоёв .icon
│   ├── font-specimen.png             образец шрифта
│   ├── concepts/*.svg, png/*.png     исходники концепций и отдельные превью
├── font/Onest[wght].ttf, OFL.txt
└── tools/                            генераторы (Python + Node)
```

## Иконка для macOS 26: пакет `Kaban.icon`

Пакет предназначен для Icon Composer (Xcode 26+). Система сама рисует стекло, блики, тени и варианты Light / Dark / Tinted / Clear, поэтому в `Assets/` лежат **плоские** SVG на холсте 1024×1024 без запечённых эффектов.

`icon.json`. Группы перечислены **спереди назад**: первая группа рисуется сверху.

| Группа | Слои (сверху вниз) | Настройки |
|---|---|---|
| Highlight | `highlight.svg` | blend `plus-lighter`, непрозрачность 0.45, без стекла. Если системный specular покажется достаточным, слой можно выключить |
| Snout | `details.svg` (глаза, брови, ноздри), `snout.svg`, `tusks.svg` | specular, translucency 0.2, тень neutral 0.5; пятачок и клыки со стеклом |
| Head | `ears-inner.svg`, `head.svg`, `mane.svg` | specular, translucency 0.35, тень neutral 0.5; голова и щетина со стеклом |

Фон задаётся на уровне документа линейным градиентом: светлый `#A46C43 → #2F180B`, для appearance `dark` — `#4A2C19 → #120904`. Платформы: `{"squares": "shared"}` (macOS и iOS).

**Важно:**
- Формат `.icon` Apple публично не документирует.
- `icon.json` проверен JSON-схемой из открытого реверс-инжиниринга формата (`tools/icon-composer.schema.json`, проект giginet/apple-icon-composer-skill), но **не открывался в самом Icon Composer**: на сервере нет macOS.
- Перед сборкой откройте `icon/Kaban.icon` в Icon Composer и проверьте все режимы. Удобно также прогнать `ictool`: `…/Icon Composer.app/Contents/Executables/ictool`.
- Если что-то не так, слои можно импортировать вручную из `src/layers/`.
- Для сборок до macOS 26 используйте `Kaban.icns` или `AppIcon.iconset`.

## Как пересобрать

```bash
cd design/brand
/home/box/.venvs/brand/bin/python tools/build.py     # SVG, словесные знаки, баннеры, Kaban.icon (+ проверка схемой)
/home/box/.venvs/brand/bin/python tools/export.py    # PNG, iconset, .icns, превью
/home/box/.venvs/brand/bin/python tools/specimen.py  # образец шрифта
```
Зависимости: fontTools, uharfbuzz, shapely, svgpathtools, Pillow, icnsutil, jsonschema, а также puppeteer-core и Google Chrome для растеризации.

## Penpot и Google Drive

- **Penpot:** проект «Kaban», файл «Kaban — бренд», страница «Бренд».
  - На странице: концепции, иконка 1024, размеры, варианты, слои, баннеры, локапы, аватар, шрифт.
  - Доска «Иконка — вектор (плоские слои .icon)» собрана из **настоящих векторных объектов Penpot** (пути и эллипсы с градиентами). Остальные доски — PNG-заливки.
- **Google Drive:** папка `kaban/design/brand`. В ней ключевые PNG, этот README и архив `kaban-brand-src-icon.zip` с папками `src/` и `icon/`.

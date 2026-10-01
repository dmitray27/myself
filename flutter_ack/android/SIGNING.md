# Подпись release-APK своим ключом

Раньше `flutter build apk --release` подписывался **debug-ключом** Android SDK.
Это плохо по двум причинам:

* debug-ключ у каждой машины/установки SDK свой — APK, собранный на другом
  компьютере (или после переустановки SDK), не встанет поверх старого:
  «Приложение не установлено» / «конфликт подписи», придётся удалять с потерей
  настроек (имя, звук);
* debug-ключ не секретный — кто угодно может собрать APK с той же подписью и
  выдать за «обновление».

Теперь `android/app/build.gradle.kts` ищет файл `android/key.properties`.
Если он есть — release подписывается вашим ключом; если нет — как раньше,
debug-ключом (с предупреждением в логе сборки), чтобы сборка не ломалась.

## 1. Создать keystore (один раз)

Ключ создаётся один раз и хранится **вне репозитория**. Потеря ключа =
невозможность выпускать обновления поверх уже установленного приложения.

```bash
mkdir -p ~/keys
keytool -genkey -v \
  -keystore ~/keys/radiochat-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias radiochat
```

`keytool` идёт в комплекте с JDK (тот же, что использует Flutter/Android
Studio; если команда не найдена — `flutter doctor -v` покажет путь к Java,
`keytool` лежит рядом в `bin/`).

Программа спросит:

* пароль хранилища (store password) — придумайте и запишите;
* имя, организация, город, страна — можно заполнить произвольно, это
  попадёт только в сертификат;
* пароль ключа (key password) — Enter = такой же, как у хранилища
  (рекомендуется, современный формат PKCS12 всё равно использует один пароль).

Результат: файл `~/keys/radiochat-release.jks`.

## 2. Создать `android/key.properties`

```bash
cd flutter/android          # или flutter_info/android
cp key.properties.example key.properties
```

Отредактируйте `key.properties`:

```properties
storeFile=/home/dima/keys/radiochat-release.jks
storePassword=<пароль хранилища>
keyAlias=radiochat
keyPassword=<пароль ключа>
```

`storeFile` — абсолютный путь или относительный от папки `android/`.
Файл уже в `.gitignore` (`android/.gitignore`: `key.properties`, `*.jks`),
проверьте, что `git status` его **не** показывает.

Если собираете и `flutter/`, и `flutter_info/` — положите одинаковый
`key.properties` в обе папки `android/` (ключ общий, приложение одно).

## 3. Собрать и проверить

```bash
cd flutter
flutter build apk --release
```

В логе **не** должно быть строки
`key.properties не найден: release подписан debug-ключом`.

Проверить подпись готового APK:

```bash
apksigner verify --print-certs build/app/outputs/flutter-apk/radiochat.apk
```

(`apksigner` — в `$ANDROID_HOME/build-tools/<версия>/`). В выводе должен быть
ваш сертификат (имя/организация из шага 1), а не `CN=Android Debug`.

Альтернатива без apksigner:

```bash
keytool -printcert -jarfile build/app/outputs/flutter-apk/radiochat.apk
```

## 4. Первая установка на телефоны

APK с новым ключом **не встанет** поверх уже установленного с debug-подписью —
один раз придётся удалить старое приложение (настройки имени/звука сбросятся),
затем установить новый `radiochat.apk`. Все последующие обновления будут
ставиться поверх без удаления — пока используется этот же ключ.

## 5. Хранение ключа

* Сделайте резервную копию `radiochat-release.jks` и паролей (менеджер
  паролей, зашифрованная флешка). Восстановить утерянный ключ невозможно.
* Не коммитьте `key.properties` и `.jks`. Если случайно закоммитили — ключ
  считается скомпрометированным: создайте новый (и переустановите приложение
  на телефонах).
* Ключ никак не связан с Google Play — это подпись для прямой установки APK.
  Если когда-нибудь публиковать в Play, этот же ключ подойдёт как upload key.

## Что если key.properties нет

Сборка проходит, APK подписан debug-ключом (поведение как до этого изменения),
в лог Gradle выводится предупреждение. Так удобно для эмулятора и тестов,
но APK для раздачи на телефоны так собирать не надо.

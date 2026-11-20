# BBrbx (fork)

Fork [Cautioned/Blender-Animations-Plugin](https://github.com/Cautioned/Blender-Animations-Plugin) 3.1.3, który zastępuje oficjalny RBXMonkey. Dochodzi swobodna edycja riga w Blenderze, wbudowane Bulk Actions i poprawki błędów.

## Instalacja

1. **Blender:** w Edit → Preferences → Add-ons odinstaluj „RBXMonkey - Roblox Importer/Exporter” oraz stary dodatek „RBXMonkey Bulk Actions”. Potem zainstaluj `build/bbrbx_<wersja>.zip` przez Install from Disk.
2. **Studio:** uruchom `build_plugin.bat --install`, który kopiuje plik do `%LOCALAPPDATA%\Roblox\Plugins\BBrbx.rbxm`. Następnie w Plugins → Manage Plugins wyłącz oficjalny RBXMonkey i usuń z folderu Plugins plik `RBXMonkeyBulkImport.rbxmx`.

Porty zostają te same (31337), a stare pliki `.blend` i rigi działają bez zmian.

## Workflow: edytuję rig w Blenderze → Roblox

**Bez siatek skinned** (dodałeś lub przesunąłeś kości, stawy, bełt, rączkę…):
- W Studio: zakładka Rigging → **Push Rig from Blender**. Brakujące Bone'y i Motor6D zostaną utworzone, zmieniony spoczynek zaktualizowany, a kości w Blenderze ostemplowane, więc eksport idzie 1:1.

**Z siatkami skinned** (łuk, kusza, cokolwiek, co się wygina):
1. Blender: panel RBXMonkey → **BBrbx** → **Export Deform FBX**.
2. Studio: Home → Import 3D, z domyślnymi ustawieniami.
3. Studio: Rigging → **Bind Imported Mesh**.

Bind sam poprawia skalę, usuwa zagnieżdżony AnimationController, stawia siatkę na spoczynku z Blendera, przepina kości pod rig, zachowuje teksturę i odkłada zastąpione części do ServerStorage.

Potem animujesz i importujesz normalnie. Kości dodane w Blenderze dostają przy eksporcie prawdziwy spoczynek ze Studio, więc koniec ze zgadywaniem osi (dawny obrót o 180° wokół Y).

**Kości pomocnicze** (IK, pole, kontrolki) nie trafiają do Robloxa. W panelu BB możesz to zmienić dla wybranej kości: Always / Auto / Never.

**Przebudowa riga** (Generate rig) ma teraz opcję **Keep my bones**: zachowuje twoje kości, constrainty i akcję.

## Bulk Actions (wbudowane)

Zakładka Player → **📦 Bulk Actions (BB)**:
- import wszystkich akcji z Blendera jako osobnych KeyframeSequence w AnimSaves,
- upload z zachowaniem ID i ModuleScript `AnimationIds` z mapą nazwa → id,
- zaznaczanie tylko akcji zmienionych od ostatniego uploadu,
- nadpisywane zapisy lądują w `ServerStorage/BBrbx_AnimBackups`.

Priorytet, loop i nazwę docelową ustawisz dla każdej akcji w panelu BB w Blenderze.

## Automatyczna kontrola importu

Po każdym imporcie Studio po cichu sprawdza, czy rig odtwarza animację tak samo jak Blender. Pozycje stawów są porównywane w kilku klatkach. Jeśli coś się nie zgadza, w nagłówku pojawi się ostrzeżenie z przyczyną:
- staw nie istnieje w rigu,
- staw jest pomijany przez zagnieżdżony AnimationController,
- inny spoczynek,
- odwrócone osie.

## Rig Doctor

Rigging → **Rig Doctor: Scan** sprawdza zaznaczony rig albo cały folder z rigami. Szuka zagnieżdżonych AnimationController/Humanoid, braku PrimaryPart, zduplikowanych nazw kości i pozostałości importera. **Fix All** naprawia bezpieczne przypadki (Ctrl+Z cofa).

## Naprawione błędy

- Kamera nie trzyma się już starego riga po zmianie riga. Śledzi część po nazwie, przepina się na nowy rig albo odpina. Działa też na Bone'ach i przywraca poprzednie ustawienia kamery. Jest skrót „BBrbx: Attach/Detach Camera”.
- Zaznaczenie podmodelu broni z resztkowym AnimationController wybiera rig nadrzędny.
- Legacy export nie przełącza aktywnego riga na tymczasowy klon.
- Nowa karta riga nie dziedziczy stanu poprzedniego riga. Tryb multi-rig nie zatrzymuje innych otwartych rigów.
- Kanały są kluczowane nazwą Roblox, więc zmiana nazwy kości w Blenderze nic nie psuje. Kopie kości (Shift+D) nie nadpisują oryginału.
- Import kości Motor6D ze skinned mesh idzie dokładną ścieżką (round-trip Studio → Blender → Studio).
- Plugin nie budował się z repo (brak Packages). Fusion i Promise są teraz w `vendor/Packages.rbxm`.

## Dla deweloperów

- `build_plugin.bat [--install]` buduje plugin (Rojo, `plugin.project.json`).
- `python tools/bb/build_addon.py` buduje paczkę rozszerzenia Blendera.
- `lune run tools/bb/luau_check.luau` sprawdza kompilację wszystkich plików pluginu.
- Testy addonu (z repo, bez instalowania) uruchamiasz tak: `blender -b --factory-startup --python tools/bb/blender_bootstrap.py -- unittest:test_rest_contract`.

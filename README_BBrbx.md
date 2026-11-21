# BBrbx (fork)

Blender ⇄ Roblox Studio: rigi i animacje. Fork RBXMonkey 3.1.3, który zastępuje oficjalny plugin i działa na tym samym porcie (31337).

Najważniejsze różnice względem oryginału:
- kości dodane w Blenderze trafiają do Studio jednym kliknięciem i eksportują się 1:1,
- meshe, które się zginają, mają własną drogę do Robloxa,
- skalę broni zmieniasz bez wyrzucania animacji,
- wbudowane są import wielu akcji, upload i automatyczna kontrola importu.

**Gdzie co jest:**
- **Blender:** View3D → Sidebar (N) → zakładka **BBrbx**. Na górze są status Studio, port i armatura. Niżej:
  - **Import**: rig .rbxm, Rig setup, animacja z .fbx, legacy .obj,
  - **Export**: bake bez Studio, Export Deform FBX,
  - **Utility**: weld bones, Rig check, deform scale, aktywna kość,
  - **Advanced**: constrainty, środek masy, face, walidacja, konto, About.
- **Studio:** przycisk **BBrbx** na pasku pluginów. Zakładki:
  - **Import/Export** (nagłówki Import i Export),
  - **Play/Upload**,
  - **Extras**,
  - **Settings**.

## Instalacja

1. **Blender:** w Edit → Preferences → Add-ons odinstaluj „RBXMonkey - Roblox Importer/Exporter” i stary dodatek „RBXMonkey Bulk Actions”. Potem przez Install from Disk zainstaluj `build/bbrbx_<wersja>.zip`. Serwer dla Studio startuje sam razem z Blenderem; wyłączysz to w ustawieniach dodatku.
2. **Studio:** `build_plugin.bat --install` kopiuje plik do `%LOCALAPPDATA%\Roblox\Plugins\BBrbx.rbxm`. W Plugins → Manage Plugins wyłącz oficjalny RBXMonkey i usuń z folderu Plugins plik `RBXMonkeyBulkImport.rbxmx`. Zmiany pluginu działają po restarcie Studio.

Port zostaje ten sam (31337), więc stare pliki `.blend` i rigi działają bez zmian. Studio łączy się z Blenderem samo, gdy tylko Blender działa. Rozłączenie zauważa i po powrocie Blendera łączy się ponownie.

## Import animacji z Blendera

Import/Export → karta **Import Animation**:
1. Zaznacz akcje na liście albo „All”. Lista odświeża się sama po restarcie Blendera, przeładowaniu dodatku albo otwarciu innego `.blend`. Ikonka w rogu karty odświeża ją ręcznie.
2. W **Import options** ustawisz domyślny priorytet i loop oraz to, czy zastępować zapisy o tej samej nazwie.
3. **Import selected actions**: każda akcja trafia do AnimSaves riga jako osobna animacja.

Nadpisywane zapisy najpierw lądują w `ServerStorage/BBrbx_AnimBackups`.

**Kontrola importu.** Po każdym imporcie Studio porównuje pozy stawów z Blenderem w kilku klatkach. Ostrzega tylko wtedy, gdy coś się nie zgadza, i podaje przyczynę. Może to być na przykład:
- staw, którego nie ma w rigu,
- zagnieżdżony AnimationController,
- inny spoczynek, z odchyłką w studach lub stopniach.

W tym samym komunikacie jest sposób naprawy.

**W drugą stronę:** odtwórz animację w Studio i kliknij Export Animation → **Send to Blender**. Akcja pojawi się w Blenderze pod tą samą nazwą. Jeśli akcja o tej nazwie już była, jej poprzednia wersja zostaje jako „… (before Studio)”.

## Upload

Play/Upload → karta **Save / Upload**:
1. Na liście „Local saves (AnimSaves)” zaznacz animacje albo „All”.
2. W **Upload options** wybierz z listy „Upload to” siebie albo grupę. Lista pokazuje grupy, w których masz uprawnienia.
3. Opcje do włączenia:
   - „Keep the same asset ID when re-uploading”, gdy aktualizujesz istniejące animacje,
   - „Write an AnimationIds ModuleScript”, który tworzy mapę nazwa → id gotową do `require`.
4. **Upload selected**. Folder z obiektami Animation powstaje zawsze, a upload nie robi dodatkowej kopii w AnimSaves.

Zapisane animacje są też na pasku pod odtwarzaczem w Play/Upload (biały romb oznacza zapis lokalny). Pole Name pokazuje nazwę grającej animacji.

## Edytuję rig w Blenderze → Roblox

**Kości bez meshu deform** (nowa kość, przesunięty staw, bełt, rączka, laser):
- W Studio: Import/Export → Synchronise Rig → **Synchronise**.
- Brakujące Motor6D i Bone zostaną utworzone, a przesunięty spoczynek zaktualizowany. Wrócą też części usunięte poza pluginem.
- Kości w Blenderze dostają dokładną ramkę Robloxa, więc eksport idzie 1:1 bez zgadywania osi (dawny obrót o 180° wokół Y).
- Ctrl+Z w Studio cofa cały Synchronise jednym krokiem.

**Meshe, które się zginają** (pas, cięciwa, kabel):
1. Blender: BBrbx → Export → **Export Deform FBX**. Plik zapisze się obok `.blend`.
2. Studio: Home → Import 3D, z domyślnymi ustawieniami.
3. Studio: Synchronise Rig → **Append deform mesh**.

Append deform mesh robi resztę za Ciebie:
- poprawia skalę,
- usuwa zagnieżdżony AnimationController,
- stawia mesh na spoczynku z Blendera,
- przepina kości pod rig,
- zachowuje teksturę,
- odkłada zastąpione części do ServerStorage.

Przy eksporcie animacji takich rigów plugin pomija pozy, które Roblox i tak odtworzy. Na TAC50 z paskiem zostaje 352 pozy zamiast 3416, a animacja wygląda tak samo.

**Kości pomocnicze** (IK, pole, kontrolki) domyślnie nie trafiają do Robloxa. Dla każdej kości zmienisz to w Utility → aktywna kość: **Always / Auto / Never**.
- Kość ruszana przez helper zachowuje jego interpolację (Constant, Linear, Bezier).
- Kość podpięta pod helper liczy ruch od najbliższego rodzica, który jest stawem w Robloxie.

**Nazwy kości** możesz zmieniać, bo kanał trzyma nazwę z Robloxa. Kopia kości (Shift+D) nie nadpisuje oryginału.

**Przebudowa riga:** Import → Rig setup → Generate / rebuild armature ma opcję **Keep my bones**. Zachowuje ona Twoje kości, ich wagi, constrainty i akcje.

## Skala broni

Broń jest za mała albo za duża względem rąk, a animacja już jest zrobiona:
1. W Blenderze w Pose Mode przeskaluj kość broni, np. `Handle`. Może to być klucz albo zwykła wartość, w dowolnej akcji. Dwie bronie (akimbo) skaluj osobno, np. 1.2 i 2.
2. W Studio kliknij **Synchronise**.
   - Plugin bierze największą skalę każdej kości ze wszystkich klatek i akcji, albo najmniejszą, jeśli kość była tylko zmniejszana.
   - Broń rośnie w Blenderze i w Studio: części, meshe, stawy, attachmenty i kości.
   - Przesunięcia części broni w animacjach (magazynek, zamek) mnożą się przez skalę, także w AnimSaves (wcześniej robiona jest kopia).
   - Ruch samej broni w dłoni zostaje bez zmian.
   - Klucze skali znikają, bo rozmiar siedzi już w rigu.

Na co uważać:
- **Zmiana w Blenderze jest trwała.** Jeśli chcesz mieć wersję sprzed skalowania, zapisz `.blend` przed Synchronise.
- **Chowanie przez skalę jest pomijane.** Skala, która schodzi do 0 i wraca (np. chowany magazynek), nie zmienia rozmiaru broni.
- **Opublikowane już animacje** trzeba wrzucić ponownie.
- **`Model:ScaleTo` nie jest używane**, bo Animator przeskalowałby animacje drugi raz.

## Rig Doctor i Rig check

- **Studio:** zaznacz rig albo cały folder z rigami i kliknij Synchronise Rig → **Scan for issues**. Skan szuka:
  - zagnieżdżonych AnimationController i Humanoid,
  - braku PrimaryPart,
  - zduplikowanych nazw kości,
  - pozostałości importera.

  **Fix issues** naprawia bezpieczne przypadki (Ctrl+Z cofa).
- **Blender:** Utility → **Rig check** pokazuje jedną linijkę statusu riga, a szczegóły tylko przy problemie. Aktywna kość pokazuje obrót i pozycję w osiach Robloxa, tak jak zobaczysz je w Studio.

## Naprawione błędy

- Kamera nie trzyma się starego riga po zmianie riga. Przepina się na nowy rig albo odpina i działa też na Bone'ach. Ma skrót „BBrbx: Attach/Detach Camera”.
- Zaznaczenie podmodelu broni z zagnieżdżonym AnimationController wybiera rig nadrzędny.
- Nowa karta riga nie przejmuje stanu poprzedniego, a tryb multi-rig nie zatrzymuje innych rigów.
- Kość główna nie spada o 3.6 studa przy przenoszeniu animacji ze Studio do Blendera.
- Kość pod helperem nie przesuwa się w Studio.
- Krok Constant nie dostaje jednoklatkowej rampy, gdy rodzic się obraca.
- Synchronise nie pomija luźnych kości bez rodzica.
- Plugin nie trzyma armatury z poprzedniego pliku Blendera.
- Skalowanie broni przy grającym podglądzie nie zapisuje pozy z animacji w spoczynku.
- Import kości Motor6D ze skinned mesh idzie dokładną ścieżką (round-trip Studio → Blender → Studio).
- Przyciski, które wyglądały na wyszarzone, działają normalnie, a podpowiedzi pokazują się w swojej karcie.
- Suwak FOV nie wypisuje błędów w konsoli.
- Plugin budował się z repo tylko z ręcznie dociągniętymi Packages. Fusion i Promise są teraz w `vendor/Packages.rbxm`.

## Ograniczenia

- **Kość z wyłączonym Inherit Rotation** wraca z błędem przy przenoszeniu animacji ze Studio do Blendera. Z Blendera do Studio działa dobrze.
- **Roblox nie animuje skali.** Skala kości zamienia się w stały rozmiar przy Synchronise.
- **Helper skalowanej broni wiszący poza nią** (np. na HumanoidRootPart) skaluje się dokładnie tylko wtedy, gdy broń stoi w spoczynku.
- **Lewa ręka może odjechać od chwytu** po powiększeniu broni, jeśli jej cel IK nie jest podpięty pod broń.

## Dla deweloperów

- `build_plugin.bat [--install]` buduje plugin (Rojo, `plugin.project.json`).
- `python tools/bb/build_addon.py` buduje paczkę rozszerzenia Blendera.
- `lune run tools/bb/luau_check.luau` sprawdza kompilację wszystkich plików pluginu.
- Testy dodatku uruchamiasz z repo, bez instalowania: `blender -b --factory-startup --python tools/bb/blender_bootstrap.py -- unittest:test_rest_contract`.
- Działający Blender przeładuje dodatek bez restartu: `curl -X POST localhost:31337/bb/reload_addon`. Wcześniej skopiuj nowe pliki do `%APPDATA%\Blender Foundation\Blender\<wersja>\extensions\user_default\roblox_animations_importer_exporter`.
- **Nie instaluj dodatku komendą `blender --factory-startup -c extension install-file …`.** Instalacja zapisuje ustawienia Blendera, a z `--factory-startup` nadpisuje Twoje `userpref.blend` fabrycznymi.

## Credits

Oparte na RBXMonkey (Blender Animations Plugin) autorstwa Cautioned — [github.com/Cautioned/Blender-Animations-Plugin](https://github.com/Cautioned/Blender-Animations-Plugin). Licencja GPL-3.0, BBrbx jest na tej samej licencji.

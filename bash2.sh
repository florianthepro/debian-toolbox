#!/usr/bin/env bash

set -u

exec 3<>/dev/tty || {
    echo "Fehler: Kein Terminal verfügbar."
    exit 1
}

ORT="$(pwd -P)"
STATUS="Bereit"
AUSWAHL=""
SEITENGROESSE=8

bild() {
    printf '\033[2J\033[H'
}

taste() {
    local variable="$1"
    local wert
    IFS= read -rsn1 wert <&3 || exit 0
    printf -v "$variable" '%s' "$wert"
}

text() {
    local variable="$1"
    local frage="$2"
    local wert
    printf '%s' "$frage" >&3
    IFS= read -r wert <&3
    printf -v "$variable" '%s' "$wert"
}

pause() {
    local pause_taste
    echo
    echo "Beliebige Taste drücken ..."
    taste pause_taste
}

prompt() {
    local benutzer="${SUDO_USER:-${USER:-$(id -un)}}"
    local rechner
    local zeichen='$'
    rechner="$(hostname -s 2>/dev/null || hostname)"
    [ "$(id -u)" -eq 0 ] && zeichen='#'
    printf '\n%s@%s:%s%s ' "$benutzer" "$rechner" "$ORT" "$zeichen"
}

kopf() {
    bild
    echo "bash2"
    echo
}

frage() {
    local antwort
    printf '%s [j/N] ' "$1" >&3
    taste antwort
    echo
    [ "${antwort,,}" = "j" ]
}

befehl() {
    local titel="$1"
    shift
    local code
    kopf
    echo "$titel"
    echo
    "$@"
    code=$?
    echo
    if [ "$code" -eq 0 ]; then
        echo "Erledigt."
    else
        echo "Fehlgeschlagen. Fehlercode: $code"
    fi
    pause
    return "$code"
}

als_root() {
    local titel="$1"
    shift
    if [ "$(id -u)" -eq 0 ]; then
        befehl "$titel" "$@"
    else
        befehl "$titel" sudo -- "$@"
    fi
}

liste() {
    local titel="$1"
    shift
    local -a elemente=("$@")
    local seite=0
    local gesamt="${#elemente[@]}"
    local start ende nummer index eingabe

    [ "$gesamt" -gt 0 ] || {
        STATUS="Keine Einträge vorhanden"
        return 1
    }

    while true; do
        start=$((seite * SEITENGROESSE))
        ende=$((start + SEITENGROESSE))
        [ "$ende" -gt "$gesamt" ] && ende="$gesamt"

        kopf
        echo "$titel"
        echo

        nummer=1
        for ((index=start; index<ende; index++)); do
            printf '[%d] %s\n' "$nummer" "${elemente[$index]}"
            nummer=$((nummer + 1))
        done

        echo
        printf '%d-%d/%d\n' "$((start + 1))" "$ende" "$gesamt"
        echo
        [ "$seite" -gt 0 ] && echo "[V] Vorherige Seite"
        [ "$ende" -lt "$gesamt" ] && echo "[N] Nächste Seite"
        echo "[Z] Zurück"
        prompt
        taste eingabe

        case "${eingabe,,}" in
            [1-8])
                index=$((start + eingabe - 1))
                if [ "$index" -lt "$ende" ]; then
                    AUSWAHL="${elemente[$index]}"
                    return 0
                fi
                ;;
            n)
                [ "$ende" -lt "$gesamt" ] && seite=$((seite + 1))
                ;;
            v)
                [ "$seite" -gt 0 ] && seite=$((seite - 1))
                ;;
            z)
                return 1
                ;;
        esac
    done
}

pfad_aufloesen() {
    local eingabe="$1"
    if [[ "$eingabe" = /* ]]; then
        printf '%s' "$eingabe"
    else
        printf '%s/%s' "$ORT" "$eingabe"
    fi
}

datei_waehlen() {
    local art="${1:-alle}"
    local -a elemente=()
    case "$art" in
        ordner)
            mapfile -t elemente < <(find "$ORT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -f)
            ;;
        datei)
            mapfile -t elemente < <(find "$ORT" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort -f)
            ;;
        *)
            mapfile -t elemente < <(find "$ORT" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort -f)
            ;;
    esac
    liste "Auswählen" "${elemente[@]}"
}

datei_anzeigen() {
    local name pfad
    datei_waehlen datei || return
    name="$AUSWAHL"
    pfad="$ORT/$name"
    kopf
    echo "$name"
    echo
    if file -- "$pfad" 2>/dev/null | grep -qi text; then
        sed -n '1,200p' -- "$pfad"
    else
        file -- "$pfad"
        echo
        echo "Keine Textvorschau verfügbar."
    fi
    pause
}

dateien() {
    local w name ziel quelle neuer_pfad
    while true; do
        kopf
        echo "Dateien und Ordner"
        echo
        echo "[1] Inhalt anzeigen"
        echo "[2] Datei ansehen"
        echo "[3] Ordner wechseln"
        echo "[4] Ordner erstellen"
        echo "[5] Datei erstellen"
        echo "[6] Kopieren"
        echo "[7] Verschieben oder umbenennen"
        echo "[8] Löschen"
        echo "[A] Speicherverbrauch"
        echo "[Z] Zurück"
        echo
        echo "Aktueller Ordner: $ORT"
        prompt
        taste w

        case "${w,,}" in
            1)
                befehl "Inhalt von $ORT" ls -lah -- "$ORT"
                ;;
            2)
                datei_anzeigen
                ;;
            3)
                text ziel "Pfad: "
                [ -z "$ziel" ] && continue
                ziel="$(pfad_aufloesen "$ziel")"
                if cd -- "$ziel" 2>/dev/null; then
                    ORT="$(pwd -P)"
                    STATUS="Ordner gewechselt"
                else
                    STATUS="Ordner nicht gefunden"
                fi
                ;;
            4)
                text name "Ordnername: "
                [ -z "$name" ] && continue
                if mkdir -p -- "$ORT/$name"; then
                    STATUS="Ordner erstellt: $name"
                else
                    STATUS="Ordner konnte nicht erstellt werden"
                fi
                ;;
            5)
                text name "Dateiname: "
                [ -z "$name" ] && continue
                if touch -- "$ORT/$name"; then
                    STATUS="Datei erstellt: $name"
                else
                    STATUS="Datei konnte nicht erstellt werden"
                fi
                ;;
            6)
                datei_waehlen alle || continue
                quelle="$ORT/$AUSWAHL"
                text ziel "Zielpfad: "
                [ -z "$ziel" ] && continue
                ziel="$(pfad_aufloesen "$ziel")"
                befehl "Kopieren" cp -a -- "$quelle" "$ziel"
                ;;
            7)
                datei_waehlen alle || continue
                quelle="$ORT/$AUSWAHL"
                text neuer_pfad "Neuer Name oder Zielpfad: "
                [ -z "$neuer_pfad" ] && continue
                neuer_pfad="$(pfad_aufloesen "$neuer_pfad")"
                befehl "Verschieben" mv -- "$quelle" "$neuer_pfad"
                ;;
            8)
                datei_waehlen alle || continue
                name="$AUSWAHL"
                if frage "$name wirklich dauerhaft löschen?"; then
                    befehl "Löschen" rm -rf -- "$ORT/$name"
                fi
                ;;
            a)
                befehl "Speicherverbrauch" du -h -d 1 -- "$ORT"
                ;;
            z)
                return
                ;;
        esac
    done
}

programme() {
    local w paket suchwort
    while true; do
        kopf
        echo "Programme"
        echo
        echo "[1] Programm suchen"
        echo "[2] Programm installieren"
        echo "[3] Programm entfernen"
        echo "[4] Aktualisierungen suchen"
        echo "[5] System aktualisieren"
        echo "[6] Installierte Programme"
        echo "[7] Nicht mehr benötigte Pakete entfernen"
        echo "[8] Paketdetails"
        echo "[Z] Zurück"
        prompt
        taste w

        case "${w,,}" in
            1)
                text suchwort "Suchbegriff: "
                [ -n "$suchwort" ] && befehl "Suchergebnisse" apt-cache search -- "$suchwort"
                ;;
            2)
                text paket "Paketname: "
                [ -n "$paket" ] && als_root "Programm installieren" apt-get install -y -- "$paket"
                ;;
            3)
                text paket "Paketname: "
                [ -n "$paket" ] && frage "$paket wirklich entfernen?" && als_root "Programm entfernen" apt-get remove -y -- "$paket"
                ;;
            4)
                als_root "Aktualisierungen suchen" apt-get update
                ;;
            5)
                if frage "Alle verfügbaren Aktualisierungen installieren?"; then
                    als_root "Paketlisten aktualisieren" apt-get update
                    als_root "System aktualisieren" apt-get upgrade -y
                fi
                ;;
            6)
                befehl "Installierte Programme" dpkg-query -W '-f=${binary:Package}\t${Version}\n'
                ;;
            7)
                frage "Nicht mehr benötigte Pakete entfernen?" && als_root "Aufräumen" apt-get autoremove -y
                ;;
            8)
                text paket "Paketname: "
                [ -n "$paket" ] && befehl "Paketdetails" apt-cache show -- "$paket"
                ;;
            z)
                return
                ;;
        esac
    done
}

dienst_liste() {
    mapfile -t DIENSTE < <(
        systemctl list-unit-files --type=service --no-legend 2>/dev/null |
        awk '{sub(/\.service$/, "", $1); print $1}' |
        sort -fu
    )
}

dienste() {
    local w dienst aktiv autostart
    while true; do
        dienst_liste
        liste "Dienst auswählen" "${DIENSTE[@]}" || return
        dienst="$AUSWAHL"

        while true; do
            aktiv="$(systemctl is-active "$dienst" 2>/dev/null || true)"
            autostart="$(systemctl is-enabled "$dienst" 2>/dev/null || true)"
            kopf
            echo "Dienst: $dienst"
            echo
            echo "Aktuell:  $aktiv"
            echo "Autostart: $autostart"
            echo
            echo "[1] Starten"
            echo "[2] Stoppen"
            echo "[3] Neu starten"
            echo "[4] Autostart einschalten"
            echo "[5] Autostart ausschalten"
            echo "[6] Status und letzte Meldungen"
            echo "[7] Protokoll"
            echo "[Z] Andere Auswahl"
            prompt
            taste w

            case "${w,,}" in
                1) als_root "Dienst starten" systemctl start "$dienst" ;;
                2) frage "$dienst wirklich stoppen?" && als_root "Dienst stoppen" systemctl stop "$dienst" ;;
                3) als_root "Dienst neu starten" systemctl restart "$dienst" ;;
                4) als_root "Autostart einschalten" systemctl enable "$dienst" ;;
                5) als_root "Autostart ausschalten" systemctl disable "$dienst" ;;
                6) befehl "Dienststatus" systemctl status --no-pager --full "$dienst" ;;
                7) befehl "Dienstprotokoll" journalctl -u "$dienst" -n 100 --no-pager ;;
                z) break ;;
            esac
        done
    done
}

prozesse() {
    local w pid signal
    while true; do
        kopf
        echo "Prozesse"
        echo
        echo "[1] Nach CPU-Nutzung"
        echo "[2] Nach Speicherverbrauch"
        echo "[3] Prozess suchen"
        echo "[4] Prozess normal beenden"
        echo "[5] Prozess sofort beenden"
        echo "[Z] Zurück"
        prompt
        taste w

        case "${w,,}" in
            1) befehl "Prozesse nach CPU-Nutzung" ps aux --sort=-%cpu ;;
            2) befehl "Prozesse nach Speicherverbrauch" ps aux --sort=-%mem ;;
            3)
                text signal "Name oder Suchbegriff: "
                [ -n "$signal" ] && befehl "Suchergebnisse" pgrep -a -f -- "$signal"
                ;;
            4)
                text pid "Prozessnummer: "
                [[ "$pid" =~ ^[0-9]+$ ]] && frage "Prozess $pid beenden?" && befehl "Prozess beenden" kill -TERM "$pid"
                ;;
            5)
                text pid "Prozessnummer: "
                [[ "$pid" =~ ^[0-9]+$ ]] && frage "Prozess $pid sofort beenden?" && befehl "Prozess sofort beenden" kill -KILL "$pid"
                ;;
            z) return ;;
        esac
    done
}

netzwerk() {
    local w host port
    while true; do
        kopf
        echo "Netzwerk"
        echo
        echo "[1] Netzwerkübersicht"
        echo "[2] IP-Adressen"
        echo "[3] Verbindungen und offene Ports"
        echo "[4] Verbindung testen"
        echo "[5] DNS-Auflösung testen"
        echo "[6] Route anzeigen"
        echo "[7] Öffentliche Verbindung testen"
        echo "[Z] Zurück"
        prompt
        taste w

        case "${w,,}" in
            1) befehl "Netzwerkübersicht" sh -c 'ip -brief address; echo; ip route' ;;
            2) befehl "IP-Adressen" ip address show ;;
            3) befehl "Verbindungen und Ports" ss -tulpen ;;
            4)
                text host "Host oder IP: "
                [ -n "$host" ] && befehl "Verbindungstest" ping -c 4 -- "$host"
                ;;
            5)
                text host "Name: "
                [ -n "$host" ] && befehl "DNS-Test" getent ahosts "$host"
                ;;
            6) befehl "Netzwerkrouten" ip route show ;;
            7) befehl "Internetverbindung" ping -c 4 1.1.1.1 ;;
            z) return ;;
        esac
    done
}

benutzerverwaltung() {
    local w name gruppe
    while true; do
        kopf
        echo "Benutzer und Gruppen"
        echo
        echo "[1] Benutzer anzeigen"
        echo "[2] Gruppen anzeigen"
        echo "[3] Benutzer erstellen"
        echo "[4] Benutzer löschen"
        echo "[5] Benutzer zu Gruppe hinzufügen"
        echo "[6] Benutzer aus Gruppe entfernen"
        echo "[7] Passwort ändern"
        echo "[8] Benutzerinformationen"
        echo "[Z] Zurück"
        prompt
        taste w

        case "${w,,}" in
            1) befehl "Benutzer" getent passwd ;;
            2) befehl "Gruppen" getent group ;;
            3)
                text name "Benutzername: "
                if [[ "$name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
                    als_root "Benutzer erstellen" adduser "$name"
                else
                    STATUS="Ungültiger Benutzername"
                fi
                ;;
            4)
                text name "Benutzername: "
                [ -n "$name" ] && frage "$name wirklich löschen?" && als_root "Benutzer löschen" deluser "$name"
                ;;
            5)
                text name "Benutzername: "
                text gruppe "Gruppe: "
                [ -n "$name" ] && [ -n "$gruppe" ] && als_root "Gruppenzuweisung" usermod -aG "$gruppe" "$name"
                ;;
            6)
                text name "Benutzername: "
                text gruppe "Gruppe: "
                [ -n "$name" ] && [ -n "$gruppe" ] && als_root "Gruppenzuweisung entfernen" gpasswd -d "$name" "$gruppe"
                ;;
            7)
                text name "Benutzername: "
                [ -n "$name" ] && als_root "Passwort ändern" passwd "$name"
                ;;
            8)
                text name "Benutzername: "
                [ -n "$name" ] && befehl "Benutzerinformationen" id "$name"
                ;;
            z) return ;;
        esac
    done
}

protokolle() {
    local w suchwort
    while true; do
        kopf
        echo "Protokolle"
        echo
        echo "[1] Letzte Systemmeldungen"
        echo "[2] Fehler seit Systemstart"
        echo "[3] Anmeldungen"
        echo "[4] Kernelmeldungen"
        echo "[5] In Systemmeldungen suchen"
        echo "[6] Speicherplatz der Protokolle"
        echo "[Z] Zurück"
        prompt
        taste w

        case "${w,,}" in
            1) befehl "Letzte Systemmeldungen" journalctl -n 150 --no-pager ;;
            2) befehl "Fehler seit Systemstart" journalctl -b -p err --no-pager ;;
            3) befehl "Anmeldungen" last -a ;;
            4) befehl "Kernelmeldungen" journalctl -k -n 150 --no-pager ;;
            5)
                text suchwort "Suchbegriff: "
                [ -n "$suchwort" ] && befehl "Suchergebnisse" journalctl --no-pager -g "$suchwort"
                ;;
            6) befehl "Protokoll-Speicher" journalctl --disk-usage ;;
            z) return ;;
        esac
    done
}

systembereich() {
    local w
    while true; do
        kopf
        echo "System"
        echo
        echo "[1] Übersicht"
        echo "[2] Arbeitsspeicher"
        echo "[3] Festplatten"
        echo "[4] Hardware"
        echo "[5] Datum und Uhrzeit"
        echo "[6] Laufzeit"
        echo "[7] Neustarten"
        echo "[8] Ausschalten"
        echo "[Z] Zurück"
        prompt
        taste w

        case "${w,,}" in
            1) befehl "Systemübersicht" sh -c 'hostnamectl 2>/dev/null || true; echo; uname -a; echo; uptime' ;;
            2) befehl "Arbeitsspeicher" free -h ;;
            3) befehl "Festplatten" df -hT ;;
            4) befehl "Hardware" sh -c 'lscpu; echo; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS' ;;
            5) befehl "Datum und Uhrzeit" timedatectl ;;
            6) befehl "Systemlaufzeit" uptime ;;
            7) frage "System wirklich neu starten?" && als_root "Neustart" systemctl reboot ;;
            8) frage "System wirklich ausschalten?" && als_root "Ausschalten" systemctl poweroff ;;
            z) return ;;
        esac
    done
}

werkzeuge() {
    local w eingabe ausgabe
    while true; do
        kopf
        echo "Werkzeuge"
        echo
        echo "[1] Prüfsumme einer Datei"
        echo "[2] Zufällige UUID"
        echo "[3] Text in Base64 umwandeln"
        echo "[4] Base64 zurückwandeln"
        echo "[5] Archiv erstellen"
        echo "[6] Archiv entpacken"
        echo "[7] Datei oder Text suchen"
        echo "[Z] Zurück"
        prompt
        taste w

        case "${w,,}" in
            1)
                datei_waehlen datei && befehl "SHA-256-Prüfsumme" sha256sum -- "$ORT/$AUSWAHL"
                ;;
            2)
                kopf
                echo "UUID"
                echo
                cat /proc/sys/kernel/random/uuid
                pause
                ;;
            3)
                text eingabe "Text: "
                kopf
                echo "Base64"
                echo
                printf '%s' "$eingabe" | base64
                pause
                ;;
            4)
                text eingabe "Base64: "
                kopf
                echo "Klartext"
                echo
                printf '%s' "$eingabe" | base64 -d 2>/dev/null || echo "Ungültige Eingabe"
                echo
                pause
                ;;
            5)
                datei_waehlen alle || continue
                text ausgabe "Archivname ohne Endung: "
                [ -n "$ausgabe" ] && befehl "Archiv erstellen" tar -czf "$ORT/$ausgabe.tar.gz" -C "$ORT" -- "$AUSWAHL"
                ;;
            6)
                datei_waehlen datei || continue
                befehl "Archiv entpacken" tar -xf "$ORT/$AUSWAHL" -C "$ORT"
                ;;
            7)
                text eingabe "Suchbegriff: "
                [ -n "$eingabe" ] && befehl "Suche" grep -RIn --exclude-dir=.git -- "$eingabe" "$ORT"
                ;;
            z) return ;;
        esac
    done
}

terminal() {
    local kommando
    kopf
    echo "Befehl ausführen"
    echo
    text kommando "${USER:-$(id -un)}@$(hostname -s):$ORT$ "
    [ -z "$kommando" ] && return
    echo
    (cd -- "$ORT" && bash -c "$kommando")
    pause
}

hilfe() {
    kopf
    echo "Hilfe"
    echo
    echo "bash2 ist eine vereinfachte Oberfläche für Debian und Ubuntu."
    echo "Menüpunkte werden mit einer einzelnen Taste geöffnet."
    echo "Nur Texteingaben werden mit Enter bestätigt."
    echo
    echo "[Z] geht zurück. [Q] beendet bash2."
    echo "[N] und [V] blättern in langen Listen."
    echo
    echo "Für Systemänderungen wird sudo verwendet."
    echo "Löschen, Stoppen, Neustarten und Ausschalten fragen vorher nach."
    echo "Über 'Terminalbefehl' bleiben alle normalen Bash-Befehle verfügbar."
    pause
}

while true; do
    kopf
    echo "[1] Dateien und Ordner"
    echo "[2] Programme"
    echo "[3] Dienste"
    echo "[4] Prozesse"
    echo "[5] Netzwerk"
    echo "[6] Benutzer und Gruppen"
    echo "[7] Protokolle"
    echo "[8] System"
    echo "[A] Werkzeuge"
    echo "[T] Terminalbefehl"
    echo "[H] Hilfe"
    echo "[Q] Beenden"
    echo
    echo "Status: $STATUS"
    echo "Ort:    $ORT"
    prompt
    taste WAHL

    case "${WAHL,,}" in
        1) dateien ;;
        2) programme ;;
        3) dienste ;;
        4) prozesse ;;
        5) netzwerk ;;
        6) benutzerverwaltung ;;
        7) protokolle ;;
        8) systembereich ;;
        a) werkzeuge ;;
        t) terminal ;;
        h) hilfe ;;
        q) bild; exit 0 ;;
    esac
done

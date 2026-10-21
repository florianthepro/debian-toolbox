#!/usr/bin/env bash
# curl -fsSL "https://raw.githubusercontent.com/florianthepro/debian-toolbox/main/permissions/ordner-rechte.sh" | sudo bash

set -u

exec 3<>/dev/tty || {
    echo "Fehler: Kein Terminal verfügbar."
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Fehler: Mit sudo ausführen."
    exit 1
fi

ORDNER="$(pwd -P)" || {
    echo "Fehler: Aktueller Ordner nicht verfügbar."
    exit 1
}

if [ ! -d "$ORDNER" ]; then
    echo "Fehler: Kein gültiger Ordner."
    exit 1
fi

UID_MIN="$(awk '/^[[:space:]]*UID_MIN[[:space:]]+/ {print $2; exit}' /etc/login.defs 2>/dev/null)"
UID_MIN="${UID_MIN:-1000}"

eingabe() {
    printf "%s" "$1" >&3
    IFS= read -r "$2" <&3
}

pause() {
    local pause_eingabe
    echo
    eingabe "Enter drücken ..." pause_eingabe
}

kopf() {
    printf '\033[2J\033[H' >&3
    echo "Ordnerrechte"
    echo "$ORDNER"
    echo
}

rechte_text() {
    local rechte="$1"
    local art="$2"
    local teile=()

    [ "${rechte:0:1}" = "r" ] && teile+=("Lesen")
    [ "${rechte:1:1}" = "w" ] && teile+=("Schreiben")

    if [ "${rechte:2:1}" = "x" ] ||
       [ "${rechte:2:1}" = "s" ] ||
       [ "${rechte:2:1}" = "t" ]; then
        if [ "$art" = "Ordner" ]; then
            teile+=("Betreten")
        else
            teile+=("Ausführen")
        fi
    fi

    if [ "${#teile[@]}" -eq 0 ]; then
        printf "Kein Zugriff"
        return
    fi

    local ausgabe=""
    local teil

    for teil in "${teile[@]}"; do
        if [ -n "$ausgabe" ]; then
            ausgabe+=", "
        fi
        ausgabe+="$teil"
    done

    printf "%s" "$ausgabe"
}

objekt_art() {
    if [ -L "$1" ]; then
        printf "Verknüpfung"
    elif [ -d "$1" ]; then
        printf "Ordner"
    elif [ -f "$1" ]; then
        printf "Datei"
    else
        printf "Objekt"
    fi
}

rechte_anzeigen() {
    local pfad="$1"
    local modus="${2:-voll}"
    local art
    local rechte
    local besitzer
    local gruppe

    art="$(objekt_art "$pfad")"
    rechte="$(stat -c '%A' -- "$pfad" 2>/dev/null)" || return
    besitzer="$(stat -c '%U' -- "$pfad" 2>/dev/null)"
    gruppe="$(stat -c '%G' -- "$pfad" 2>/dev/null)"

    echo "$pfad"
    echo "  Art:       $art"
    echo "  Besitzer:  $besitzer"
    echo "  Gruppe:    $gruppe"

    if [ "$modus" = "voll" ]; then
        echo "  Besitzer:  $(rechte_text "${rechte:1:3}" "$art")"
        echo "  Gruppe:    $(rechte_text "${rechte:4:3}" "$art")"
        echo "  Andere:    $(rechte_text "${rechte:7:3}" "$art")"
    fi
}

aktueller_ordner() {
    kopf
    rechte_anzeigen "$ORDNER"

    echo
    echo "Gruppenmitglieder:"

    local gruppe
    local mitglieder

    gruppe="$(stat -c '%G' -- "$ORDNER")"
    mitglieder="$(getent group "$gruppe" | cut -d: -f4)"

    if [ -n "$mitglieder" ]; then
        printf '%s\n' "$mitglieder" | tr ',' '\n' | sed 's/^/  /'
    else
        echo "  Keine zusätzlichen Mitglieder"
    fi

    pause
}

benutzer_laden() {
    NORMALE_BENUTZER=()
    SYSTEM_BENUTZER=()

    local name
    local uid_num

    while IFS=: read -r name _ uid_num _ _ _ _; do
        [ "$name" = "root" ] && continue
        [ "$uid_num" -eq 65534 ] && continue

        if [ "$uid_num" -ge "$UID_MIN" ]; then
            NORMALE_BENUTZER+=("$name")
        else
            SYSTEM_BENUTZER+=("$name")
        fi
    done < <(getent passwd)
}

liste_auswaehlen() {
    local titel="$1"
    shift

    local liste=("$@")
    local nummer
    local index

    kopf
    echo "$titel"
    echo

    if [ "${#liste[@]}" -eq 0 ]; then
        echo "Keine Einträge vorhanden."
        pause
        return 1
    fi

    for index in "${!liste[@]}"; do
        printf "[%d] %s\n" "$((index + 1))" "${liste[$index]}"
    done

    echo "[0] Zurück"
    echo
    eingabe "Auswahl: " nummer

    [[ "$nummer" =~ ^[0-9]+$ ]] || return 1
    [ "$nummer" -eq 0 ] && return 1

    index=$((nummer - 1))

    if [ "$index" -lt 0 ] || [ "$index" -ge "${#liste[@]}" ]; then
        return 1
    fi

    AUSWAHL="${liste[$index]}"
    return 0
}

benutzer_auswaehlen() {
    local auswahl

    benutzer_laden

    while true; do
        kopf
        echo "[1] root"
        echo "[2] Normale Benutzer"
        echo "[3] Systembenutzer"
        echo "[0] Zurück"
        echo
        eingabe "Auswahl: " auswahl

        case "$auswahl" in
            1)
                AUSWAHL="root"
                return 0
                ;;
            2)
                liste_auswaehlen "Normale Benutzer" "${NORMALE_BENUTZER[@]}" &&
                    return 0
                ;;
            3)
                liste_auswaehlen "Systembenutzer" "${SYSTEM_BENUTZER[@]}" &&
                    return 0
                ;;
            0)
                return 1
                ;;
        esac
    done
}

zugriff_text() {
    local benutzer="$1"
    local pfad="$2"
    local art
    local zugriffe=()

    art="$(objekt_art "$pfad")"

    if su -s /bin/sh "$benutzer" -c 'test -r "$1"' sh "$pfad" 2>/dev/null; then
        zugriffe+=("Lesen")
    fi

    if su -s /bin/sh "$benutzer" -c 'test -w "$1"' sh "$pfad" 2>/dev/null; then
        zugriffe+=("Schreiben")
    fi

    if su -s /bin/sh "$benutzer" -c 'test -x "$1"' sh "$pfad" 2>/dev/null; then
        if [ "$art" = "Ordner" ]; then
            zugriffe+=("Betreten")
        else
            zugriffe+=("Ausführen")
        fi
    fi

    if [ "${#zugriffe[@]}" -eq 0 ]; then
        printf "Kein Zugriff"
        return
    fi

    local ausgabe=""
    local zugriff

    for zugriff in "${zugriffe[@]}"; do
        if [ -n "$ausgabe" ]; then
            ausgabe+=", "
        fi
        ausgabe+="$zugriff"
    done

    printf "%s" "$ausgabe"
}

benutzerzugriff_anzeigen() {
    local benutzer="$1"

    kopf
    echo "Benutzer: $benutzer"
    echo
    rechte_anzeigen "$ORDNER" kurz
    echo "  Zugriff:   $(zugriff_text "$benutzer" "$ORDNER")"

    pause
}

benutzer_verwalten() {
    local benutzer
    local gruppe
    local auswahl

    benutzer_auswaehlen || return

    benutzer="$AUSWAHL"
    gruppe="$(stat -c '%G' -- "$ORDNER")"

    while true; do
        kopf
        echo "Benutzer: $benutzer"
        echo "Gruppe:   $gruppe"
        echo
        echo "[1] Zugriff anzeigen"

        if [ "$benutzer" != "root" ]; then
            echo "[2] Zur Gruppe hinzufügen"
            echo "[3] Aus Gruppe entfernen"
        fi

        echo "[0] Zurück"
        echo
        eingabe "Auswahl: " auswahl

        case "$auswahl" in
            1)
                benutzerzugriff_anzeigen "$benutzer"
                ;;
            2)
                [ "$benutzer" = "root" ] && continue

                if id -nG "$benutzer" | tr ' ' '\n' | grep -Fxq "$gruppe"; then
                    echo
                    echo "$benutzer ist bereits Mitglied von $gruppe."
                elif usermod -aG "$gruppe" "$benutzer"; then
                    echo
                    echo "$benutzer wurde zu $gruppe hinzugefügt."
                else
                    echo
                    echo "Änderung fehlgeschlagen."
                fi

                pause
                ;;
            3)
                [ "$benutzer" = "root" ] && continue

                if ! id -nG "$benutzer" | tr ' ' '\n' | grep -Fxq "$gruppe"; then
                    echo
                    echo "$benutzer ist nicht Mitglied von $gruppe."
                elif [ "$(id -gn "$benutzer")" = "$gruppe" ]; then
                    echo
                    echo "$gruppe ist die Hauptgruppe von $benutzer."
                    echo "Die Hauptgruppe kann hier nicht entfernt werden."
                elif gpasswd -d "$benutzer" "$gruppe" >/dev/null 2>&1; then
                    echo
                    echo "$benutzer wurde aus $gruppe entfernt."
                else
                    echo
                    echo "Änderung fehlgeschlagen."
                fi

                pause
                ;;
            0)
                return
                ;;
        esac
    done
}

gruppe_auswaehlen() {
    local gruppen=()
    local name

    while IFS=: read -r name _; do
        gruppen+=("$name")
    done < <(getent group)

    liste_auswaehlen "Gruppen" "${gruppen[@]}"
}

gruppe_setzen() {
    gruppe_auswaehlen || return

    local gruppe="$AUSWAHL"
    local antwort

    kopf
    echo "Neue Gruppe: $gruppe"
    echo
    eingabe "Gruppe wirklich ändern? [ja/Nein]: " antwort

    case "$antwort" in
        ja|Ja|JA)
            if chgrp -- "$gruppe" "$ORDNER"; then
                echo
                echo "Gruppe wurde geändert."
            else
                echo
                echo "Änderung fehlgeschlagen."
            fi
            ;;
        *)
            echo
            echo "Abgebrochen."
            ;;
    esac

    pause
}

gruppe_erstellen() {
    local gruppe

    kopf
    eingabe "Neue Gruppe: " gruppe

    if ! [[ "$gruppe" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        echo
        echo "Ungültiger Gruppenname."
        pause
        return
    fi

    if getent group "$gruppe" >/dev/null; then
        echo
        echo "Gruppe existiert bereits."
        pause
        return
    fi

    if groupadd -- "$gruppe" && chgrp -- "$gruppe" "$ORDNER"; then
        echo
        echo "Gruppe wurde erstellt und ausgewählt."
    else
        echo
        echo "Änderung fehlgeschlagen."
    fi

    pause
}

rechte_setzen() {
    local bereich="$1"
    local titel="$2"
    local auswahl
    local modus

    kopf
    echo "$titel"
    echo
    echo "[1] Kein Zugriff"
    echo "[2] Betreten"
    echo "[3] Lesen und betreten"
    echo "[4] Schreiben und betreten"
    echo "[5] Lesen, schreiben und betreten"
    echo "[0] Zurück"
    echo
    eingabe "Auswahl: " auswahl

    case "$auswahl" in
        1) modus="---" ;;
        2) modus="--x" ;;
        3) modus="r-x" ;;
        4) modus="-wx" ;;
        5) modus="rwx" ;;
        0) return ;;
        *)
            echo
            echo "Ungültige Auswahl."
            pause
            return
            ;;
    esac

    if chmod "$bereich=$modus" -- "$ORDNER"; then
        echo
        echo "Rechte wurden geändert."
    else
        echo
        echo "Änderung fehlgeschlagen."
    fi

    pause
}

gruppen_verwalten() {
    local auswahl

    while true; do
        kopf
        rechte_anzeigen "$ORDNER"
        echo
        echo "[1] Gruppe auswählen"
        echo "[2] Neue Gruppe erstellen"
        echo "[3] Rechte der Gruppe ändern"
        echo "[4] Rechte aller anderen ändern"
        echo "[0] Zurück"
        echo
        eingabe "Auswahl: " auswahl

        case "$auswahl" in
            1) gruppe_setzen ;;
            2) gruppe_erstellen ;;
            3) rechte_setzen "g" "Rechte der Gruppe" ;;
            4) rechte_setzen "o" "Rechte aller anderen" ;;
            0) return ;;
        esac
    done
}

tiefe_abfragen() {
    local eingabe_tiefe

    kopf
    echo "Baumtiefe"
    echo
    eingabe "Ebenen " eingabe_tiefe

    eingabe_tiefe="${eingabe_tiefe:-3}"

    if ! [[ "$eingabe_tiefe" =~ ^[0-9]+$ ]]; then
        BAUMTIEFE=3
        return
    fi

    if [ "$eingabe_tiefe" -gt 20 ]; then
        BAUMTIEFE=20
    else
        BAUMTIEFE="$eingabe_tiefe"
    fi
}

baum_alle() {
    local nur_ordner="$1"
    local pfad

    tiefe_abfragen

    kopf
    echo "Alle Rechte"
    echo "Tiefe: $BAUMTIEFE"
    echo

    if [ "$nur_ordner" = "ja" ]; then
        while IFS= read -r -d '' pfad; do
            rechte_anzeigen "$pfad"
            echo
        done < <(find "$ORDNER" -maxdepth "$BAUMTIEFE" -type d -print0 2>/dev/null)
    else
        while IFS= read -r -d '' pfad; do
            rechte_anzeigen "$pfad"
            echo
        done < <(find "$ORDNER" -maxdepth "$BAUMTIEFE" -print0 2>/dev/null)
    fi

    pause
}

baum_benutzer() {
    local nur_ordner="$1"
    local benutzer
    local pfad

    benutzer_auswaehlen || return
    benutzer="$AUSWAHL"

    tiefe_abfragen

    kopf
    echo "Benutzer: $benutzer"
    echo "Tiefe:    $BAUMTIEFE"
    echo

    if [ "$nur_ordner" = "ja" ]; then
        while IFS= read -r -d '' pfad; do
            echo "$pfad"
            echo "  Art:      $(objekt_art "$pfad")"
            echo "  Zugriff:  $(zugriff_text "$benutzer" "$pfad")"
            echo
        done < <(find "$ORDNER" -maxdepth "$BAUMTIEFE" -type d -print0 2>/dev/null)
    else
        while IFS= read -r -d '' pfad; do
            echo "$pfad"
            echo "  Art:      $(objekt_art "$pfad")"
            echo "  Zugriff:  $(zugriff_text "$benutzer" "$pfad")"
            echo
        done < <(find "$ORDNER" -maxdepth "$BAUMTIEFE" -print0 2>/dev/null)
    fi

    pause
}

baumansicht() {
    local auswahl

    while true; do
        kopf
        echo "[1] Alle Rechte"
        echo "[2] Alle Rechte, nur Ordner"
        echo "[3] Zugriff eines Benutzers"
        echo "[4] Zugriff eines Benutzers, nur Ordner"
        echo "[0] Zurück"
        echo
        eingabe "Auswahl: " auswahl

        case "$auswahl" in
            1) baum_alle "nein" ;;
            2) baum_alle "ja" ;;
            3) baum_benutzer "nein" ;;
            4) baum_benutzer "ja" ;;
            0) return ;;
        esac
    done
}

while true; do
    kopf
    echo "[1] Aktueller Ordner"
    echo "[2] Benutzer"
    echo "[3] Gruppen"
    echo "[4] Baumansicht"
    echo "[0] Beenden"
    echo
    eingabe "Auswahl: " HAUPTAUSWAHL

    case "$HAUPTAUSWAHL" in
        1) aktueller_ordner ;;
        2) benutzer_verwalten ;;
        3) gruppen_verwalten ;;
        4) baumansicht ;;
        0)
            echo
            echo "Beendet."
            exit 0
            ;;
    esac
done

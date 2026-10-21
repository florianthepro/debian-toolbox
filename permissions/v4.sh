#!/usr/bin/env bash
# curl -fsSL "https://raw.githubusercontent.com/florianthepro/debian-toolbox/main/permissions/ordner-rechte.sh" | sudo bash

set -u

exec 3<>/dev/tty || {
    echo "Fehler: Kein Terminal verfügbar."
    exit 1
}

[ "$(id -u)" -eq 0 ] || {
    echo "Fehler: Mit sudo ausführen."
    exit 1
}

ORDNER="$(pwd -P)" || exit 1

[ -d "$ORDNER" ] || {
    echo "Fehler: Kein gültiger Ordner."
    exit 1
}

UID_MIN="$(awk '/^[[:space:]]*UID_MIN[[:space:]]+/ {print $2; exit}' /etc/login.defs 2>/dev/null)"
UID_MIN="${UID_MIN:-1000}"

ERGEBNIS=""

clear_screen() {
    printf '\033[2J\033[H'
}

taste() {
    local variablenname="$1"
    local wert

    IFS= read -rsn1 wert <&3 || exit 0
    printf -v "$variablenname" '%s' "$wert"
}

prompt() {
    local benutzer="${SUDO_USER:-$(id -un)}"
    local rechner
    local zeichen='$'

    rechner="$(hostname -s 2>/dev/null || hostname)"

    if [ -z "${SUDO_USER:-}" ] && [ "$(id -u)" -eq 0 ]; then
        zeichen='#'
    fi

    printf '\n%s@%s:%s%s ' \
        "$benutzer" \
        "$rechner" \
        "$ORDNER" \
        "$zeichen"
}

art() {
    if [ -d "$1" ]; then
        echo "Ordner"
    elif [ -f "$1" ]; then
        echo "Datei"
    elif [ -L "$1" ]; then
        echo "Verknüpfung"
    else
        echo "Objekt"
    fi
}

rechte_text() {
    local rechte="$1"
    local typ="$2"
    local ausgabe=""

    if [ "${rechte:0:1}" = "r" ]; then
        ausgabe="Lesen"
    fi

    if [ "${rechte:1:1}" = "w" ]; then
        ausgabe="${ausgabe:+$ausgabe, }Schreiben"
    fi

    case "${rechte:2:1}" in
        x|s|t)
            if [ "$typ" = "Ordner" ]; then
                ausgabe="${ausgabe:+$ausgabe, }Betreten"
            else
                ausgabe="${ausgabe:+$ausgabe, }Ausführen"
            fi
            ;;
    esac

    printf '%s' "${ausgabe:-Kein Zugriff}"
}

status() {
    local pfad="$1"
    local rechte
    local typ
    local besitzer
    local gruppe

    rechte="$(stat -c '%A' -- "$pfad" 2>/dev/null)" || return
    typ="$(art "$pfad")"
    besitzer="$(stat -c '%U' -- "$pfad")"
    gruppe="$(stat -c '%G' -- "$pfad")"

    echo "Aktueller Ordner"
    echo "Besitzer: $besitzer | $(rechte_text "${rechte:1:3}" "$typ")"
    echo "Gruppe:   $gruppe | $(rechte_text "${rechte:4:3}" "$typ")"
    echo "Andere:   $(rechte_text "${rechte:7:3}" "$typ")"
}

zugriff() {
    local benutzer="$1"
    local pfad="$2"
    local typ
    local ausgabe=""

    typ="$(art "$pfad")"

    if su -s /bin/sh "$benutzer" \
        -c 'test -r "$1"' sh "$pfad" 2>/dev/null; then
        ausgabe="Lesen"
    fi

    if su -s /bin/sh "$benutzer" \
        -c 'test -w "$1"' sh "$pfad" 2>/dev/null; then
        ausgabe="${ausgabe:+$ausgabe, }Schreiben"
    fi

    if su -s /bin/sh "$benutzer" \
        -c 'test -x "$1"' sh "$pfad" 2>/dev/null; then

        if [ "$typ" = "Ordner" ]; then
            ausgabe="${ausgabe:+$ausgabe, }Betreten"
        else
            ausgabe="${ausgabe:+$ausgabe, }Ausführen"
        fi
    fi

    printf '%s' "${ausgabe:-Kein Zugriff}"
}

ansicht() {
    clear_screen

    echo "Ordnerrechte"
    echo
    echo "[1] Benutzerzugriff"
    echo "[2] Gruppe wechseln"
    echo "[3] Gruppenrechte ändern"
    echo "[4] Rechte für Andere ändern"
    echo "[5] Gesamten Rechtebaum anzeigen"
    echo "[6] Rechtebaum eines Benutzers"
    echo "[Q] Beenden"

    if [ -n "$ERGEBNIS" ]; then
        echo
        echo "Ergebnis: $ERGEBNIS"
    fi

    echo
    status "$ORDNER"
    prompt
}

liste_waehlen() {
    local titel="$1"
    shift

    local -a liste=("$@")
    local seite=0
    local start
    local ende
    local index
    local nummer
    local auswahl

    [ "${#liste[@]}" -gt 0 ] || return 1

    while true; do
        start=$((seite * 8))
        ende=$((start + 8))

        if [ "$ende" -gt "${#liste[@]}" ]; then
            ende="${#liste[@]}"
        fi

        clear_screen

        echo "$titel"
        echo

        nummer=1

        for ((index = start; index < ende; index++)); do
            printf '[%d] %s\n' \
                "$nummer" \
                "${liste[$index]}"

            nummer=$((nummer + 1))
        done

        echo

        if [ "$ende" -lt "${#liste[@]}" ]; then
            echo "[N] Weiter"
        fi

        if [ "$seite" -gt 0 ]; then
            echo "[V] Zurückblättern"
        fi

        echo "[Z] Zurück"

        prompt
        taste auswahl

        case "${auswahl,,}" in
            [1-8])
                index=$((start + auswahl - 1))

                if [ "$index" -lt "$ende" ]; then
                    AUSWAHL="${liste[$index]}"
                    return 0
                fi
                ;;

            n)
                if [ "$ende" -lt "${#liste[@]}" ]; then
                    seite=$((seite + 1))
                fi
                ;;

            v)
                if [ "$seite" -gt 0 ]; then
                    seite=$((seite - 1))
                fi
                ;;

            z)
                return 1
                ;;
        esac
    done
}

benutzer_waehlen() {
    local name
    local uid_num
    local bezeichnung

    local -a benutzer=("root")

    while IFS=: read -r name _ uid_num _ _ _ _; do
        [ "$name" = "root" ] && continue
        [ "$uid_num" -eq 65534 ] && continue

        if [ "$uid_num" -ge "$UID_MIN" ]; then
            bezeichnung="Benutzer"
        else
            bezeichnung="Systemkonto"
        fi

        benutzer+=("$name ($bezeichnung)")
    done < <(getent passwd)

    liste_waehlen "Benutzer auswählen" "${benutzer[@]}" ||
        return 1

    AUSWAHL="${AUSWAHL%% (*}"
}

gruppen_waehlen() {
    local name
    local -a gruppen=()

    while IFS=: read -r name _; do
        gruppen+=("$name")
    done < <(getent group)

    liste_waehlen "Gruppe auswählen" "${gruppen[@]}"
}

benutzer_aktion() {
    local benutzer
    local gruppe
    local mitglied
    local auswahl

    benutzer_waehlen || return

    benutzer="$AUSWAHL"

    while true; do
        gruppe="$(stat -c '%G' -- "$ORDNER")"

        if id -nG "$benutzer" 2>/dev/null |
            tr ' ' '\n' |
            grep -Fxq -- "$gruppe"; then
            mitglied="Ja"
        else
            mitglied="Nein"
        fi

        clear_screen

        echo "Benutzerzugriff"
        echo

        if [ "$benutzer" != "root" ]; then
            if [ "$mitglied" = "Ja" ]; then
                echo "[1] Aus Gruppe entfernen"
            else
                echo "[1] Zur Gruppe hinzufügen"
            fi
        fi

        echo "[2] Rechtebaum anzeigen"
        echo "[Z] Zurück"

        echo
        echo "Benutzer: $benutzer"
        echo "Zugriff:  $(zugriff "$benutzer" "$ORDNER")"
        echo "Gruppe:   $gruppe"

        if [ "$benutzer" != "root" ]; then
            echo "Mitglied: $mitglied"
        fi

        prompt
        taste auswahl

        case "${auswahl,,}" in
            1)
                [ "$benutzer" = "root" ] && continue

                if [ "$mitglied" = "Ja" ]; then
                    if [ "$(id -gn "$benutzer")" = "$gruppe" ]; then
                        ERGEBNIS="Hauptgruppe kann nicht entfernt werden."

                    elif gpasswd -d "$benutzer" "$gruppe" \
                        >/dev/null 2>&1; then
                        ERGEBNIS="$benutzer wurde aus $gruppe entfernt."

                    else
                        ERGEBNIS="Änderung fehlgeschlagen."
                    fi
                else
                    if usermod -aG "$gruppe" "$benutzer"; then
                        ERGEBNIS="$benutzer wurde zu $gruppe hinzugefügt."
                    else
                        ERGEBNIS="Änderung fehlgeschlagen."
                    fi
                fi

                return
                ;;

            2)
                baum "$benutzer"
                return
                ;;

            z)
                return
                ;;
        esac
    done
}

rechte_waehlen() {
    local bereich="$1"
    local titel="$2"
    local auswahl
    local modus

    clear_screen

    echo "$titel"
    echo
    echo "[1] Kein Zugriff"
    echo "[2] Betreten"
    echo "[3] Lesen und Betreten"
    echo "[4] Schreiben und Betreten"
    echo "[5] Lesen, Schreiben und Betreten"
    echo "[Z] Zurück"

    echo
    status "$ORDNER"

    prompt
    taste auswahl

    case "${auswahl,,}" in
        1) modus="---" ;;
        2) modus="--x" ;;
        3) modus="r-x" ;;
        4) modus="-wx" ;;
        5) modus="rwx" ;;
        z) return ;;
        *) return ;;
    esac

    if chmod "$bereich=$modus" -- "$ORDNER"; then
        ERGEBNIS="$titel wurden geändert."
    else
        ERGEBNIS="Änderung fehlgeschlagen."
    fi
}

baum() {
    local benutzer="${1:-}"
    local pfad
    local anzahl=0
    local rechte
    local typ
    local besitzer
    local gruppe
    local auswahl

    clear_screen

    if [ -n "$benutzer" ]; then
        echo "Rechtebaum für $benutzer"
    else
        echo "Gesamter Rechtebaum"
    fi

    echo

    while IFS= read -r -d '' pfad; do
        if [ -n "$benutzer" ]; then
            echo "$pfad"
            echo "  Zugriff: $(zugriff "$benutzer" "$pfad")"
        else
            rechte="$(stat -c '%A' -- "$pfad" 2>/dev/null)" ||
                continue

            typ="$(art "$pfad")"
            besitzer="$(stat -c '%U' -- "$pfad")"
            gruppe="$(stat -c '%G' -- "$pfad")"

            echo "$pfad"
            echo "  Besitzer: $besitzer | $(rechte_text "${rechte:1:3}" "$typ")"
            echo "  Gruppe:   $gruppe | $(rechte_text "${rechte:4:3}" "$typ")"
            echo "  Andere:   $(rechte_text "${rechte:7:3}" "$typ")"
        fi

        echo

        anzahl=$((anzahl + 1))

        if [ "$anzahl" -ge 300 ]; then
            echo "Ausgabe nach 300 Einträgen beendet."
            break
        fi
    done < <(
        find "$ORDNER" -maxdepth 3 -print0 2>/dev/null
    )

    echo "[Z] Zurück"
    prompt

    while true; do
        taste auswahl

        if [ "${auswahl,,}" = "z" ]; then
            return
        fi
    done
}

while true; do
    ansicht
    taste WAHL

    case "${WAHL,,}" in
        1)
            benutzer_aktion
            ;;

        2)
            if gruppen_waehlen; then
                if chgrp -- "$AUSWAHL" "$ORDNER"; then
                    ERGEBNIS="Gruppe wurde zu $AUSWAHL geändert."
                else
                    ERGEBNIS="Änderung fehlgeschlagen."
                fi
            fi
            ;;

        3)
            rechte_waehlen "g" "Gruppenrechte"
            ;;

        4)
            rechte_waehlen "o" "Rechte für Andere"
            ;;

        5)
            baum
            ;;

        6)
            if benutzer_waehlen; then
                baum "$AUSWAHL"
            fi
            ;;

        q)
            clear_screen
            exit 0
            ;;
    esac
done

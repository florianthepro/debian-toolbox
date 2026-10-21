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

kopf() {
    printf '\033[2J\033[H'
    echo "Ordnerrechte"
    echo "$ORDNER"
    echo
}

taste() {
    local variablenname="$1"
    local wert

    IFS= read -rsn1 wert <&3 || exit 0
    printf -v "$variablenname" '%s' "$wert"
}

meldung() {
    echo
    echo "$1"
    echo
    echo "Taste drücken ..."
    taste meldung_taste
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
    local ergebnis=""

    [ "${rechte:0:1}" = "r" ] &&
        ergebnis="Lesen"

    [ "${rechte:1:1}" = "w" ] &&
        ergebnis="${ergebnis:+$ergebnis, }Schreiben"

    case "${rechte:2:1}" in
        x|s|t)
            if [ "$typ" = "Ordner" ]; then
                ergebnis="${ergebnis:+$ergebnis, }Betreten"
            else
                ergebnis="${ergebnis:+$ergebnis, }Ausführen"
            fi
            ;;
    esac

    echo "${ergebnis:-Kein Zugriff}"
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

    echo "$pfad"
    echo "  Art:      $typ"
    echo "  Besitzer: $besitzer | $(rechte_text "${rechte:1:3}" "$typ")"
    echo "  Gruppe:   $gruppe | $(rechte_text "${rechte:4:3}" "$typ")"
    echo "  Andere:   $(rechte_text "${rechte:7:3}" "$typ")"
}

zugriff() {
    local benutzer="$1"
    local pfad="$2"
    local typ
    local ergebnis=""

    typ="$(art "$pfad")"

    if su -s /bin/sh "$benutzer" -c 'test -r "$1"' sh "$pfad" 2>/dev/null; then
        ergebnis="Lesen"
    fi

    if su -s /bin/sh "$benutzer" -c 'test -w "$1"' sh "$pfad" 2>/dev/null; then
        ergebnis="${ergebnis:+$ergebnis, }Schreiben"
    fi

    if su -s /bin/sh "$benutzer" -c 'test -x "$1"' sh "$pfad" 2>/dev/null; then
        if [ "$typ" = "Ordner" ]; then
            ergebnis="${ergebnis:+$ergebnis, }Betreten"
        else
            ergebnis="${ergebnis:+$ergebnis, }Ausführen"
        fi
    fi

    echo "${ergebnis:-Kein Zugriff}"
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
    local taste_wert

    if [ "${#liste[@]}" -eq 0 ]; then
        meldung "Keine Einträge."
        return 1
    fi

    while true; do
        start=$((seite * 8))
        ende=$((start + 8))

        [ "$ende" -gt "${#liste[@]}" ] &&
            ende="${#liste[@]}"

        kopf
        echo "$titel"
        echo

        nummer=1

        for ((index = start; index < ende; index++)); do
            printf '[%d] %s\n' "$nummer" "${liste[$index]}"
            nummer=$((nummer + 1))
        done

        echo

        [ "$ende" -lt "${#liste[@]}" ] &&
            echo "[N] Weiter"

        [ "$seite" -gt 0 ] &&
            echo "[V] Zurückblättern"

        echo "[Z] Zurück"

        taste taste_wert

        case "${taste_wert,,}" in
            [1-8])
                index=$((start + taste_wert - 1))

                if [ "$index" -lt "$ende" ]; then
                    AUSWAHL="${liste[$index]}"
                    return 0
                fi
                ;;

            n)
                [ "$ende" -lt "${#liste[@]}" ] &&
                    seite=$((seite + 1))
                ;;

            v)
                [ "$seite" -gt 0 ] &&
                    seite=$((seite - 1))
                ;;

            z)
                return 1
                ;;
        esac
    done
}

benutzer_liste() {
    local typ="$1"
    local name
    local uid_num
    local -a benutzer=()

    while IFS=: read -r name _ uid_num _ _ _ _; do
        [ "$name" = "root" ] && continue
        [ "$uid_num" -eq 65534 ] && continue

        if [ "$typ" = "normal" ] && [ "$uid_num" -ge "$UID_MIN" ]; then
            benutzer+=("$name")
        fi

        if [ "$typ" = "system" ] && [ "$uid_num" -lt "$UID_MIN" ]; then
            benutzer+=("$name")
        fi
    done < <(getent passwd)

    if [ "$typ" = "normal" ]; then
        liste_waehlen "Normale Benutzer" "${benutzer[@]}"
    else
        liste_waehlen "Systembenutzer" "${benutzer[@]}"
    fi
}

benutzer_menu() {
    local benutzer="$1"
    local gruppe
    local auswahl
    local mitglied

    while true; do
        gruppe="$(stat -c '%G' -- "$ORDNER")"

        if id -nG "$benutzer" 2>/dev/null |
            tr ' ' '\n' |
            grep -Fxq -- "$gruppe"; then
            mitglied="Ja"
        else
            mitglied="Nein"
        fi

        kopf

        echo "Benutzer: $benutzer"
        echo "Zugriff:  $(zugriff "$benutzer" "$ORDNER")"
        echo "Gruppe:   $gruppe"

        [ "$benutzer" != "root" ] &&
            echo "Mitglied: $mitglied"

        echo

        if [ "$benutzer" = "root" ]; then
            echo "[Z] Zurück"
        elif [ "$mitglied" = "Ja" ]; then
            echo "[1] Aus Gruppe entfernen"
            echo "[Z] Zurück"
        else
            echo "[1] Zur Gruppe hinzufügen"
            echo "[Z] Zurück"
        fi

        taste auswahl

        case "${auswahl,,}" in
            1)
                [ "$benutzer" = "root" ] && continue

                if [ "$mitglied" = "Ja" ]; then
                    if [ "$(id -gn "$benutzer")" = "$gruppe" ]; then
                        meldung "Hauptgruppe kann nicht entfernt werden."
                    elif gpasswd -d "$benutzer" "$gruppe" >/dev/null 2>&1; then
                        meldung "$benutzer wurde entfernt."
                    else
                        meldung "Änderung fehlgeschlagen."
                    fi
                else
                    if usermod -aG "$gruppe" "$benutzer"; then
                        meldung "$benutzer wurde hinzugefügt."
                    else
                        meldung "Änderung fehlgeschlagen."
                    fi
                fi
                ;;

            z)
                return
                ;;
        esac
    done
}

gruppen_liste() {
    local name
    local -a gruppen=()

    while IFS=: read -r name _; do
        gruppen+=("$name")
    done < <(getent group)

    liste_waehlen "Gruppe auswählen" "${gruppen[@]}"
}

rechte_waehlen() {
    local bereich="$1"
    local titel="$2"
    local auswahl
    local modus

    kopf

    echo "$titel"
    echo
    echo "[1] Kein Zugriff"
    echo "[2] Betreten"
    echo "[3] Lesen und Betreten"
    echo "[4] Schreiben und Betreten"
    echo "[5] Lesen, Schreiben und Betreten"
    echo "[Z] Zurück"

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
        meldung "Rechte geändert."
    else
        meldung "Änderung fehlgeschlagen."
    fi
}

gruppe_menu() {
    local auswahl
    local name

    while true; do
        kopf
        status "$ORDNER"

        echo
        echo "[1] Gruppe auswählen"
        echo "[2] Gruppe erstellen"
        echo "[3] Gruppenrechte"
        echo "[4] Rechte für Andere"
        echo "[Z] Zurück"

        taste auswahl

        case "${auswahl,,}" in
            1)
                if gruppen_liste; then
                    if chgrp -- "$AUSWAHL" "$ORDNER"; then
                        meldung "Gruppe geändert."
                    else
                        meldung "Änderung fehlgeschlagen."
                    fi
                fi
                ;;

            2)
                kopf
                printf "Gruppenname: " >&3
                IFS= read -r name <&3

                if ! [[ "$name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
                    meldung "Ungültiger Gruppenname."
                elif getent group "$name" >/dev/null; then
                    meldung "Gruppe ist bereits vorhanden."
                elif groupadd -- "$name" &&
                    chgrp -- "$name" "$ORDNER"; then
                    meldung "Gruppe erstellt und ausgewählt."
                else
                    meldung "Änderung fehlgeschlagen."
                fi
                ;;

            3)
                rechte_waehlen "g" "Gruppenrechte"
                ;;

            4)
                rechte_waehlen "o" "Rechte für Andere"
                ;;

            z)
                return
                ;;
        esac
    done
}

baum() {
    local benutzer="${1:-}"
    local pfad
    local anzahl=0

    kopf

    if [ -n "$benutzer" ]; then
        echo "Benutzer: $benutzer"
    else
        echo "Alle Rechte"
    fi

    echo "Tiefe: 3"
    echo

    while IFS= read -r -d '' pfad; do
        if [ -n "$benutzer" ]; then
            echo "$pfad"
            echo "  Zugriff: $(zugriff "$benutzer" "$pfad")"
        else
            status "$pfad"
        fi

        echo

        anzahl=$((anzahl + 1))

        if [ "$anzahl" -ge 300 ]; then
            echo "Ausgabe bei 300 Einträgen beendet."
            break
        fi
    done < <(
        find "$ORDNER" -maxdepth 3 -print0 2>/dev/null
    )

    echo "Taste drücken ..."
    taste baum_taste
}

baum_menu() {
    local auswahl

    kopf

    echo "[1] Alle Rechte"
    echo "[2] Normale Benutzer"
    echo "[3] Systembenutzer"
    echo "[4] root"
    echo "[Z] Zurück"

    taste auswahl

    case "${auswahl,,}" in
        1)
            baum
            ;;

        2)
            benutzer_liste "normal" &&
                baum "$AUSWAHL"
            ;;

        3)
            benutzer_liste "system" &&
                baum "$AUSWAHL"
            ;;

        4)
            baum "root"
            ;;

        z)
            return
            ;;
    esac
}

while true; do
    kopf
    status "$ORDNER"

    echo
    echo "[1] Normale Benutzer"
    echo "[2] Systembenutzer"
    echo "[3] root"
    echo "[4] Gruppe und Rechte"
    echo "[5] Baumansicht"
    echo "[Q] Beenden"

    taste auswahl

    case "${auswahl,,}" in
        1)
            benutzer_liste "normal" &&
                benutzer_menu "$AUSWAHL"
            ;;

        2)
            benutzer_liste "system" &&
                benutzer_menu "$AUSWAHL"
            ;;

        3)
            benutzer_menu "root"
            ;;

        4)
            gruppe_menu
            ;;

        5)
            baum_menu
            ;;

        q)
            printf '\033[2J\033[H'
            exit 0
            ;;
    esac
done

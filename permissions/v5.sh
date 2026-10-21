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
AUSWAHL=""

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

    if [ -z "${SUDO_USER:-}" ]; then
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
    else
        echo "Objekt"
    fi
}

rechte_text() {
    local rechte="$1"
    local typ="$2"
    local ausgabe=""

    [ "${rechte:0:1}" = "r" ] &&
        ausgabe="Lesen"

    [ "${rechte:1:1}" = "w" ] &&
        ausgabe="${ausgabe:+$ausgabe, }Schreiben"

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
    local rechte
    local typ
    local besitzer
    local gruppe

    rechte="$(stat -c '%A' -- "$ORDNER")"
    typ="$(art "$ORDNER")"
    besitzer="$(stat -c '%U' -- "$ORDNER")"
    gruppe="$(stat -c '%G' -- "$ORDNER")"

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

benutzer_laden() {
    USERS=("root")

    local name
    local uid_num
    local bezeichnung

    while IFS=: read -r name _ uid_num _ _ _ _; do
        [ "$name" = "root" ] && continue
        [ "$uid_num" -eq 65534 ] && continue

        if [ "$uid_num" -ge "$UID_MIN" ]; then
            bezeichnung="Benutzer"
        else
            bezeichnung="Systemkonto"
        fi

        USERS+=("$name|$bezeichnung")
    done < <(getent passwd)
}

gruppen_laden() {
    GROUPS=()

    local name
    local gid

    while IFS=: read -r name _ gid _; do
        GROUPS+=("$name|$gid")
    done < <(getent group)
}

benutzername() {
    printf '%s' "${1%%|*}"
}

gruppenname() {
    printf '%s' "${1%%|*}"
}

liste_waehlen() {
    local titel="$1"
    local typ="$2"

    shift 2

    local -a liste=("$@")
    local seite=0
    local pro_seite=8
    local gesamt="${#liste[@]}"
    local start
    local ende
    local index
    local nummer
    local auswahl
    local eintrag
    local name
    local information

    [ "$gesamt" -gt 0 ] || return 1

    while true; do
        start=$((seite * pro_seite))
        ende=$((start + pro_seite))

        if [ "$ende" -gt "$gesamt" ]; then
            ende="$gesamt"
        fi

        clear_screen

        echo "$titel"
        echo

        nummer=1

        for ((index = start; index < ende; index++)); do
            eintrag="${liste[$index]}"

            if [ "$typ" = "Benutzer" ]; then
                name="$(benutzername "$eintrag")"
                information="${eintrag#*|}"

                if [ "$eintrag" = "$information" ]; then
                    information=""
                fi
            else
                name="$(gruppenname "$eintrag")"
                information=""
            fi

            printf '[%d] %-24s %s\n' \
                "$nummer" \
                "$name" \
                "$information"

            nummer=$((nummer + 1))
        done

        echo
        printf '%d-%d/%d\n' \
            "$((start + 1))" \
            "$ende" \
            "$gesamt"

        echo

        [ "$seite" -gt 0 ] &&
            echo "[V] Vorherige Seite"

        [ "$ende" -lt "$gesamt" ] &&
            echo "[N] Nächste Seite"

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
                if [ "$ende" -lt "$gesamt" ]; then
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

gruppen_fuer_benutzer() {
    local benutzer="$1"
    local seite=0
    local pro_seite=8
    local gesamt="${#GROUPS[@]}"
    local start
    local ende
    local index
    local nummer
    local auswahl
    local gruppe
    local markierung
    local ordnergruppe

    ordnergruppe="$(stat -c '%G' -- "$ORDNER")"

    while true; do
        start=$((seite * pro_seite))
        ende=$((start + pro_seite))

        if [ "$ende" -gt "$gesamt" ]; then
            ende="$gesamt"
        fi

        clear_screen

        echo "Benutzer: $benutzer"
        echo "Zugriff:  $(zugriff "$benutzer" "$ORDNER")"
        echo
        echo "Gruppenmitgliedschaften"
        echo

        nummer=1

        for ((index = start; index < ende; index++)); do
            gruppe="$(gruppenname "${GROUPS[$index]}")"
            markierung=" "

            if id -nG "$benutzer" 2>/dev/null |
                tr ' ' '\n' |
                grep -Fxq -- "$gruppe"; then
                markierung="x"
            fi

            if [ "$gruppe" = "$ordnergruppe" ]; then
                printf '[%d] [%s] %-20s Ordnergruppe\n' \
                    "$nummer" \
                    "$markierung" \
                    "$gruppe"
            else
                printf '[%d] [%s] %s\n' \
                    "$nummer" \
                    "$markierung" \
                    "$gruppe"
            fi

            nummer=$((nummer + 1))
        done

        echo
        printf '%d-%d/%d\n' \
            "$((start + 1))" \
            "$ende" \
            "$gesamt"

        echo

        [ "$seite" -gt 0 ] &&
            echo "[V] Vorherige Seite"

        [ "$ende" -lt "$gesamt" ] &&
            echo "[N] Nächste Seite"

        echo "[B] Rechtebaum"
        echo "[Z] Zurück"
        echo
        echo "[x] Mitglied"

        prompt
        taste auswahl

        case "${auswahl,,}" in
            [1-8])
                index=$((start + auswahl - 1))

                if [ "$index" -lt "$ende" ]; then
                    AUSWAHL="${GROUPS[$index]}"
                    return 0
                fi
                ;;

            n)
                if [ "$ende" -lt "$gesamt" ]; then
                    seite=$((seite + 1))
                fi
                ;;

            v)
                if [ "$seite" -gt 0 ]; then
                    seite=$((seite - 1))
                fi
                ;;

            b)
                rechtebaum "$benutzer"
                return 1
                ;;

            z)
                return 1
                ;;
        esac
    done
}

benutzer_und_gruppen() {
    local benutzer
    local gruppe
    local hauptgruppe

    benutzer_laden

    liste_waehlen \
        "Benutzer auswählen" \
        "Benutzer" \
        "${USERS[@]}" ||
        return

    benutzer="$(benutzername "$AUSWAHL")"

    gruppen_laden

    gruppen_fuer_benutzer "$benutzer" ||
        return

    gruppe="$(gruppenname "$AUSWAHL")"

    if [ "$benutzer" = "root" ]; then
        ERGEBNIS="root wurde nicht geändert."
        return
    fi

    hauptgruppe="$(id -gn "$benutzer")"

    if id -nG "$benutzer" |
        tr ' ' '\n' |
        grep -Fxq -- "$gruppe"; then

        if [ "$hauptgruppe" = "$gruppe" ]; then
            ERGEBNIS="$gruppe ist die Hauptgruppe von $benutzer."

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
}

benutzer_fuer_gruppe() {
    local gruppe="$1"
    local seite=0
    local pro_seite=8
    local gesamt="${#USERS[@]}"
    local start
    local ende
    local index
    local nummer
    local auswahl
    local benutzer
    local eintrag
    local markierung
    local information

    while true; do
        start=$((seite * pro_seite))
        ende=$((start + pro_seite))

        if [ "$ende" -gt "$gesamt" ]; then
            ende="$gesamt"
        fi

        clear_screen

        echo "Gruppe: $gruppe"
        echo
        echo "Mitglieder"
        echo

        nummer=1

        for ((index = start; index < ende; index++)); do
            eintrag="${USERS[$index]}"
            benutzer="$(benutzername "$eintrag")"
            information="${eintrag#*|}"
            markierung=" "

            if [ "$eintrag" = "$information" ]; then
                information=""
            fi

            if id -nG "$benutzer" 2>/dev/null |
                tr ' ' '\n' |
                grep -Fxq -- "$gruppe"; then
                markierung="x"
            fi

            printf '[%d] [%s] %-20s %s\n' \
                "$nummer" \
                "$markierung" \
                "$benutzer" \
                "$information"

            nummer=$((nummer + 1))
        done

        echo
        printf '%d-%d/%d\n' \
            "$((start + 1))" \
            "$ende" \
            "$gesamt"

        echo

        [ "$seite" -gt 0 ] &&
            echo "[V] Vorherige Seite"

        [ "$ende" -lt "$gesamt" ] &&
            echo "[N] Nächste Seite"

        echo "[S] Als Ordnergruppe setzen"
        echo "[Z] Zurück"
        echo
        echo "[x] Mitglied"

        prompt
        taste auswahl

        case "${auswahl,,}" in
            [1-8])
                index=$((start + auswahl - 1))

                if [ "$index" -lt "$ende" ]; then
                    AUSWAHL="${USERS[$index]}"
                    return 0
                fi
                ;;

            n)
                if [ "$ende" -lt "$gesamt" ]; then
                    seite=$((seite + 1))
                fi
                ;;

            v)
                if [ "$seite" -gt 0 ]; then
                    seite=$((seite - 1))
                fi
                ;;

            s)
                if chgrp -- "$gruppe" "$ORDNER"; then
                    ERGEBNIS="$gruppe ist jetzt die Ordnergruppe."
                else
                    ERGEBNIS="Änderung fehlgeschlagen."
                fi

                return 1
                ;;

            z)
                return 1
                ;;
        esac
    done
}

gruppen_und_benutzer() {
    local gruppe
    local benutzer
    local hauptgruppe

    gruppen_laden

    liste_waehlen \
        "Gruppe auswählen" \
        "Gruppe" \
        "${GROUPS[@]}" ||
        return

    gruppe="$(gruppenname "$AUSWAHL")"

    benutzer_laden

    benutzer_fuer_gruppe "$gruppe" ||
        return

    benutzer="$(benutzername "$AUSWAHL")"

    if [ "$benutzer" = "root" ]; then
        ERGEBNIS="root wurde nicht geändert."
        return
    fi

    hauptgruppe="$(id -gn "$benutzer")"

    if id -nG "$benutzer" |
        tr ' ' '\n' |
        grep -Fxq -- "$gruppe"; then

        if [ "$hauptgruppe" = "$gruppe" ]; then
            ERGEBNIS="$gruppe ist die Hauptgruppe von $benutzer."

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
    status

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
        ERGEBNIS="$titel geändert."
    else
        ERGEBNIS="Änderung fehlgeschlagen."
    fi
}

rechtebaum() {
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

        [ "${auswahl,,}" = "z" ] &&
            return
    done
}

rechtebaum_benutzer() {
    local benutzer

    benutzer_laden

    liste_waehlen \
        "Benutzer auswählen" \
        "Benutzer" \
        "${USERS[@]}" ||
        return

    benutzer="$(benutzername "$AUSWAHL")"

    rechtebaum "$benutzer"
}

hauptansicht() {
    clear_screen

    echo "Ordnerrechte"
    echo
    echo "[1] Benutzer und Gruppen"
    echo "[2] Gruppen und Benutzer"
    echo "[3] Gruppenrechte"
    echo "[4] Rechte für Andere"
    echo "[5] Gesamter Rechtebaum"
    echo "[6] Rechtebaum eines Benutzers"
    echo "[Q] Beenden"

    if [ -n "$ERGEBNIS" ]; then
        echo
        echo "Ergebnis: $ERGEBNIS"
    fi

    echo
    status
    prompt
}

while true; do
    hauptansicht
    taste HAUPTAUSWAHL

    case "${HAUPTAUSWAHL,,}" in
        1)
            benutzer_und_gruppen
            ;;

        2)
            gruppen_und_benutzer
            ;;

        3)
            rechte_waehlen "g" "Gruppenrechte"
            ;;

        4)
            rechte_waehlen "o" "Rechte für Andere"
            ;;

        5)
            rechtebaum
            ;;

        6)
            rechtebaum_benutzer
            ;;

        q)
            clear_screen
            exit 0
            ;;
    esac
done

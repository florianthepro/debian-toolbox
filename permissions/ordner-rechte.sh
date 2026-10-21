#!/usr/bin/env bash
# Direkt ausführen: curl -fsSL https://raw.githubusercontent.com/florianthepro/debian-toolbox/main/permissions/ordner-rechte.sh | sudo env STARTORDNER="$PWD" bash

set -u

if [ -r /dev/tty ]; then
    exec </dev/tty >/dev/tty 2>&1
fi

ORDNER="${STARTORDNER:-$PWD}"

fehler() {
    printf 'Fehler: %s\n' "$*" >&2
    exit 1
}

pause() {
    printf '\nEnter drücken, um fortzufahren ...'
    read -r _
}

if [ "$(id -u)" -ne 0 ]; then
    fehler "Dieses Skript muss als root oder mit sudo ausgeführt werden."
fi

if [ ! -d "$ORDNER" ]; then
    fehler "Ordner existiert nicht: $ORDNER"
fi

ORDNER="$(cd -- "$ORDNER" 2>/dev/null && pwd -P)" ||
    fehler "Ordner kann nicht geöffnet werden."

case "$ORDNER" in
    /|/bin|/boot|/dev|/etc|/lib|/lib32|/lib64|/libx32|/proc|/root|/run|/sbin|/sys|/usr|/var)
        printf 'WARNUNG: "%s" ist ein wichtiges Systemverzeichnis.\n' "$ORDNER"
        printf 'Direkte Änderungen daran können das System beschädigen.\n'
        printf 'Trotzdem fortfahren? [j/N]: '
        read -r ANTWORT

        case "$ANTWORT" in
            j|J|ja|JA|Ja)
                ;;
            *)
                printf 'Abgebrochen.\n'
                exit 0
                ;;
        esac
        ;;
esac

benutzer_auswaehlen() {
    local eintrag name uid shell
    local -a benutzer=()

    while IFS=: read -r name _ uid _ _ _ shell; do
        if [ "$uid" -ge 1000 ] &&
           [ "$uid" -ne 65534 ] &&
           [ "$shell" != "/usr/sbin/nologin" ] &&
           [ "$shell" != "/sbin/nologin" ] &&
           [ "$shell" != "/bin/false" ]; then
            benutzer+=("$name")
        fi
    done < <(getent passwd)

    if [ "${#benutzer[@]}" -eq 0 ]; then
        fehler "Keine normalen Benutzer gefunden."
    fi

    printf '\nBenutzer auswählen:\n\n'

    PS3=$'\nNummer eingeben oder mit Strg+C abbrechen: '

    select eintrag in "${benutzer[@]}"; do
        if [ -n "${eintrag:-}" ]; then
            AUSGEWAEHLTER_BENUTZER="$eintrag"
            return 0
        fi

        printf 'Ungültige Auswahl.\n'
    done
}

gruppenname_erzeugen() {
    local basis hash

    basis="$(basename -- "$ORDNER")"

    basis="$(printf '%s' "$basis" |
        tr '[:upper:]' '[:lower:]' |
        tr -cd 'a-z0-9_-')"

    if [ -z "$basis" ]; then
        basis="ordner"
    fi

    hash="$(printf '%s' "$ORDNER" | cksum | awk '{print $1}')"

    GRUPPE="zugriff-${basis}-${hash}"

    GRUPPE="${GRUPPE:0:31}"
}

rechte_auswaehlen() {
    printf '\nRechte für "%s" auf "%s":\n\n' \
        "$AUSGEWAEHLTER_BENUTZER" "$ORDNER"

    printf '  1) Lesen und betreten\n'
    printf '  2) Lesen, schreiben und betreten\n'
    printf '  3) Benutzerzugriff entfernen\n'
    printf '  4) Nur prüfen, nichts ändern\n'
    printf '  5) Abbrechen\n\n'

    printf 'Auswahl [1-5]: '
    read -r AUSWAHL

    case "$AUSWAHL" in
        1)
            MODUS="r-x"
            ;;
        2)
            MODUS="rwx"
            ;;
        3)
            MODUS="entfernen"
            ;;
        4)
            MODUS="pruefen"
            ;;
        5)
            printf 'Abgebrochen.\n'
            exit 0
            ;;
        *)
            fehler "Ungültige Auswahl: $AUSWAHL"
            ;;
    esac
}

zugriff_pruefen() {
    local lesen="nein"
    local schreiben="nein"
    local betreten="nein"

    if su -s /bin/sh "$AUSGEWAEHLTER_BENUTZER" \
        -c "test -r \"\$1\"" sh "$ORDNER" 2>/dev/null; then
        lesen="ja"
    fi

    if su -s /bin/sh "$AUSGEWAEHLTER_BENUTZER" \
        -c "test -w \"\$1\"" sh "$ORDNER" 2>/dev/null; then
        schreiben="ja"
    fi

    if su -s /bin/sh "$AUSGEWAEHLTER_BENUTZER" \
        -c "test -x \"\$1\"" sh "$ORDNER" 2>/dev/null; then
        betreten="ja"
    fi

    printf '\nEffektiver Zugriff:\n'
    printf '  Benutzer:  %s\n' "$AUSGEWAEHLTER_BENUTZER"
    printf '  Ordner:    %s\n' "$ORDNER"
    printf '  Lesen:     %s\n' "$lesen"
    printf '  Schreiben: %s\n' "$schreiben"
    printf '  Betreten:  %s\n' "$betreten"
}

benutzer_auswaehlen
gruppenname_erzeugen
rechte_auswaehlen

if [ "$MODUS" = "pruefen" ]; then
    zugriff_pruefen
    exit 0
fi

if [ "$MODUS" = "entfernen" ]; then
    if getent group "$GRUPPE" >/dev/null; then
        gpasswd -d "$AUSGEWAEHLTER_BENUTZER" "$GRUPPE" 2>/dev/null || true
        printf '\nBenutzer "%s" wurde aus Gruppe "%s" entfernt.\n' \
            "$AUSGEWAEHLTER_BENUTZER" "$GRUPPE"
    else
        printf '\nDie verwaltete Gruppe "%s" existiert nicht.\n' "$GRUPPE"
    fi

    zugriff_pruefen
    exit 0
fi

if ! getent group "$GRUPPE" >/dev/null; then
    groupadd "$GRUPPE" ||
        fehler "Gruppe konnte nicht erstellt werden: $GRUPPE"
fi

chgrp "$GRUPPE" "$ORDNER" ||
    fehler "Gruppe des Ordners konnte nicht geändert werden."

usermod -a -G "$GRUPPE" "$AUSGEWAEHLTER_BENUTZER" ||
    fehler "Benutzer konnte nicht zur Gruppe hinzugefügt werden."

case "$MODUS" in
    r-x)
        chmod g+rx,g-w "$ORDNER" ||
            fehler "Ordnerrechte konnten nicht gesetzt werden."
        ;;
    rwx)
        chmod g+rwx "$ORDNER" ||
            fehler "Ordnerrechte konnten nicht gesetzt werden."
        ;;
esac

printf '\nÄnderung durchgeführt:\n'
printf '  Ordner:   %s\n' "$ORDNER"
printf '  Benutzer: %s\n' "$AUSGEWAEHLTER_BENUTZER"
printf '  Gruppe:   %s\n' "$GRUPPE"
printf '  Rechte:   %s\n' "$MODUS"

printf '\nAktuelle Ordnerinformationen:\n'
ls -ld -- "$ORDNER"

printf '\nGruppenmitgliedschaft:\n'
id "$AUSGEWAEHLTER_BENUTZER"

zugriff_pruefen

printf '\nHinweis: Bei einer bestehenden Anmeldung kann eine neue Anmeldung\n'
printf 'notwendig sein, damit die neue Gruppenmitgliedschaft wirksam wird.\n'

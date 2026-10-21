#!/usr/bin/env bash
# Ausführen: curl -fsSL "https://raw.githubusercontent.com/florianthepro/debian-toolbox/main/permissions/ordner-rechte.sh" | sudo bash

set -u

ORDNER="$PWD"

exec 3<>/dev/tty || {
    echo "[✗] Kein interaktives Terminal verfügbar"
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    echo "[✗] Das Skript muss mit sudo ausgeführt werden"
    exit 1
fi

if [ ! -d "$ORDNER" ]; then
    echo "[✗] Ordner existiert nicht: $ORDNER"
    exit 1
fi

ORDNER="$(cd -- "$ORDNER" && pwd -P)"

echo
echo "Ordner-Rechteverwaltung"
echo "========================"
echo "Ordner: $ORDNER"
echo

BENUTZER=()

while IFS=: read -r NAME _ UID _ _ _ SHELL; do
    if [ "$UID" -ge 1000 ] &&
       [ "$UID" -ne 65534 ] &&
       [ "$SHELL" != "/usr/sbin/nologin" ] &&
       [ "$SHELL" != "/sbin/nologin" ] &&
       [ "$SHELL" != "/bin/false" ]; then
        BENUTZER+=("$NAME")
    fi
done </etc/passwd

if [ "${#BENUTZER[@]}" -eq 0 ]; then
    echo "[✗] Keine normalen Benutzer gefunden"
    exit 1
fi

echo "Benutzer auswählen:"
echo

for NUMMER in "${!BENUTZER[@]}"; do
    printf "  [%d] %s\n" "$((NUMMER + 1))" "${BENUTZER[$NUMMER]}"
done

echo
printf "Nummer: " >&3
read -r AUSWAHL <&3

if ! [[ "$AUSWAHL" =~ ^[0-9]+$ ]]; then
    echo "[✗] Ungültige Eingabe"
    exit 1
fi

INDEX=$((AUSWAHL - 1))

if [ "$INDEX" -lt 0 ] || [ "$INDEX" -ge "${#BENUTZER[@]}" ]; then
    echo "[✗] Benutzer existiert nicht"
    exit 1
fi

USER="${BENUTZER[$INDEX]}"
HASH="$(printf '%s' "$ORDNER" | cksum | awk '{print $1}')"
GRUPPE="ordner-$HASH"

echo
echo "Benutzer: $USER"
echo
echo "  [1] Lesen und betreten"
echo "  [2] Lesen, schreiben und betreten"
echo "  [3] Zugriff entfernen"
echo "  [4] Zugriff nur prüfen"
echo "  [5] Abbrechen"
echo
printf "Auswahl: " >&3
read -r AKTION <&3

pruefen() {
    echo
    echo "Zugriff von $USER auf $ORDNER"
    echo "------------------------------"

    if su -s /bin/sh "$USER" -c 'test -r "$1"' sh "$ORDNER" 2>/dev/null; then
        echo "[✓] Lesen"
    else
        echo "[✗] Lesen"
    fi

    if su -s /bin/sh "$USER" -c 'test -w "$1"' sh "$ORDNER" 2>/dev/null; then
        echo "[✓] Schreiben"
    else
        echo "[✗] Schreiben"
    fi

    if su -s /bin/sh "$USER" -c 'test -x "$1"' sh "$ORDNER" 2>/dev/null; then
        echo "[✓] Betreten"
    else
        echo "[✗] Betreten"
    fi
}

case "$AKTION" in
    1|2)
        if ! getent group "$GRUPPE" >/dev/null; then
            groupadd "$GRUPPE" || exit 1
        fi

        chgrp "$GRUPPE" "$ORDNER" || exit 1
        usermod -aG "$GRUPPE" "$USER" || exit 1

        if [ "$AKTION" = "1" ]; then
            chmod g=rx "$ORDNER" || exit 1
            RECHTE="Lesen und betreten"
        else
            chmod g=rwx "$ORDNER" || exit 1
            RECHTE="Lesen, schreiben und betreten"
        fi

        echo
        echo "[✓] Rechte wurden gesetzt"
        echo "    Benutzer: $USER"
        echo "    Gruppe:   $GRUPPE"
        echo "    Rechte:   $RECHTE"
        ;;

    3)
        if getent group "$GRUPPE" >/dev/null; then
            gpasswd -d "$USER" "$GRUPPE" >/dev/null 2>&1
            echo
            echo "[✓] $USER wurde aus $GRUPPE entfernt"
        else
            echo
            echo "[!] Für diesen Ordner wurde noch keine Gruppe erstellt"
        fi
        ;;

    4)
        pruefen
        exit 0
        ;;

    5)
        echo "[!] Abgebrochen"
        exit 0
        ;;

    *)
        echo "[✗] Ungültige Auswahl"
        exit 1
        ;;
esac

pruefen

echo
echo "Ordnerinformationen:"
ls -ld -- "$ORDNER"

echo
echo "[!] Bei bereits angemeldeten Benutzern kann eine neue Anmeldung nötig sein."

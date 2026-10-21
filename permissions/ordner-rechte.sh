#!/usr/bin/env bash
# Ausführen: curl -fsSL "https://raw.githubusercontent.com/florianthepro/debian-toolbox/main/permissions/ordner-rechte.sh" | sudo bash

set -u

exec 3<>/dev/tty || {
    echo "[✗] Kein interaktives Terminal verfügbar"
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    echo "[✗] Bitte mit sudo ausführen"
    exit 1
fi

ORDNER="$(pwd -P 2>/dev/null)" || {
    echo "[✗] Aktueller Ordner konnte nicht ermittelt werden"
    exit 1
}

if [ ! -d "$ORDNER" ]; then
    echo "[✗] Kein gültiger Ordner: $ORDNER"
    exit 1
fi

case "$ORDNER" in
    /|/bin|/boot|/dev|/etc|/lib|/lib32|/lib64|/libx32|/proc|/root|/run|/sbin|/sys|/usr|/var)
        echo
        echo "[!] Kritisches Systemverzeichnis: $ORDNER"
        printf "Wirklich verwalten? [ja/NEIN]: " >&3
        read -r ANTWORT <&3

        case "$ANTWORT" in
            ja|JA|Ja)
                ;;
            *)
                echo "[!] Abgebrochen"
                exit 0
                ;;
        esac
        ;;
esac

pause() {
    echo
    printf "Enter drücken ..." >&3
    read -r _ <&3
}

kopf() {
    clear 2>/dev/null || true
    echo "Ordner-Rechteverwaltung"
    echo "========================"
    echo "Ordner: $ORDNER"
    echo
}

rechte_anzeigen() {
    local besitzer
    local gruppe
    local rechte
    local oktal
    local gruppenmitglieder

    besitzer="$(stat -c '%U' -- "$ORDNER")"
    gruppe="$(stat -c '%G' -- "$ORDNER")"
    rechte="$(stat -c '%A' -- "$ORDNER")"
    oktal="$(stat -c '%a' -- "$ORDNER")"
    gruppenmitglieder="$(getent group "$gruppe" | cut -d: -f4)"

    [ -n "$gruppenmitglieder" ] || gruppenmitglieder="keine zusätzlichen Mitglieder"

    kopf
    echo "Aktueller Zustand"
    echo "-----------------"
    echo "Besitzer:          $besitzer"
    echo "Besitzergruppe:    $gruppe"
    echo "Rechte:            $rechte"
    echo "Numerisch:         $oktal"
    echo "Gruppenmitglieder: $gruppenmitglieder"
    echo
    echo "Besitzerrechte: ${rechte:1:3}"
    echo "Gruppenrechte:  ${rechte:4:3}"
    echo "Sonstige:       ${rechte:7:3}"
}

benutzer_laden() {
    NORMALE_BENUTZER=()
    SYSTEM_BENUTZER=()

    while IFS=: read -r name _ uid_num _ _ _ shell; do
        [ "$name" = "root" ] && continue
        [ "$uid_num" -eq 65534 ] && continue

        if [ "$uid_num" -ge 1000 ]; then
            NORMALE_BENUTZER+=("$name")
        else
            SYSTEM_BENUTZER+=("$name")
        fi
    done < <(getent passwd)
}

benutzer_aus_liste() {
    local titel="$1"
    shift
    local liste=("$@")
    local nummer
    local index

    kopf
    echo "$titel"
    echo

    if [ "${#liste[@]}" -eq 0 ]; then
        echo "[!] Keine Konten vorhanden"
        pause
        return 1
    fi

    for index in "${!liste[@]}"; do
        printf "  [%d] %s\n" "$((index + 1))" "${liste[$index]}"
    done

    echo "  [0] Zurück"
    echo
    printf "Auswahl: " >&3
    read -r nummer <&3

    [[ "$nummer" =~ ^[0-9]+$ ]] || return 1
    [ "$nummer" -eq 0 ] && return 1

    index=$((nummer - 1))

    if [ "$index" -lt 0 ] || [ "$index" -ge "${#liste[@]}" ]; then
        return 1
    fi

    AUSGEWAEHLTER_BENUTZER="${liste[$index]}"
    return 0
}

benutzer_auswaehlen() {
    local auswahl

    benutzer_laden

    while true; do
        kopf
        echo "Benutzerkategorie"
        echo "-----------------"
        echo "  [1] root – besonderes Administratorkonto"
        echo "  [2] Normale Benutzer"
        echo "  [3] Systemkonten"
        echo "  [0] Zurück"
        echo
        printf "Auswahl: " >&3
        read -r auswahl <&3

        case "$auswahl" in
            1)
                AUSGEWAEHLTER_BENUTZER="root"
                return 0
                ;;
            2)
                benutzer_aus_liste "Normale Benutzer" "${NORMALE_BENUTZER[@]}" &&
                    return 0
                ;;
            3)
                benutzer_aus_liste "Systemkonten" "${SYSTEM_BENUTZER[@]}" &&
                    return 0
                ;;
            0)
                return 1
                ;;
        esac
    done
}

zugriff_pruefen() {
    local user_name="$1"

    kopf
    echo "Effektiver Zugriff"
    echo "------------------"
    echo "Benutzer: $user_name"
    echo "Ordner:   $ORDNER"
    echo

    if [ "$user_name" = "root" ]; then
        echo "[✓] root ist das Administratorkonto"
        echo "[✓] Lesen"
        echo "[✓] Schreiben"
        echo "[✓] Betreten"
        echo
        echo "[!] root wird nicht über normale Ordnergruppen verwaltet"
        pause
        return
    fi

    if su -s /bin/sh "$user_name" -c 'test -r "$1"' sh "$ORDNER" 2>/dev/null; then
        echo "[✓] Lesen"
    else
        echo "[✗] Lesen"
    fi

    if su -s /bin/sh "$user_name" -c 'test -w "$1"' sh "$ORDNER" 2>/dev/null; then
        echo "[✓] Schreiben"
    else
        echo "[✗] Schreiben"
    fi

    if su -s /bin/sh "$user_name" -c 'test -x "$1"' sh "$ORDNER" 2>/dev/null; then
        echo "[✓] Betreten"
    else
        echo "[✗] Betreten"
    fi

    echo
    id "$user_name"
    pause
}

verwaltete_gruppe_erstellen() {
    local hash
    local gruppe

    hash="$(printf '%s' "$ORDNER" | cksum | awk '{print $1}')"
    gruppe="ordner-$hash"

    if ! getent group "$gruppe" >/dev/null; then
        groupadd -- "$gruppe" || {
            echo "[✗] Gruppe konnte nicht erstellt werden"
            pause
            return 1
        }
    fi

    chgrp -- "$gruppe" "$ORDNER" || {
        echo "[✗] Besitzergruppe konnte nicht geändert werden"
        pause
        return 1
    }

    echo "[✓] Besitzergruppe: $gruppe"
    pause
}

vorhandene_gruppe_auswaehlen() {
    local gruppen=()
    local name
    local nummer
    local index

    while IFS=: read -r name _; do
        gruppen+=("$name")
    done < <(getent group)

    kopf
    echo "Vorhandene Gruppe auswählen"
    echo

    for index in "${!gruppen[@]}"; do
        printf "  [%d] %s\n" "$((index + 1))" "${gruppen[$index]}"
    done

    echo "  [0] Zurück"
    echo
    printf "Auswahl: " >&3
    read -r nummer <&3

    [[ "$nummer" =~ ^[0-9]+$ ]] || return
    [ "$nummer" -eq 0 ] && return

    index=$((nummer - 1))

    if [ "$index" -lt 0 ] || [ "$index" -ge "${#gruppen[@]}" ]; then
        echo "[✗] Ungültige Auswahl"
        pause
        return
    fi

    chgrp -- "${gruppen[$index]}" "$ORDNER" || {
        echo "[✗] Besitzergruppe konnte nicht geändert werden"
        pause
        return
    }

    echo "[✓] Besitzergruppe: ${gruppen[$index]}"
    pause
}

gruppenrechte_setzen() {
    local auswahl

    kopf
    echo "Gruppenrechte setzen"
    echo "--------------------"
    echo "  [1] --- Kein Zugriff"
    echo "  [2] --x Nur betreten"
    echo "  [3] r-x Lesen und betreten"
    echo "  [4] rwx Vollzugriff"
    echo "  [0] Zurück"
    echo
    printf "Auswahl: " >&3
    read -r auswahl <&3

    case "$auswahl" in
        1) chmod g=--- -- "$ORDNER" ;;
        2) chmod g=--x -- "$ORDNER" ;;
        3) chmod g=r-x -- "$ORDNER" ;;
        4) chmod g=rwx -- "$ORDNER" ;;
        0) return ;;
        *)
            echo "[✗] Ungültige Auswahl"
            pause
            return
            ;;
    esac

    echo "[✓] Gruppenrechte wurden geändert"
    pause
}

sonstige_rechte_setzen() {
    local auswahl

    kopf
    echo "Rechte für alle anderen setzen"
    echo "------------------------------"
    echo "  [1] --- Kein Zugriff"
    echo "  [2] --x Nur betreten"
    echo "  [3] r-x Lesen und betreten"
    echo "  [4] rwx Vollzugriff"
    echo "  [0] Zurück"
    echo
    printf "Auswahl: " >&3
    read -r auswahl <&3

    case "$auswahl" in
        1) chmod o=--- -- "$ORDNER" ;;
        2) chmod o=--x -- "$ORDNER" ;;
        3) chmod o=r-x -- "$ORDNER" ;;
        4) chmod o=rwx -- "$ORDNER" ;;
        0) return ;;
        *)
            echo "[✗] Ungültige Auswahl"
            pause
            return
            ;;
    esac

    echo "[✓] Rechte für alle anderen wurden geändert"
    pause
}

benutzer_verwalten() {
    local gruppe
    local auswahl

    benutzer_auswaehlen || return

    if [ "$AUSGEWAEHLTER_BENUTZER" = "root" ]; then
        zugriff_pruefen root
        return
    fi

    gruppe="$(stat -c '%G' -- "$ORDNER")"

    kopf
    echo "Benutzer verwalten"
    echo "------------------"
    echo "Benutzer:        $AUSGEWAEHLTER_BENUTZER"
    echo "Besitzergruppe:  $gruppe"
    echo
    echo "  [1] Effektiven Zugriff prüfen"
    echo "  [2] Zur Besitzergruppe hinzufügen"
    echo "  [3] Aus Besitzergruppe entfernen"
    echo "  [0] Zurück"
    echo
    printf "Auswahl: " >&3
    read -r auswahl <&3

    case "$auswahl" in
        1)
            zugriff_pruefen "$AUSGEWAEHLTER_BENUTZER"
            ;;
        2)
            usermod -aG "$gruppe" "$AUSGEWAEHLTER_BENUTZER" && {
                echo "[✓] $AUSGEWAEHLTER_BENUTZER wurde zu $gruppe hinzugefügt"
                echo "[!] Eine neue Anmeldung kann erforderlich sein"
            }
            pause
            ;;
        3)
            if id -nG "$AUSGEWAEHLTER_BENUTZER" | tr ' ' '\n' |
                grep -Fxq -- "$gruppe"; then
                gpasswd -d "$AUSGEWAEHLTER_BENUTZER" "$gruppe" >/dev/null && {
                    echo "[✓] $AUSGEWAEHLTER_BENUTZER wurde aus $gruppe entfernt"
                    echo "[!] Zugriff kann weiterhin über Besitzer- oder Sonstige-Rechte bestehen"
                }
            else
                echo "[!] Benutzer ist kein Mitglied von $gruppe"
            fi
            pause
            ;;
    esac
}

gruppen_verwalten() {
    local auswahl

    while true; do
        rechte_anzeigen
        echo
        echo "Gruppenverwaltung"
        echo "-----------------"
        echo "  [1] Verwaltete Ordnergruppe erstellen/verwenden"
        echo "  [2] Vorhandene Gruppe als Besitzergruppe setzen"
        echo "  [3] Gruppenrechte setzen"
        echo "  [4] Rechte für alle anderen setzen"
        echo "  [0] Zurück"
        echo
        printf "Auswahl: " >&3
        read -r auswahl <&3

        case "$auswahl" in
            1) verwaltete_gruppe_erstellen ;;
            2) vorhandene_gruppe_auswaehlen ;;
            3) gruppenrechte_setzen ;;
            4) sonstige_rechte_setzen ;;
            0) return ;;
        esac
    done
}

while true; do
    rechte_anzeigen
    echo
    echo "Hauptmenü"
    echo "---------"
    echo "  [1] Benutzerzugriff prüfen oder verwalten"
    echo "  [2] Gruppen und Rechte verwalten"
    echo "  [3] Informationen aktualisieren"
    echo "  [0] Beenden"
    echo
    printf "Auswahl: " >&3
    read -r HAUPTAUSWAHL <&3

    case "$HAUPTAUSWAHL" in
        1) benutzer_verwalten ;;
        2) gruppen_verwalten ;;
        3) ;;
        0)
            echo "[✓] Beendet"
            exit 0
            ;;
    esac
done

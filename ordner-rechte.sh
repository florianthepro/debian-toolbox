#!/usr/bin/env bash

set -u
exec 3<>/dev/tty || { echo "Fehler: Kein Terminal verfügbar."; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Fehler: Mit sudo ausführen."; exit 1; }
ORDNER="$(pwd -P)" || exit 1
[ -d "$ORDNER" ] || { echo "Fehler: Kein gültiger Ordner."; exit 1; }
UID_MIN="$(awk '/^[[:space:]]*UID_MIN[[:space:]]+/ {print $2; exit}' /etc/login.defs 2>/dev/null)"
UID_MIN="${UID_MIN:-1000}"
ERGEBNIS=""
AUSWAHL=""

clear_screen() { printf '\033[2J\033[H'; }
taste() { local n="$1" v; IFS= read -rsn1 v <&3 || exit 0; printf -v "$n" '%s' "$v"; }
prompt() {
    local u="${SUDO_USER:-$(id -un)}" h z='$'
    h="$(hostname -s 2>/dev/null || hostname)"
    [ -z "${SUDO_USER:-}" ] && z='#'
    printf '\n%s@%s:%s%s ' "$u" "$h" "$ORDNER" "$z"
}
art() { [ -d "$1" ] && echo Ordner || { [ -f "$1" ] && echo Datei || echo Objekt; }; }
rechte_text() {
    local r="$1" typ="$2" out=""
    [ "${r:0:1}" = r ] && out="Lesen"
    [ "${r:1:1}" = w ] && out="${out:+$out, }Schreiben"
    case "${r:2:1}" in x|s|t) [ "$typ" = Ordner ] && out="${out:+$out, }Betreten" || out="${out:+$out, }Ausführen";; esac
    printf '%s' "${out:-Kein Zugriff}"
}
status() {
    local m typ owner group
    m="$(stat -c '%A' -- "$ORDNER")"; typ="$(art "$ORDNER")"
    owner="$(stat -c '%U' -- "$ORDNER")"; group="$(stat -c '%G' -- "$ORDNER")"
    echo "Aktueller Ordner"
    echo "Besitzer: $owner | $(rechte_text "${m:1:3}" "$typ")"
    echo "Gruppe:   $group | $(rechte_text "${m:4:3}" "$typ")"
    echo "Andere:   $(rechte_text "${m:7:3}" "$typ")"
}
zugriff() {
    local u="$1" p="$2" typ out=""
    typ="$(art "$p")"
    su -s /bin/sh "$u" -c 'test -r "$1"' sh "$p" 2>/dev/null && out="Lesen"
    su -s /bin/sh "$u" -c 'test -w "$1"' sh "$p" 2>/dev/null && out="${out:+$out, }Schreiben"
    if su -s /bin/sh "$u" -c 'test -x "$1"' sh "$p" 2>/dev/null; then
        [ "$typ" = Ordner ] && out="${out:+$out, }Betreten" || out="${out:+$out, }Ausführen"
    fi
    printf '%s' "${out:-Kein Zugriff}"
}
load_users() {
    USERS=("root")

    local name uid_num
    local -a normale=()
    local -a systemkonten=()

    while IFS=: read -r name _ uid_num _ _ _ _; do
        [ "$name" = "root" ] && continue
        [ "$uid_num" -eq 65534 ] && continue

        if [ "$uid_num" -ge "$UID_MIN" ]; then
            normale+=("$name|Benutzer")
        else
            systemkonten+=("$name|Systemkonto")
        fi
    done < <(getent passwd)

    if [ "${#normale[@]}" -gt 0 ]; then
        mapfile -t normale < <(printf '%s\n' "${normale[@]}" | sort -f)
        USERS+=("${normale[@]}")
    fi

    if [ "${#systemkonten[@]}" -gt 0 ]; then
        mapfile -t systemkonten < <(printf '%s\n' "${systemkonten[@]}" | sort -f)
        USERS+=("${systemkonten[@]}")
    fi
}
load_groups() {
    GROUPS=()
    local name gid
    while IFS=: read -r name _ gid _; do GROUPS+=("$name|$gid"); done < <(getent group)
}
plain_user() { printf '%s' "${1%%|*}"; }
plain_group() { printf '%s' "${1%%|*}"; }

list_select() {
    local title="$1" kind="$2" mark_for="${3:-}"; shift 3
    local -a items=("$@")
    local page=0 size=8 total="${#items[@]}" start end i nr key idx raw name mark info
    [ "$total" -gt 0 ] || return 1
    while true; do
        start=$((page*size)); end=$((start+size)); [ "$end" -gt "$total" ] && end="$total"
        clear_screen; echo "$title"; echo
        nr=1
        for ((i=start;i<end;i++)); do
            raw="${items[$i]}"
            if [ "$kind" = user ]; then name="$(plain_user "$raw")"; info="${raw#*|}"; [ "$raw" = "$info" ] && info=""
            else name="$(plain_group "$raw")"; info=""; fi
            mark=" "
            if [ -n "$mark_for" ]; then
                if [ "$kind" = group ]; then id -nG "$mark_for" 2>/dev/null | tr ' ' '\n' | grep -Fxq -- "$name" && mark="x"
                else id -nG "$name" 2>/dev/null | tr ' ' '\n' | grep -Fxq -- "$mark_for" && mark="x"
                fi
            fi
            if [ -n "$mark_for" ]; then printf '[%d] [%s] %-20s %s\n' "$nr" "$mark" "$name" "$info"
            else printf '[%d] %-24s %s\n' "$nr" "$name" "$info"; fi
            nr=$((nr+1))
        done
        echo; printf '%d-%d/%d\n' "$((start+1))" "$end" "$total"; echo
        [ "$page" -gt 0 ] && echo "[V] Vorherige Seite"
        [ "$end" -lt "$total" ] && echo "[N] Nächste Seite"
        echo "[Z] Zurück"
        [ -n "$mark_for" ] && echo "[x] Mitglied"
        prompt; taste key
        case "${key,,}" in
            [1-8]) idx=$((start+key-1)); [ "$idx" -lt "$end" ] && AUSWAHL="${items[$idx]}" && return 0;;
            n) [ "$end" -lt "$total" ] && page=$((page+1));;
            v) [ "$page" -gt 0 ] && page=$((page-1));;
            z) return 1;;
        esac
    done
}

user_panel() {
    local raw u g key member primary
    load_users
    list_select "Benutzer auswählen" user "" "${USERS[@]}" || return
    raw="$AUSWAHL"; u="$(plain_user "$raw")"
    while true; do
        load_groups
        clear_screen
        echo "Benutzer: $u"
        echo "Zugriff:  $(zugriff "$u" "$ORDNER")"
        echo
        echo "Gruppe wählen: Mitgliedschaft hinzufügen oder entfernen"
        echo "[B] Rechtebaum  [Z] Zurück"
        echo
        list_select_inline_group "$u" || return
        g="$(plain_group "$AUSWAHL")"
        [ "$u" = root ] && { ERGEBNIS="root wird nicht geändert."; return; }
        primary="$(id -gn "$u")"
        if id -nG "$u" | tr ' ' '\n' | grep -Fxq -- "$g"; then
            if [ "$primary" = "$g" ]; then ERGEBNIS="$g ist die Hauptgruppe von $u."
            elif gpasswd -d "$u" "$g" >/dev/null 2>&1; then ERGEBNIS="$u wurde aus $g entfernt."
            else ERGEBNIS="Änderung fehlgeschlagen."
            fi
        else
            usermod -aG "$g" "$u" && ERGEBNIS="$u wurde zu $g hinzugefügt." || ERGEBNIS="Änderung fehlgeschlagen."
        fi
        return
    done
}
list_select_inline_group() {
    local u="$1" page=0 size=8 total="${#GROUPS[@]}" start end i nr key idx raw name mark current
    current="$(stat -c '%G' -- "$ORDNER")"
    while true; do
        start=$((page*size)); end=$((start+size)); [ "$end" -gt "$total" ] && end="$total"
        clear_screen
        echo "Benutzer: $u"
        echo "Zugriff:  $(zugriff "$u" "$ORDNER")"
        echo
        echo "Gruppenmitgliedschaften"
        echo
        nr=1
        for ((i=start;i<end;i++)); do
            raw="${GROUPS[$i]}"; name="$(plain_group "$raw")"; mark=" "
            id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -Fxq -- "$name" && mark="x"
            [ "$name" = "$current" ] && printf '[%d] [%s] %-20s Ordnergruppe\n' "$nr" "$mark" "$name" || printf '[%d] [%s] %s\n' "$nr" "$mark" "$name"
            nr=$((nr+1))
        done
        echo; printf '%d-%d/%d\n' "$((start+1))" "$end" "$total"; echo
        [ "$page" -gt 0 ] && echo "[V] Vorherige Seite"
        [ "$end" -lt "$total" ] && echo "[N] Nächste Seite"
        echo "[B] Rechtebaum"
        echo "[Z] Zurück"
        echo "[x] Mitglied"
        prompt; taste key
        case "${key,,}" in
            [1-8]) idx=$((start+key-1)); [ "$idx" -lt "$end" ] && AUSWAHL="${GROUPS[$idx]}" && return 0;;
            n) [ "$end" -lt "$total" ] && page=$((page+1));;
            v) [ "$page" -gt 0 ] && page=$((page-1));;
            b) tree "$u"; return 1;;
            z) return 1;;
        esac
    done
}

group_panel() {
    local raw g u key current primary
    load_groups
    list_select "Gruppe auswählen" group "" "${GROUPS[@]}" || return
    raw="$AUSWAHL"; g="$(plain_group "$raw")"
    load_users
    while true; do
        clear_screen
        echo "Gruppe: $g"
        echo
        echo "Benutzer wählen: Mitgliedschaft hinzufügen oder entfernen"
        echo "[S] Als Ordnergruppe setzen  [Z] Zurück"
        echo
        list_select_inline_user "$g" || return
        u="$(plain_user "$AUSWAHL")"
        [ "$u" = root ] && { ERGEBNIS="root wird nicht geändert."; return; }
        primary="$(id -gn "$u")"
        if id -nG "$u" | tr ' ' '\n' | grep -Fxq -- "$g"; then
            if [ "$primary" = "$g" ]; then ERGEBNIS="$g ist die Hauptgruppe von $u."
            elif gpasswd -d "$u" "$g" >/dev/null 2>&1; then ERGEBNIS="$u wurde aus $g entfernt."
            else ERGEBNIS="Änderung fehlgeschlagen."
            fi
        else
            usermod -aG "$g" "$u" && ERGEBNIS="$u wurde zu $g hinzugefügt." || ERGEBNIS="Änderung fehlgeschlagen."
        fi
        return
    done
}
list_select_inline_user() {
    local g="$1" page=0 size=8 total="${#USERS[@]}" start end i nr key idx raw name mark info
    while true; do
        start=$((page*size)); end=$((start+size)); [ "$end" -gt "$total" ] && end="$total"
        clear_screen; echo "Gruppe: $g"; echo; echo "Mitglieder"; echo
        nr=1
        for ((i=start;i<end;i++)); do
            raw="${USERS[$i]}"; name="$(plain_user "$raw")"; info="${raw#*|}"; [ "$raw" = "$info" ] && info=""; mark=" "
            id -nG "$name" 2>/dev/null | tr ' ' '\n' | grep -Fxq -- "$g" && mark="x"
            printf '[%d] [%s] %-20s %s\n' "$nr" "$mark" "$name" "$info"; nr=$((nr+1))
        done
        echo; printf '%d-%d/%d\n' "$((start+1))" "$end" "$total"; echo
        [ "$page" -gt 0 ] && echo "[V] Vorherige Seite"
        [ "$end" -lt "$total" ] && echo "[N] Nächste Seite"
        echo "[S] Als Ordnergruppe setzen"
        echo "[Z] Zurück"
        echo "[x] Mitglied"
        prompt; taste key
        case "${key,,}" in
            [1-8]) idx=$((start+key-1)); [ "$idx" -lt "$end" ] && AUSWAHL="${USERS[$idx]}" && return 0;;
            n) [ "$end" -lt "$total" ] && page=$((page+1));;
            v) [ "$page" -gt 0 ] && page=$((page-1));;
            s) chgrp -- "$g" "$ORDNER" && ERGEBNIS="$g ist jetzt die Ordnergruppe." || ERGEBNIS="Änderung fehlgeschlagen."; return 1;;
            z) return 1;;
        esac
    done
}

permissions() {
    local target="$1" title="$2" key mode
    clear_screen; echo "$title"; echo
    echo "[1] Kein Zugriff"
    echo "[2] Betreten"
    echo "[3] Lesen und Betreten"
    echo "[4] Schreiben und Betreten"
    echo "[5] Lesen, Schreiben und Betreten"
    echo "[Z] Zurück"
    echo; status; prompt; taste key
    case "${key,,}" in 1) mode='---';;2) mode='--x';;3) mode='r-x';;4) mode='-wx';;5) mode='rwx';;z) return;;*) return;;esac
    chmod "$target=$mode" -- "$ORDNER" && ERGEBNIS="$title geändert." || ERGEBNIS="Änderung fehlgeschlagen."
}
tree() {
    local u="${1:-}" p count=0 m typ owner group key
    clear_screen; [ -n "$u" ] && echo "Rechtebaum für $u" || echo "Gesamter Rechtebaum"; echo
    while IFS= read -r -d '' p; do
        if [ -n "$u" ]; then echo "$p"; echo "  Zugriff: $(zugriff "$u" "$p")"
        else
            m="$(stat -c '%A' -- "$p" 2>/dev/null)" || continue; typ="$(art "$p")"; owner="$(stat -c '%U' -- "$p")"; group="$(stat -c '%G' -- "$p")"
            echo "$p"; echo "  Besitzer: $owner | $(rechte_text "${m:1:3}" "$typ")"; echo "  Gruppe:   $group | $(rechte_text "${m:4:3}" "$typ")"; echo "  Andere:   $(rechte_text "${m:7:3}" "$typ")"
        fi
        echo; count=$((count+1)); [ "$count" -ge 300 ] && { echo "Ausgabe nach 300 Einträgen beendet."; break; }
    done < <(find "$ORDNER" -maxdepth 3 -print0 2>/dev/null)
    echo "[Z] Zurück"; prompt; while true; do taste key; [ "${key,,}" = z ] && return; done
}
main_view() {
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
    [ -n "$ERGEBNIS" ] && { echo; echo "Ergebnis: $ERGEBNIS"; }
    echo; status; prompt
}
while true; do
    main_view; taste KEY
    case "${KEY,,}" in
        1) user_panel;;
        2) group_panel;;
        3) permissions g "Gruppenrechte";;
        4) permissions o "Rechte für Andere";;
        5) tree;;
        6) load_users; list_select "Benutzer auswählen" user "" "${USERS[@]}" && tree "$(plain_user "$AUSWAHL")";;
        q) clear_screen; exit 0;;
    esac
done

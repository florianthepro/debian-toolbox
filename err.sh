#!/usr/bin/env bash

set -u
exec 3<>/dev/tty || { echo "Fehler: Kein Terminal verfügbar."; exit 1; }

TMP="$(mktemp -d /tmp/fehlerfinder.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

clear_screen() { printf '\033[2J\033[H'; }
taste() { local n="$1" v; IFS= read -rsn1 v <&3 || exit 0; printf -v "$n" '%s' "$v"; }
text() { local n="$1" q="$2" v; printf '%s' "$q" >&3; IFS= read -r v <&3; printf -v "$n" '%s' "$v"; }
pause() { local k; echo; echo "Taste drücken ..."; taste k; }
prompt() { printf '\n%s@%s:~$ ' "${SUDO_USER:-${USER:-$(id -un)}}" "$(hostname -s 2>/dev/null || hostname)"; }
kopf() { clear_screen; echo "Fehlerfinder"; echo; }

add() { printf '%s\n' "$2" >> "$TMP/$1"; }
count() { [ -s "$TMP/$1" ] && awk 'END {print NR}' "$TMP/$1" || echo 0; }
clean() { [ -s "$TMP/$1" ] || return; awk 'NF && !seen[$0]++' "$TMP/$1" > "$TMP/$1.new"; mv "$TMP/$1.new" "$TMP/$1"; }

scan() {
    local f p available time_sync
    for f in dienste speicher netzwerk pakete kernel system; do : > "$TMP/$f"; done

    while read -r unit rest; do
        [ -n "${unit:-}" ] && add dienste "${unit%.service}|Dienst fehlgeschlagen"
    done < <(systemctl --failed --type=service --no-legend 2>/dev/null)

    while read -r fs blocks used avail percent mount; do
        [ "$fs" = Filesystem ] && continue
        p="${percent%%%}"; [[ "$p" =~ ^[0-9]+$ ]] || continue
        [ "$p" -ge 95 ] && add speicher "$mount|Datenträger kritisch voll: $p %"
        [ "$p" -ge 85 ] && [ "$p" -lt 95 ] && add speicher "$mount|Datenträger fast voll: $p %"
    done < <(df -P 2>/dev/null)

    while read -r fs total used free percent mount; do
        [ "$fs" = Filesystem ] && continue
        p="${percent%%%}"; [[ "$p" =~ ^[0-9]+$ ]] || continue
        [ "$p" -ge 90 ] && add speicher "$mount|Dateieinträge fast voll: $p %"
    done < <(df -Pi 2>/dev/null)

    available="$(free 2>/dev/null | awk '/Mem:/ {if ($2>0) printf "%.0f", $7*100/$2; else print 100}')"
    [ "$available" -lt 10 ] && add speicher "Arbeitsspeicher|Nur $available % verfügbar"

    journalctl -b --no-pager -o cat 2>/dev/null | grep -Ei 'out of memory|oom-kill|killed process' | tail -n 8 |
        while IFS= read -r line; do add speicher "Speicherabbruch|$line"; done

    ip route 2>/dev/null | grep -q '^default ' || add netzwerk "Route|Keine Standardroute"
    getent ahosts deb.debian.org >/dev/null 2>&1 || add netzwerk "DNS|Namensauflösung fehlgeschlagen"
    timeout 3 bash -c '</dev/tcp/1.1.1.1/53' 2>/dev/null || add netzwerk "Internet|Externe Verbindung nicht bestätigt"

    dpkg --audit 2>/dev/null | sed '/^[[:space:]]*$/d' | head -n 12 |
        while IFS= read -r line; do add pakete "dpkg|$line"; done
    apt-get check >/dev/null 2>"$TMP/apt" || grep -E '^E:|^W:' "$TMP/apt" | head -n 12 |
        while IFS= read -r line; do add pakete "apt|$line"; done

    journalctl -k -b -p err --no-pager -o cat 2>/dev/null | grep -Ev '^$|audit:|apparmor=' | tail -n 20 |
        while IFS= read -r line; do add kernel "Kernel|$line"; done

    journalctl -b -p err --no-pager -o cat 2>/dev/null | grep -Ev '^$|Failed to start|Dependency failed|audit:|apparmor=' | tail -n 20 |
        while IFS= read -r line; do add system "System|$line"; done

    time_sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    [ "$time_sync" = no ] && add system "Systemzeit|Nicht synchronisiert"

    for f in dienste speicher netzwerk pakete kernel system; do clean "$f"; done
}

detail() {
    local category="$1" entry="$2" name="${entry%%|*}" message="${entry#*|}"
    kopf
    echo "$name"
    echo
    echo "$message"
    if [ "$category" = dienste ]; then
        echo
        echo "Status"
        systemctl status --no-pager --full "$name" 2>&1 | sed -n '1,14p'
        echo
        echo "Letzte Meldungen"
        journalctl -u "$name" -b --no-pager -o cat 2>/dev/null | tail -n 8
    fi
    pause
}

external() {
    local target port k resolved pingok
    kopf
    echo "Extern suchen"
    echo
    text target "Hostname oder IP: "
    [ -z "$target" ] && return

    while true; do
        resolved="$(getent ahosts "$target" 2>/dev/null | awk 'NR==1 {print $1}')"
        ping -c 1 -W 2 "$target" >/dev/null 2>&1 && pingok=Ja || pingok=Nein
        kopf
        echo "Extern: $target"
        echo
        echo "Aufgelöst: ${resolved:-Nein}"
        echo "Erreichbar: $pingok"
        echo
        echo "[1] Erreichbarkeit erneut prüfen"
        echo "[2] Route zum Ziel"
        echo "[3] Port prüfen"
        echo "[4] Webports 80 und 443 prüfen"
        echo "[5] SSH-Port 22 prüfen"
        echo "[6] DNS-Details"
        echo "[Z] Zurück"
        prompt; taste k
        case "${k,,}" in
            1) kopf; ping -c 4 -W 3 -- "$target" 2>&1; pause ;;
            2) kopf; if command -v tracepath >/dev/null 2>&1; then tracepath "$target"; else ip route get "$target"; fi; pause ;;
            3) text port "Port: "; if [[ "$port" =~ ^[0-9]+$ ]] && timeout 4 bash -c "</dev/tcp/$target/$port" 2>/dev/null; then echo "Port $port ist erreichbar."; else echo "Port $port ist nicht erreichbar."; fi; pause ;;
            4) kopf; for port in 80 443; do if timeout 4 bash -c "</dev/tcp/$target/$port" 2>/dev/null; then echo "Port $port: erreichbar"; else echo "Port $port: nicht erreichbar"; fi; done; pause ;;
            5) kopf; if timeout 4 bash -c "</dev/tcp/$target/22" 2>/dev/null; then echo "SSH-Port 22: erreichbar"; else echo "SSH-Port 22: nicht erreichbar"; fi; pause ;;
            6) kopf; getent ahosts "$target" 2>&1; pause ;;
            z) return ;;
        esac
    done
}

report() {
    local target="/tmp/fehlerfinder-$(date +%Y%m%d-%H%M%S).txt" category title
    {
        echo "Fehlerfinder-Bericht"
        echo "Zeit: $(date -Is)"
        echo "Rechner: $(hostname)"
        echo
        for category in dienste speicher netzwerk pakete kernel system; do
            case "$category" in
                dienste) title="Dienste";; speicher) title="Speicher/Leistung";; netzwerk) title="Netzwerk";;
                pakete) title="Pakete";; kernel) title="Kernel/Hardware";; system) title="System";;
            esac
            echo "=== $title ($(count "$category")) ==="
            cat "$TMP/$category"
            echo
        done
    } > "$target"
    kopf; echo "Bericht gespeichert:"; echo "$target"; pause
}

browser() {
    local categories=(dienste speicher netzwerk pakete kernel system extern)
    local titles=("Dienste" "Speicher/Leistung" "Netzwerk" "Pakete" "Kernel/Hardware" "System" "Extern suchen")
    local pos=0 category title total item_index key
    local -a entries=()

    while true; do
        category="${categories[$pos]}"; title="${titles[$pos]}"
        if [ "$category" = extern ]; then
            total=1; entries=("Externe Hardware untersuchen")
        else
            mapfile -t entries < "$TMP/$category"
            total="${#entries[@]}"
        fi
        item_index=0

        while true; do
            kopf
            printf '%s  %d/%d\n' "$title" "$((pos + 1))" "${#categories[@]}"
            echo
            if [ "$category" = extern ]; then
                echo "Externe Hardware über diese Maschine prüfen"
                echo
                echo "[E] Öffnen"
            elif [ "$total" -eq 0 ]; then
                echo "Keine Fehler gefunden."
            else
                printf 'Fehler %d/%d\n\n' "$((item_index + 1))" "$total"
                echo "${entries[$item_index]%%|*}"
                echo "${entries[$item_index]#*|}"
                echo
                echo "[E] Details"
                [ "$total" -gt 1 ] && echo "[W] Vorheriger Fehler  [S] Nächster Fehler"
            fi
            echo
            echo "[A] Vorheriger Bereich  [D] Nächster Bereich"
            echo "[R] Erneut prüfen       [B] Bericht"
            echo "[Q] Beenden"
            prompt; taste key
            case "${key,,}" in
                a) pos=$(( (pos + ${#categories[@]} - 1) % ${#categories[@]} )); break ;;
                d) pos=$(( (pos + 1) % ${#categories[@]} )); break ;;
                w) [ "$total" -gt 1 ] && item_index=$(( (item_index + total - 1) % total )) ;;
                s) [ "$total" -gt 1 ] && item_index=$(( (item_index + 1) % total )) ;;
                e)
                    if [ "$category" = extern ]; then external
                    elif [ "$total" -gt 0 ]; then detail "$category" "${entries[$item_index]}"
                    fi
                    ;;
                r) scan; break ;;
                b) report ;;
                q) clear_screen; exit 0 ;;
            esac
        done
    done
}

kopf
echo "System wird automatisch geprüft ..."
scan
browser

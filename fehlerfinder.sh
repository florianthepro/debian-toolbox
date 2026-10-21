#!/usr/bin/env bash

set -u
exec 3<>/dev/tty || { echo "Fehler: Kein Terminal verfügbar."; exit 1; }

TMP="$(mktemp -d /tmp/fehlerfinder.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

ZIEL="localhost"
SEITENGROESSE=8
KATEGORIEN=()
TITEL=()
PRUEFUNGEN=()

bild() { printf '\033[2J\033[H'; }
taste() { local name="$1" wert=""; IFS= read -rsn1 wert <&3 || exit 0; printf -v "$name" '%s' "$wert"; }
text() { local name="$1" frage="$2" wert=""; printf '%s' "$frage" >&3; IFS= read -r wert <&3; printf -v "$name" '%s' "$wert"; }
pause() { local key=""; echo; echo "Taste drücken ..."; taste key; }
kopf() { local pfad="${1:-}"; bild; printf 'Fehlerfinder [%s]' "$ZIEL"; [ -n "$pfad" ] && printf '/%s' "$pfad"; printf '\n\n'; }
add() { printf '%s\n' "$2" >> "$TMP/$1"; }
anzahl() { [ -s "$TMP/$1" ] && awk 'END {print NR}' "$TMP/$1" || echo 0; }
saeubern() { [ -s "$TMP/$1" ] || return 0; awk 'NF && !seen[$0]++' "$TMP/$1" > "$TMP/$1.new"; mv "$TMP/$1.new" "$TMP/$1"; }
port_offen() { timeout 3 bash -c "</dev/tcp/$1/$2" >/dev/null 2>&1; }

ziel_waehlen() {
    local eingabe=""
    while true; do
        bild
        echo "Fehlerfinder"
        echo
        printf 'IP/FQDN [localhost]: ' >&3
        IFS= read -r eingabe <&3
        eingabe="${eingabe:-localhost}"
        if [ "${eingabe,,}" = q ]; then
            bild
            exit 0
        fi
        if [[ "$eingabe" =~ ^[A-Za-z0-9._:-]+$ ]]; then
            ZIEL="$eingabe"
            return
        fi
    done
}

lokale_kategorien() {
    KATEGORIEN=(dienste speicher netzwerk pakete kernel system prozesse dateisystem)
    TITEL=("Dienste" "Speicher und Leistung" "Netzwerk" "Pakete" "Kernel und Hardware" "System" "Prozesse" "Dateisysteme")
    PRUEFUNGEN=(0 5 5 2 3 4 0 3)
}

externe_kategorien() {
    KATEGORIEN=(erreichbarkeit namensaufloesung route ports web ssh tls antwortzeit)
    TITEL=("Erreichbarkeit" "Namensauflösung" "Route" "Standardports" "Webdienste" "SSH" "TLS" "Antwortzeit")
    PRUEFUNGEN=(2 2 1 8 4 1 1 1)
}

lokal_scannen() {
    local kategorie p frei sync laufend gesamt
    lokale_kategorien
    for kategorie in "${KATEGORIEN[@]}"; do : > "$TMP/$kategorie"; done

    gesamt="$(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk 'NF {n++} END {print n+0}')"
    PRUEFUNGEN[0]="$gesamt"
    while read -r unit rest; do
        [ -n "${unit:-}" ] && add dienste "${unit%.service}|Dienst ist fehlgeschlagen"
    done < <(systemctl --failed --type=service --no-legend 2>/dev/null)

    while read -r fs blocks used avail percent mount; do
        [ "$fs" = Filesystem ] && continue
        p="${percent%%%}"; [[ "$p" =~ ^[0-9]+$ ]] || continue
        [ "$p" -ge 95 ] && add speicher "$mount|Datenträger ist kritisch voll: $p %"
        [ "$p" -ge 85 ] && [ "$p" -lt 95 ] && add speicher "$mount|Datenträger ist fast voll: $p %"
    done < <(df -P 2>/dev/null)
    frei="$(free 2>/dev/null | awk '/Mem:/ {if ($2>0) printf "%.0f", $7*100/$2; else print 100}')"
    [ "$frei" -lt 10 ] && add speicher "Arbeitsspeicher|Nur $frei % verfügbar"
    journalctl -b --no-pager -o cat 2>/dev/null | grep -Ei 'out of memory|oom-kill|killed process' | tail -n 8 |
        while IFS= read -r line; do add speicher "Speicherabbruch|$line"; done

    ip route 2>/dev/null | grep -q '^default ' || add netzwerk "Route|Keine Standardroute vorhanden"
    getent ahosts deb.debian.org >/dev/null 2>&1 || add netzwerk "DNS|Namensauflösung fehlgeschlagen"
    timeout 3 bash -c '</dev/tcp/1.1.1.1/53' 2>/dev/null || add netzwerk "Internet|Externe Verbindung nicht erreichbar"
    ip -brief link 2>/dev/null | awk '$2=="DOWN" && $1!="lo" {print $1}' |
        while IFS= read -r iface; do add netzwerk "$iface|Schnittstelle ist ausgeschaltet"; done

    dpkg --audit 2>/dev/null | sed '/^[[:space:]]*$/d' | head -n 12 |
        while IFS= read -r line; do add pakete "dpkg|$line"; done
    apt-get check >/dev/null 2>"$TMP/apt" || grep -E '^E:|^W:' "$TMP/apt" | head -n 12 |
        while IFS= read -r line; do add pakete "apt|$line"; done

    journalctl -k -b -p err --no-pager -o cat 2>/dev/null | grep -Ev '^$|audit:|apparmor=' | tail -n 20 |
        while IFS= read -r line; do add kernel "Kernel|$line"; done
    journalctl -k -b --no-pager -o cat 2>/dev/null | grep -Ei 'I/O error|hardware error|critical medium error|nvme.*error|ata.*error' | tail -n 10 |
        while IFS= read -r line; do add kernel "Hardware|$line"; done

    journalctl -b -p err --no-pager -o cat 2>/dev/null | grep -Ev '^$|Failed to start|Dependency failed|audit:|apparmor=' | tail -n 20 |
        while IFS= read -r line; do add system "System|$line"; done
    sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    [ "$sync" = no ] && add system "Systemzeit|Zeit ist nicht synchronisiert"
    systemctl is-system-running --quiet 2>/dev/null || add system "Systemzustand|System meldet einen eingeschränkten Zustand"

    gesamt="$(ps -e --no-headers 2>/dev/null | wc -l)"
    PRUEFUNGEN[6]="$gesamt"
    laufend="$(ps -eo stat= 2>/dev/null | awk '$1 ~ /^Z/ {n++} END {print n+0}')"
    [ "$laufend" -gt 0 ] && add prozesse "Zombie-Prozesse|$laufend nicht aufgeräumte Prozesse"
    ps -eo pid=,comm=,%cpu=,%mem= --sort=-%cpu 2>/dev/null | awk '$3>=90 {print $1" "$2" "$3}' | head -n 8 |
        while read -r pid name cpu; do add prozesse "$name|Prozess $pid nutzt $cpu % CPU"; done

    while read -r fs total used free percent mount; do
        [ "$fs" = Filesystem ] && continue
        p="${percent%%%}"; [[ "$p" =~ ^[0-9]+$ ]] || continue
        [ "$p" -ge 90 ] && add dateisystem "$mount|Dateieinträge sind fast voll: $p %"
    done < <(df -Pi 2>/dev/null)
    mount 2>/dev/null | grep -E ' on / .*\(.*ro[,)]' | head -n 8 |
        while IFS= read -r line; do add dateisystem "Nur-Lesen|$line"; done
    journalctl -k -b --no-pager -o cat 2>/dev/null | grep -Ei 'filesystem.*error|remount.*read-only' | tail -n 8 |
        while IFS= read -r line; do add dateisystem "Dateisystem|$line"; done

    for kategorie in "${KATEGORIEN[@]}"; do saeubern "$kategorie"; done
}

extern_scannen() {
    local kategorie ip zeit port code
    externe_kategorien
    for kategorie in "${KATEGORIEN[@]}"; do : > "$TMP/$kategorie"; done

    ping -c 1 -W 2 "$ZIEL" >/dev/null 2>&1 || add erreichbarkeit "$ZIEL|Antwortet nicht auf Ping"
    port_offen "$ZIEL" 443 || port_offen "$ZIEL" 80 || port_offen "$ZIEL" 22 || add erreichbarkeit "$ZIEL|Kein geprüfter Standarddienst erreichbar"

    ip="$(getent ahosts "$ZIEL" 2>/dev/null | awk 'NR==1 {print $1}')"
    [ -z "$ip" ] && add namensaufloesung "$ZIEL|Name kann nicht aufgelöst werden"
    if [[ "$ZIEL" =~ ^[0-9a-fA-F:.]+$ ]]; then
        getent hosts "$ZIEL" >/dev/null 2>&1 || add namensaufloesung "$ZIEL|Kein Rückwärtsname gefunden"
    fi

    ip route get "$ZIEL" >/dev/null 2>&1 || add route "$ZIEL|Keine Route zum Ziel gefunden"

    for port in 22 25 53 80 110 143 443 3389; do
        port_offen "$ZIEL" "$port" || add ports "Port $port|Nicht erreichbar"
    done

    if command -v curl >/dev/null 2>&1; then
        code="$(curl -kLsS -o /dev/null --connect-timeout 4 --max-time 8 -w '%{http_code}' "http://$ZIEL" 2>/dev/null || true)"
        [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] || add web "HTTP|Keine gültige Antwort auf Port 80"
        code="$(curl -kLsS -o /dev/null --connect-timeout 4 --max-time 8 -w '%{http_code}' "https://$ZIEL" 2>/dev/null || true)"
        [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] || add web "HTTPS|Keine gültige Antwort auf Port 443"
    else
        port_offen "$ZIEL" 80 || add web "HTTP|Port 80 nicht erreichbar"
        port_offen "$ZIEL" 443 || add web "HTTPS|Port 443 nicht erreichbar"
    fi

    port_offen "$ZIEL" 22 || add ssh "SSH|Port 22 nicht erreichbar"

    if command -v openssl >/dev/null 2>&1 && port_offen "$ZIEL" 443; then
        timeout 6 openssl s_client -connect "$ZIEL:443" -servername "$ZIEL" </dev/null 2>/dev/null |
            openssl x509 -checkend 0 -noout >/dev/null 2>&1 || add tls "TLS-Zertifikat|Ungültig, abgelaufen oder nicht lesbar"
    elif ! port_offen "$ZIEL" 443; then
        add tls "TLS|Port 443 nicht erreichbar"
    fi

    zeit="$(ping -c 2 -W 2 "$ZIEL" 2>/dev/null | awk -F'/' '/^rtt|^round-trip/ {print $5}')"
    if [ -n "$zeit" ] && awk -v t="$zeit" 'BEGIN {exit !(t>200)}'; then
        add antwortzeit "$ZIEL|Hohe mittlere Antwortzeit: $zeit ms"
    elif [ -z "$zeit" ]; then
        add antwortzeit "$ZIEL|Antwortzeit konnte nicht gemessen werden"
    fi

    for kategorie in "${KATEGORIEN[@]}"; do saeubern "$kategorie"; done
}

scan() {
    kopf
    echo "Ziel wird vollständig geprüft ..."
    if [ "$ZIEL" = localhost ] || [ "$ZIEL" = 127.0.0.1 ] || [ "$ZIEL" = ::1 ]; then
        lokal_scannen
    else
        extern_scannen
    fi
}

detail() {
    local kategorie="$1" eintrag="${2:-}" name meldung
    [ -n "$eintrag" ] || return
    name="${eintrag%%|*}"
    meldung="${eintrag#*|}"
    kopf "${3:-Details}/$name"
    echo "$meldung"
    if [ "$kategorie" = dienste ]; then
        echo
        systemctl status --no-pager --full "$name" 2>&1 | sed -n '1,14p'
        echo
        echo "Letzte Meldungen"
        journalctl -u "$name" -b --no-pager -o cat 2>/dev/null | tail -n 8
    fi
    pause
}

fehlerliste() {
    local kategorie="$1" titel="$2" seite=0 gesamt start ende i nummer key index
    local -a eintraege=()
    mapfile -t eintraege < "$TMP/$kategorie"
    gesamt="${#eintraege[@]}"
    [ "$gesamt" -gt 0 ] || return

    while true; do
        start=$((seite * SEITENGROESSE)); ende=$((start + SEITENGROESSE)); [ "$ende" -gt "$gesamt" ] && ende="$gesamt"
        kopf "$titel"
        nummer=1
        for ((i=start; i<ende; i++)); do
            printf '[%d] %s - %s\n' "$nummer" "${eintraege[$i]%%|*}" "${eintraege[$i]#*|}"
            nummer=$((nummer + 1))
        done
        echo
        printf '%d-%d/%d\n' "$((start + 1))" "$ende" "$gesamt"
        echo
        [ "$ende" -lt "$gesamt" ] && echo "[9] Nächste Seite"
        [ "$seite" -gt 0 ] && echo "[0] Vorherige Seite" || echo "[0] Zurück"
        echo "[Z] Zurück"
        echo "[Q] Quit"
        taste key
        case "${key,,}" in
            [1-8]) index=$((start + key - 1)); [ "$index" -lt "$ende" ] && detail "$kategorie" "${eintraege[$index]}" "$titel" ;;
            9) [ "$ende" -lt "$gesamt" ] && seite=$((seite + 1)) ;;
            0) if [ "$seite" -gt 0 ]; then seite=$((seite - 1)); else return; fi ;;
            z) return ;;
            q) bild; exit 0 ;;
        esac
    done
}

kategorien() {
    local seite=0 gesamt="${#KATEGORIEN[@]}" start ende i nummer key index kategorie fehler pruefungen
    while true; do
        start=$((seite * SEITENGROESSE)); ende=$((start + SEITENGROESSE)); [ "$ende" -gt "$gesamt" ] && ende="$gesamt"
        kopf
        nummer=1
        for ((i=start; i<ende; i++)); do
            kategorie="${KATEGORIEN[$i]}"
            fehler="$(anzahl "$kategorie")"
            pruefungen="${PRUEFUNGEN[$i]}"
            printf '[%d] %s/%s %s\n' "$nummer" "$fehler" "$pruefungen" "${TITEL[$i]}"
            nummer=$((nummer + 1))
        done
        echo
        printf '%d-%d/%d\n' "$((start + 1))" "$ende" "$gesamt"
        echo
        [ "$ende" -lt "$gesamt" ] && echo "[9] Nächste Seite"
        [ "$seite" -gt 0 ] && echo "[0] Vorherige Seite"
        echo "[Z] Ziel ändern"
        echo "[Q] Quit"
        taste key
        case "${key,,}" in
            [1-8])
                index=$((start + key - 1))
                if [ "$index" -lt "$ende" ]; then
                    kategorie="${KATEGORIEN[$index]}"
                    [ "$(anzahl "$kategorie")" -gt 0 ] && fehlerliste "$kategorie" "${TITEL[$index]}"
                fi
                ;;
            9) [ "$ende" -lt "$gesamt" ] && seite=$((seite + 1)) ;;
            0) [ "$seite" -gt 0 ] && seite=$((seite - 1)) ;;
            z) return ;;
            q) bild; exit 0 ;;
        esac
    done
}

while true; do
    ziel_waehlen
    scan
    kategorien
done

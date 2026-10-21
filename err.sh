#!/usr/bin/env bash
# curl -fsSL "https://raw.githubusercontent.com/florianthepro/debian-toolbox/main/fehlerfinder.sh" | bash

set -u
exec 3<>/dev/tty || { echo "Fehler: Kein Terminal verfügbar."; exit 1; }

TMP="/tmp/fehlerfinder-$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

clear_screen() { printf '\033[2J\033[H'; }
taste() { local n="$1" v; IFS= read -rsn1 v <&3 || exit 0; printf -v "$n" '%s' "$v"; }
text() { local n="$1" q="$2" v; printf '%s' "$q" >&3; IFS= read -r v <&3; printf -v "$n" '%s' "$v"; }
pause() { local k; echo; echo "Taste drücken ..."; taste k; }
prompt() { printf '\n%s@%s:~$ ' "${SUDO_USER:-${USER:-$(id -un)}}" "$(hostname -s 2>/dev/null || hostname)"; }
kopf() { clear_screen; echo "Fehlerfinder"; echo; }
hat() { command -v "$1" >/dev/null 2>&1; }

zeigen() {
    local titel="$1"; shift
    kopf; echo "$titel"; echo
    "$@" 2>&1
    pause
}

shell_zeigen() {
    local titel="$1" cmd="$2"
    kopf; echo "$titel"; echo
    bash -c "$cmd" 2>&1
    pause
}

ampel() {
    local zustand="$1" text="$2"
    case "$zustand" in
        ok) printf '[OK]      %s\n' "$text" ;;
        warn) printf '[ACHTUNG] %s\n' "$text" ;;
        fail) printf '[FEHLER]  %s\n' "$text" ;;
    esac
}

automatik() {
    local probleme=() failed disk inode mem route dns pkg kernel oom zeit
    kopf
    echo "Automatische Prüfung"
    echo

    failed="$(systemctl --failed --type=service --no-legend 2>/dev/null | awk 'NF {n++} END {print n+0}')"
    if [ "$failed" -eq 0 ]; then ampel ok "Keine fehlgeschlagenen Dienste"
    else ampel fail "$failed fehlgeschlagene Dienste"; probleme+=(dienste); fi

    disk="$(df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5+0}')"
    if [ "$disk" -ge 95 ]; then ampel fail "Systemfestplatte zu $disk % belegt"; probleme+=(speicher)
    elif [ "$disk" -ge 85 ]; then ampel warn "Systemfestplatte zu $disk % belegt"; probleme+=(speicher)
    else ampel ok "Systemfestplatte zu $disk % belegt"; fi

    inode="$(df -Pi / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5+0}')"
    if [ "$inode" -ge 90 ]; then ampel fail "Dateieinträge zu $inode % belegt"; probleme+=(speicher)
    else ampel ok "Dateieinträge zu $inode % belegt"; fi

    mem="$(free 2>/dev/null | awk '/Mem:/ {if ($2>0) printf "%.0f", $7*100/$2; else print 0}')"
    if [ "$mem" -lt 5 ]; then ampel fail "Nur $mem % Arbeitsspeicher verfügbar"; probleme+=(leistung)
    elif [ "$mem" -lt 15 ]; then ampel warn "Nur $mem % Arbeitsspeicher verfügbar"; probleme+=(leistung)
    else ampel ok "$mem % Arbeitsspeicher verfügbar"; fi

    if ip route 2>/dev/null | grep -q '^default '; then ampel ok "Standardroute vorhanden"
    else ampel fail "Keine Standardroute"; probleme+=(netzwerk); fi

    if getent ahosts deb.debian.org >/dev/null 2>&1; then ampel ok "Namensauflösung funktioniert"
    else ampel fail "Namensauflösung funktioniert nicht"; probleme+=(netzwerk); fi

    if timeout 3 bash -c '</dev/tcp/1.1.1.1/53' 2>/dev/null; then ampel ok "Internetverbindung erreichbar"
    else ampel warn "Internetverbindung nicht bestätigt"; probleme+=(netzwerk); fi

    pkg="$(dpkg --audit 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l)"
    if [ "$pkg" -eq 0 ]; then ampel ok "Paketverwaltung ohne offene Fehler"
    else ampel fail "Paketverwaltung meldet Probleme"; probleme+=(pakete); fi

    kernel="$(journalctl -k -b -p err --no-pager 2>/dev/null | grep -vc '^-- No entries --$' || true)"
    if [ "$kernel" -eq 0 ]; then ampel ok "Keine Kernel-Fehler seit dem Start"
    else ampel warn "$kernel Kernel-Fehlermeldungen seit dem Start"; probleme+=(kernel); fi

    oom="$(journalctl -b --no-pager 2>/dev/null | grep -Eic 'out of memory|oom-kill|killed process')"
    if [ "$oom" -eq 0 ]; then ampel ok "Keine Speicherabstürze erkannt"
    else ampel fail "$oom Hinweise auf Speicherabstürze"; probleme+=(leistung); fi

    zeit="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    if [ "$zeit" = yes ]; then ampel ok "Systemzeit synchronisiert"
    elif [ -n "$zeit" ]; then ampel warn "Systemzeit nicht synchronisiert"; fi

    echo
    if [ "${#probleme[@]}" -eq 0 ]; then
        echo "Kein offensichtlicher Systemfehler gefunden."
        echo "Prüfe als Nächstes [2] Letzte Fehler oder [3] Dienst suchen."
    else
        printf 'Verdächtige Bereiche: %s\n' "$(printf '%s ' "${probleme[@]}" | sed 's/ $//')"
        echo "Öffne unten direkt den passenden Bereich."
    fi
    pause
}

letzte_fehler() {
    local w
    while true; do
        kopf
        echo "Letzte Fehler"
        echo
        echo "[1] Letzte 10 Minuten"
        echo "[2] Letzte Stunde"
        echo "[3] Seit Systemstart"
        echo "[4] Nur Kernel"
        echo "[5] Nach Wort suchen"
        echo "[Z] Zurück"
        prompt; taste w
        case "${w,,}" in
            1) zeigen "Fehler der letzten 10 Minuten" journalctl --since "10 minutes ago" -p warning --no-pager -n 300 ;;
            2) zeigen "Fehler der letzten Stunde" journalctl --since "1 hour ago" -p warning --no-pager -n 300 ;;
            3) zeigen "Fehler seit Systemstart" journalctl -b -p warning --no-pager -n 500 ;;
            4) zeigen "Kernel-Fehler" journalctl -k -b -p warning --no-pager -n 300 ;;
            5) local wort; text wort "Suchwort: "; [ -n "$wort" ] && zeigen "Treffer für $wort" journalctl -b --no-pager -g "$wort" -n 300 ;;
            z) return ;;
        esac
    done
}

dienst() {
    local name w
    text name "Dienstname oder Teil: "
    [ -z "$name" ] && return
    mapfile -t treffer < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{sub(/\.service$/, "",$1); print $1}' | grep -i -- "$name" | sort -fu | head -30)
    if [ "${#treffer[@]}" -eq 0 ]; then STATUS="Kein Dienst gefunden"; return; fi
    if [ "${#treffer[@]}" -eq 1 ]; then name="${treffer[0]}"
    else
        kopf; echo "Passende Dienste"; echo
        local i=1 k
        for name in "${treffer[@]}"; do printf '[%d] %s\n' "$i" "$name"; i=$((i+1)); [ "$i" -gt 9 ] && break; done
        echo "[Z] Zurück"; prompt; taste k
        [[ "$k" =~ [1-8] ]] || return
        name="${treffer[$((k-1))]}"
    fi
    while true; do
        kopf
        echo "Dienst: $name"
        echo "Status:  $(systemctl is-active "$name" 2>/dev/null || true)"
        echo
        echo "[1] Ursache anzeigen"
        echo "[2] Letzte Meldungen"
        echo "[3] Einstellungen"
        echo "[4] Abhängigkeiten"
        echo "[5] Neu starten"
        echo "[Z] Zurück"
        prompt; taste w
        case "${w,,}" in
            1) zeigen "Status und Ursache" systemctl status --no-pager --full "$name" ;;
            2) zeigen "Dienstmeldungen" journalctl -u "$name" -b --no-pager -n 300 ;;
            3) zeigen "Diensteinstellungen" systemctl cat "$name" ;;
            4) zeigen "Abhängigkeiten" systemctl list-dependencies "$name" ;;
            5) if [ "$(id -u)" -eq 0 ]; then zeigen "Dienst neu starten" systemctl restart "$name"; else zeigen "Dienst neu starten" sudo systemctl restart "$name"; fi ;;
            z) return ;;
        esac
    done
}

netzwerk() {
    local w ziel port
    while true; do
        kopf
        echo "Netzwerkfehler"
        echo
        echo "[1] Automatisch prüfen"
        echo "[2] DNS prüfen"
        echo "[3] Host erreichen"
        echo "[4] Port erreichen"
        echo "[5] Offene Ports"
        echo "[6] Netzwerkmeldungen"
        echo "[Z] Zurück"
        prompt; taste w
        case "${w,,}" in
            1) shell_zeigen "Netzwerkprüfung" 'echo "IP-Adressen:"; ip -brief address; echo; echo "Standardroute:"; ip route | grep "^default" || echo "FEHLT"; echo; echo "DNS:"; getent ahosts deb.debian.org || echo "FEHLER"; echo; echo "Internet:"; ping -c 2 -W 2 1.1.1.1 || true' ;;
            2) text ziel "Name: "; [ -n "$ziel" ] && zeigen "DNS-Prüfung" getent ahosts "$ziel" ;;
            3) text ziel "Host oder IP: "; [ -n "$ziel" ] && zeigen "Erreichbarkeit" ping -c 4 -W 3 -- "$ziel" ;;
            4) text ziel "Host oder IP: "; text port "Port: "; [[ "$port" =~ ^[0-9]+$ ]] && zeigen "Port $ziel:$port" timeout 5 bash -c "</dev/tcp/$ziel/$port" ;;
            5) zeigen "Offene Ports" ss -tulpen ;;
            6) zeigen "Netzwerkmeldungen" journalctl -b -u NetworkManager -u systemd-networkd -u networking --no-pager -n 300 ;;
            z) return ;;
        esac
    done
}

speicher_leistung() {
    local w
    while true; do
        kopf
        echo "Speicher und Leistung"
        echo
        echo "[1] Festplatten und Inodes"
        echo "[2] Größte Ordner im System"
        echo "[3] Arbeitsspeicher"
        echo "[4] Prozesse mit hoher Last"
        echo "[5] Datenträgerfehler"
        echo "[6] Abgebrochene Prozesse"
        echo "[Z] Zurück"
        prompt; taste w
        case "${w,,}" in
            1) shell_zeigen "Festplatten und Inodes" 'df -hT; echo; df -hi' ;;
            2) shell_zeigen "Größte Ordner" 'du -xhd 2 / 2>/dev/null | sort -h | tail -50' ;;
            3) shell_zeigen "Arbeitsspeicher" 'free -h; echo; vmstat 1 5' ;;
            4) zeigen "Prozesse nach CPU" ps aux --sort=-%cpu ;;
            5) zeigen "Datenträgerfehler" journalctl -k -b --no-pager -g 'I/O error|ext4|xfs|btrfs|nvme|ata|filesystem' -n 300 ;;
            6) zeigen "Speicherbedingte Abbrüche" journalctl -b --no-pager -g 'out of memory|oom-kill|killed process' -n 300 ;;
            z) return ;;
        esac
    done
}

pfad_rechte() {
    local w pfad benutzer
    while true; do
        kopf
        echo "Pfad und Rechte"
        echo
        echo "[1] Pfad prüfen"
        echo "[2] Benutzerzugriff prüfen"
        echo "[3] Besitzer und Zeiten"
        echo "[4] Kürzlich geänderte Dateien"
        echo "[5] Defekte Verknüpfungen"
        echo "[Z] Zurück"
        prompt; taste w
        case "${w,,}" in
            1) text pfad "Pfad: "; [ -n "$pfad" ] && zeigen "Vollständiger Pfad" namei -l -- "$pfad" ;;
            2)
                text benutzer "Benutzer: "; text pfad "Pfad: "
                kopf; echo "Zugriff von $benutzer"; echo
                if [ "$(id -u)" -eq 0 ]; then
                    su -s /bin/sh "$benutzer" -c 'test -r "$1"' sh "$pfad" 2>/dev/null && echo "Lesen: Ja" || echo "Lesen: Nein"
                    su -s /bin/sh "$benutzer" -c 'test -w "$1"' sh "$pfad" 2>/dev/null && echo "Schreiben: Ja" || echo "Schreiben: Nein"
                    su -s /bin/sh "$benutzer" -c 'test -x "$1"' sh "$pfad" 2>/dev/null && echo "Betreten/Ausführen: Ja" || echo "Betreten/Ausführen: Nein"
                else
                    sudo -u "$benutzer" test -r "$pfad" && echo "Lesen: Ja" || echo "Lesen: Nein"
                    sudo -u "$benutzer" test -w "$pfad" && echo "Schreiben: Ja" || echo "Schreiben: Nein"
                    sudo -u "$benutzer" test -x "$pfad" && echo "Betreten/Ausführen: Ja" || echo "Betreten/Ausführen: Nein"
                fi
                echo; namei -l -- "$pfad"; pause
                ;;
            3) text pfad "Pfad: "; [ -n "$pfad" ] && zeigen "Dateiinformationen" stat -- "$pfad" ;;
            4) text pfad "Startpfad [/]: "; pfad="${pfad:-/}"; shell_zeigen "In letzter Stunde geändert" "find \"$pfad\" -xdev -mmin -60 -printf '%TY-%Tm-%Td %TH:%TM %p\\n' 2>/dev/null | sort -r | head -300" ;;
            5) text pfad "Startpfad [/]: "; pfad="${pfad:-/}"; shell_zeigen "Defekte Verknüpfungen" "find \"$pfad\" -xdev -xtype l -print 2>/dev/null | head -300" ;;
            z) return ;;
        esac
    done
}

pakete() {
    local w paket
    while true; do
        kopf
        echo "Paketfehler"
        echo
        echo "[1] Automatisch prüfen"
        echo "[2] Abhängigkeiten prüfen"
        echo "[3] Unfertige Installation abschließen"
        echo "[4] Letzte Paketänderungen"
        echo "[5] Einzelnes Paket prüfen"
        echo "[Z] Zurück"
        prompt; taste w
        case "${w,,}" in
            1) shell_zeigen "Paketprüfung" 'echo "Unfertige Pakete:"; dpkg --audit; echo; echo "Abhängigkeiten:"; apt-get check' ;;
            2) if [ "$(id -u)" -eq 0 ]; then zeigen "Abhängigkeiten" apt-get check; else zeigen "Abhängigkeiten" sudo apt-get check; fi ;;
            3) if [ "$(id -u)" -eq 0 ]; then zeigen "Installation abschließen" dpkg --configure -a; else zeigen "Installation abschließen" sudo dpkg --configure -a; fi ;;
            4) shell_zeigen "Letzte Paketänderungen" "grep -hE '^(Start-Date|Commandline|Install:|Upgrade:|Remove:|End-Date)' /var/log/apt/history.log 2>/dev/null | tail -120" ;;
            5) text paket "Paketname: "; [ -n "$paket" ] && shell_zeigen "Paket $paket" "dpkg -s \"$paket\" 2>&1; echo; apt-cache policy \"$paket\"" ;;
            z) return ;;
        esac
    done
}

befehl_test() {
    local cmd code
    kopf
    echo "Fehlschlagenden Befehl prüfen"
    echo
    text cmd "Befehl: "
    [ -z "$cmd" ] && return
    kopf
    echo "Ablauf und Fehlermeldung"
    echo
    echo "+ $cmd"
    echo
    (PS4='+ Zeile ${LINENO}: ' bash -x -c "$cmd") 2>&1
    code=$?
    echo
    echo "Endcode: $code"
    if [ "$code" -eq 127 ]; then echo "Bedeutung: Befehl nicht gefunden."
    elif [ "$code" -eq 126 ]; then echo "Bedeutung: Gefunden, aber nicht ausführbar."
    elif [ "$code" -eq 2 ]; then echo "Bedeutung: Häufig Syntax- oder Aufruffehler."
    elif [ "$code" -gt 128 ]; then echo "Bedeutung: Durch Signal beendet."
    fi
    pause
}

bericht() {
    local ziel="/tmp/fehlerfinder-$(date +%Y%m%d-%H%M%S).txt"
    kopf; echo "Diagnosebericht wird erstellt ..."
    {
        echo "Fehlerfinder-Bericht"
        echo "Zeit: $(date -Is)"
        echo "Rechner: $(hostname)"
        echo "Benutzer: $(id)"
        echo
        echo "=== SYSTEM ==="; uname -a; hostnamectl 2>/dev/null || true; uptime
        echo; echo "=== DIENSTE ==="; systemctl --failed --no-pager
        echo; echo "=== FEHLER ==="; journalctl -b -p warning --no-pager -n 500
        echo; echo "=== KERNEL ==="; journalctl -k -b -p warning --no-pager -n 500
        echo; echo "=== SPEICHER ==="; free -h; df -hT; df -hi
        echo; echo "=== DATENTRAEGER ==="; lsblk -o NAME,SIZE,TYPE,FSTYPE,FSAVAIL,FSUSE%,MOUNTPOINTS
        echo; echo "=== NETZWERK ==="; ip -brief address; ip route; ss -tulpen
        echo; echo "=== PROZESSE ==="; ps aux --sort=-%cpu | head -60
        echo; echo "=== PAKETE ==="; dpkg --audit; apt-get check 2>&1
    } > "$ziel" 2>&1
    echo; echo "Gespeichert unter:"; echo "$ziel"; pause
}

hilfe() {
    kopf
    echo "Schnellster Ablauf"
    echo
    echo "1. Automatische Prüfung starten."
    echo "2. Den gemeldeten Bereich öffnen."
    echo "3. Bei unbekannter Ursache 'Letzte Fehler' ansehen."
    echo "4. Bei einem konkreten Fehlerbefehl 'Befehl prüfen' verwenden."
    echo "5. Für Weitergabe einen Diagnosebericht erstellen."
    echo
    echo "Das Programm ist unabhängig vom aktuellen Ordner."
    echo "Nur die Pfadprüfung fragt gezielt nach einem Pfad."
    pause
}

STATUS="Bereit"
while true; do
    kopf
    echo "[1] Automatisch prüfen"
    echo "[2] Letzte Fehler"
    echo "[3] Dienst suchen"
    echo "[4] Netzwerk"
    echo "[5] Speicher und Leistung"
    echo "[6] Pfad und Rechte"
    echo "[7] Pakete"
    echo "[8] Befehl prüfen"
    echo "[A] Diagnosebericht"
    echo "[H] Hilfe"
    echo "[Q] Beenden"
    echo
    echo "Status: $STATUS"
    prompt
    taste WAHL
    case "${WAHL,,}" in
        1) automatik ;;
        2) letzte_fehler ;;
        3) dienst ;;
        4) netzwerk ;;
        5) speicher_leistung ;;
        6) pfad_rechte ;;
        7) pakete ;;
        8) befehl_test ;;
        a) bericht ;;
        h) hilfe ;;
        q) clear_screen; exit 0 ;;
    esac
done

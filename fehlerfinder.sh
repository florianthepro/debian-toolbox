#!/usr/bin/env bash

set -u
exec 3<>/dev/tty || { echo "Fehler: Kein Terminal verfügbar."; exit 1; }
TMP="$(mktemp -d /tmp/fehlerfinder.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

ZIEL=localhost
DNS_SERVER=""
KATEGORIEN=()
TITEL=()
PRUEFUNGEN=()

bild(){ printf '\033[2J\033[H'; }
taste(){ local n="$1" v=""; IFS= read -rsn1 v <&3 || exit 0; printf -v "$n" '%s' "$v"; }
pause(){ local k; echo; echo "Taste drücken ..."; taste k; }
kopf(){
 local weg="${1:-}"
 bild
 printf 'Fehlerfinder [%s]' "$ZIEL"
 [ -n "$weg" ] && printf '/%s' "$weg"
 printf '
'
 printf 'DNS: %s

' "${DNS_SERVER:-Systemstandard}"
}
add(){ printf '%s\n' "$2" >> "$TMP/$1"; }
anzahl(){ [ -s "$TMP/$1" ] && awk 'END{print NR}' "$TMP/$1" || echo 0; }
sauber(){ [ -s "$TMP/$1" ] || return; awk 'NF&&!a[$0]++' "$TMP/$1" > "$TMP/x"; mv "$TMP/x" "$TMP/$1"; }
port(){ timeout 3 bash -c "</dev/tcp/$1/$2" >/dev/null 2>&1; }

hilfe(){
 bild
 echo "Fehlerfinder/Ziel und DNS/Hilfe"
 echo
 echo "Ziel:       IP-Adresse, FQDN oder localhost"
 echo "DNS-Server: leer verwendet die normale Systemauflösung"
 echo
 echo "Beispiele:"
 echo "Ziel:       server.intern"
 echo "DNS-Server: 192.168.1.10"
 echo
 echo "Bei einer IP-Adresse ist kein DNS-Server notwendig."
 pause
}

einstellungen(){
 local key wert
 while true; do
  bild
  echo "Fehlerfinder/Ziel und DNS"
  echo
  echo "[1] Ziel        ${ZIEL:-localhost}"
  echo "[2] DNS-Server  ${DNS_SERVER:-Systemstandard}"
  echo
  echo "[3] Änderungen anwenden"
  echo "[4] Auf localhost zurücksetzen"
  echo "[?] Hilfe"
  echo "[Z] Zurück"
  echo "[Q] Quit"
  taste key
  case "${key,,}" in
   1)
    printf '\nZiel [localhost]: ' >&3
    IFS= read -r wert <&3
    wert="${wert:-localhost}"
    [[ "$wert" =~ ^[A-Za-z0-9._:-]+$ ]] && ZIEL="$wert"
    ;;
   2)
    printf '\nDNS-Server [Systemstandard]: ' >&3
    IFS= read -r wert <&3
    if [ -z "$wert" ]; then DNS_SERVER=""
    elif [[ "$wert" =~ ^[A-Za-z0-9._:-]+$ ]]; then DNS_SERVER="$wert"
    fi
    ;;
   3)
    scan
    return
    ;;
   4)
    ZIEL="localhost"
    DNS_SERVER=""
    scan
    return
    ;;
   \?) hilfe ;;
   z) return ;;
   q) bild; exit 0 ;;
  esac
 done
}

aufloesen(){
 local z="$1" d="${2:-}" ip=""
 [[ "$z" =~ ^[0-9]+([.][0-9]+){3}$ ]] && { printf '%s' "$z"; return; }
 if [ -n "$d" ]; then
  if command -v dig >/dev/null; then ip="$(dig +short +time=2 +tries=1 "@$d" "$z" | awk 'NR==1')"
  elif command -v nslookup >/dev/null; then ip="$(nslookup "$z" "$d" 2>/dev/null | awk '/^Address: /{x=$2} END{print x}')"
  else return 2; fi
 else ip="$(getent ahostsv4 "$z" 2>/dev/null | awk 'NR==1{print $1}')"; fi
 [ -n "$ip" ] || return 1; printf '%s' "$ip"
}

lokal(){
 KATEGORIEN=(dienste speicher netzwerk pakete kernel system prozesse dateisystem)
 TITEL=("Dienste" "Speicher und Leistung" "Netzwerk" "Pakete" "Kernel und Hardware" "System" "Prozesse" "Dateisysteme")
 PRUEFUNGEN=(0 4 4 2 2 3 0 2)
 local k p frei n
 for k in "${KATEGORIEN[@]}"; do :>"$TMP/$k"; done
 PRUEFUNGEN[0]="$(systemctl list-unit-files --type=service --no-legend 2>/dev/null|awk 'NF{n++}END{print n+0}')"
 while read -r u _; do [ -n "${u:-}" ]&&add dienste "${u%.service}|Dienst ist fehlgeschlagen"; done < <(systemctl --failed --type=service --no-legend 2>/dev/null)
 while read -r f _ _ _ q m; do [ "$f" = Filesystem ]&&continue; p="${q%%%}"; [[ "$p" =~ ^[0-9]+$ ]]||continue; [ "$p" -ge 85 ]&&add speicher "$m|Datenträger zu $p % belegt"; done < <(df -P)
 frei="$(free|awk '/Mem:/{printf "%.0f",$7*100/$2}')"; [ "$frei" -lt 10 ]&&add speicher "Arbeitsspeicher|Nur $frei % verfügbar"
 journalctl -b -o cat --no-pager 2>/dev/null|grep -Ei 'out of memory|oom-kill|killed process'|tail -5|while IFS= read -r l; do add speicher "Speicherabbruch|$l"; done
 ip route|grep -q '^default '||add netzwerk "Route|Keine Standardroute"; getent ahosts deb.debian.org >/dev/null 2>&1||add netzwerk "DNS|Namensauflösung fehlgeschlagen"; port 1.1.1.1 53||add netzwerk "Internet|Externe Verbindung nicht erreichbar"
 dpkg --audit 2>/dev/null|sed '/^$/d'|head -8|while IFS= read -r l; do add pakete "dpkg|$l"; done; apt-get check >/dev/null 2>"$TMP/a"||grep '^E:' "$TMP/a"|head -8|while IFS= read -r l; do add pakete "apt|$l"; done
 journalctl -k -b -p err -o cat --no-pager 2>/dev/null|grep -Ev '^$|audit:|apparmor='|tail -12|while IFS= read -r l; do add kernel "Kernel|$l"; done
 systemctl is-system-running --quiet 2>/dev/null||add system "Systemzustand|System ist eingeschränkt"; [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = no ]&&add system "Systemzeit|Nicht synchronisiert"
 PRUEFUNGEN[6]="$(ps -e --no-headers|wc -l)"; n="$(ps -eo stat=|awk '$1~/^Z/{n++}END{print n+0}')"; [ "$n" -gt 0 ]&&add prozesse "Zombie-Prozesse|$n nicht aufgeräumte Prozesse"
 while read -r f _ _ _ q m; do [ "$f" = Filesystem ]&&continue; p="${q%%%}"; [[ "$p" =~ ^[0-9]+$ ]]||continue; [ "$p" -ge 90 ]&&add dateisystem "$m|Dateieinträge zu $p % belegt"; done < <(df -Pi)
 for k in "${KATEGORIEN[@]}"; do sauber "$k"; done
}

extern(){
 KATEGORIEN=(erreichbarkeit namensaufloesung route ports web ssh tls antwortzeit)
 TITEL=("Erreichbarkeit" "Namensauflösung" "Route" "Standardports" "Webdienste" "SSH" "TLS" "Antwortzeit")
 PRUEFUNGEN=(2 1 1 8 2 1 1 1)
 local k ip rc pruef p code t
 for k in "${KATEGORIEN[@]}"; do :>"$TMP/$k"; done
 rc=0; ip="$(aufloesen "$ZIEL" "$DNS_SERVER")"||rc=$?; [ "$rc" -eq 2 ]&&add namensaufloesung "$ZIEL|Eigener DNS benötigt dig oder nslookup"; [ -z "$ip" ]&&add namensaufloesung "$ZIEL|Nicht über ${DNS_SERVER:-System-DNS} auflösbar"; pruef="${ip:-$ZIEL}"
 ping -c1 -W2 "$pruef" >/dev/null 2>&1||add erreichbarkeit "$ZIEL|Antwortet nicht auf Ping"; port "$pruef" 80||port "$pruef" 443||port "$pruef" 22||add erreichbarkeit "$ZIEL|Kein Standarddienst erreichbar"
 ip route get "$pruef" >/dev/null 2>&1||add route "$ZIEL|Keine Route zum Ziel"
 for p in 22 25 53 80 110 143 443 3389; do port "$pruef" "$p"||add ports "Port $p|Nicht erreichbar"; done
 if command -v curl >/dev/null; then for p in 80 443; do [ "$p" = 80 ]&&proto=http||proto=https; code="$(curl -kLsS -o /dev/null --connect-timeout 3 --max-time 6 ${ip:+--resolve "$ZIEL:$p:$ip"} -w '%{http_code}' "$proto://$ZIEL" 2>/dev/null||true)"; [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]||add web "$proto|Keine gültige Antwort"; done; fi
 port "$pruef" 22||add ssh "SSH|Port 22 nicht erreichbar"; port "$pruef" 443||add tls "TLS|Port 443 nicht erreichbar"
 t="$(ping -c2 -W2 "$pruef" 2>/dev/null|awk -F/ '/^rtt|^round-trip/{print $5}')"; [ -z "$t" ]&&add antwortzeit "$ZIEL|Nicht messbar"; [ -n "$t" ]&&awk -v x="$t" 'BEGIN{exit !(x>200)}'&&add antwortzeit "$ZIEL|Hohe Antwortzeit: $t ms"
 for k in "${KATEGORIEN[@]}"; do sauber "$k"; done
}

scan(){ kopf; echo "Ziel wird geprüft ..."; if [ "$ZIEL" = localhost ]||[ "$ZIEL" = 127.0.0.1 ]||[ "$ZIEL" = ::1 ]; then lokal; else extern; fi; }

detail(){ local kat="$1" e="${2:-}" n m; [ -n "$e" ]||return; n="${e%%|*}"; m="${e#*|}"; kopf "$3/$n"; echo "$m"; if [ "$kat" = dienste ]; then echo; systemctl status --no-pager --full "$n" 2>&1|sed -n '1,14p'; echo; journalctl -u "$n" -b -o cat --no-pager 2>/dev/null|tail -8; fi; pause; }

fehler(){
 local kat="$1" titel="$2" seite=0 start ende i nr key idx total; local -a e=(); mapfile -t e < "$TMP/$kat"; total="${#e[@]}"
 while true; do start=$((seite*8)); ende=$((start+8)); [ "$ende" -gt "$total" ]&&ende="$total"; kopf "$titel"; nr=1; for((i=start;i<ende;i++));do printf '[%d] %s - %s\n' "$nr" "${e[$i]%%|*}" "${e[$i]#*|}";nr=$((nr+1));done; echo; printf '%d-%d/%d\n\n' "$((start+1))" "$ende" "$total"; [ "$ende" -lt "$total" ]&&echo "[9] Nächste Seite"; [ "$seite" -gt 0 ]&&echo "[0] Vorherige Seite"; echo "[Z] Zurück"; echo "[Q] Quit"; taste key
 case "${key,,}" in [1-8])idx=$((start+key-1));[ "$idx" -lt "$ende" ]&&detail "$kat" "${e[$idx]}" "$titel";;9)[ "$ende" -lt "$total" ]&&seite=$((seite+1));;0)[ "$seite" -gt 0 ]&&seite=$((seite-1));;z)return;;q)bild;exit;;esac; done
}

menu(){
 local i kat n total key idx; local -a fk=() ft=() fp=()
 for((i=0;i<${#KATEGORIEN[@]};i++));do kat="${KATEGORIEN[$i]}";n="$(anzahl "$kat")";[ "$n" -gt 0 ]&&{ fk+=("$kat");ft+=("${TITEL[$i]}");fp+=("${PRUEFUNGEN[$i]}");};done; total="${#fk[@]}"
 while true; do
  kopf
  if [ "$total" -eq 0 ]; then
   echo "Keine Fehler gefunden."
  else
   for((i=0;i<total&&i<8;i++)); do
    printf '[%d] %s/%s %s\n' "$((i+1))" "$(anzahl "${fk[$i]}")" "${fp[$i]}" "${ft[$i]}"
   done
   echo
   printf '1-%d/%d\n' "$total" "$total"
  fi
  echo
  echo "[E] Ziel und DNS"
  echo "[R] Erneut prüfen"
  echo "[Q] Quit"
  taste key
  case "${key,,}" in
   [1-8]) idx=$((key-1)); [ "$idx" -lt "$total" ] && fehler "${fk[$idx]}" "${ft[$idx]}" ;;
   e) einstellungen; return ;;
   r) scan; return ;;
   q) bild; exit ;;
  esac
 done
}

ZIEL="localhost"
DNS_SERVER=""
scan
while true; do menu; done

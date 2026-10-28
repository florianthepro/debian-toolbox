#!/usr/bin/env bash
set -uo pipefail
IFS=$'\n\t'

APP="Docker Verwaltung"
VERSION="2.0.0"
TTY=""
if [[ -r /dev/tty && -w /dev/tty ]]; then exec 3<>/dev/tty; TTY=/dev/tty; else printf 'FEHLER: Interaktives Terminal erforderlich.\n' >&2; exit 1; fi

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then R=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'; else R= B= D= RED= GRN= YEL= CYN=; fi
ok(){ printf '%b[OK]%b %s\n' "$GRN" "$R" "$*"; }
warn(){ printf '%b[!]%b %s\n' "$YEL" "$R" "$*"; }
fail(){ printf '%b[FEHLER]%b %s\n' "$RED" "$R" "$*" >&2; }
info(){ printf '%b[>]%b %s\n' "$CYN" "$R" "$*"; }
rule(){ printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '-'; }
cls(){ [[ -t 1 && "${TERM:-dumb}" != dumb ]] && printf '\033[2J\033[H' || true; }
pause(){ local x; read -r -u 3 -p 'Weiter mit Enter ...' x || true; }
ask(){ local p="$1" x; read -r -u 3 -p "$p [j/N]: " x || return 1; [[ "$x" =~ ^([jJ]|[jJ][aA])$ ]]; }
input(){ local p="$1"; read -r -u 3 -p "$p" REPLY || return 1; }
menu(){ local p="$1" max="$2" x; while true; do read -r -u 3 -p "$p" x || return 1; [[ "$x" =~ ^[0-9]+$ ]] && ((x>=0 && x<=max)) && { REPLY=$x; return; }; warn "Erlaubt: 0 bis $max"; done; }
need(){ command -v "$1" >/dev/null 2>&1 || { fail "$1 fehlt."; exit 1; }; }

engine_check(){
  need docker
  docker info >/dev/null 2>&1 || { fail 'Docker-Daemon nicht erreichbar.'; printf 'Pruefen: systemctl status docker\n'; exit 1; }
}

host_context(){
  local run all bad projects root use
  run=$(docker ps -q | wc -l); all=$(docker ps -aq | wc -l)
  bad=$(docker ps -a --format '{{.Status}}' | grep -Ec 'unhealthy|Restarting|Dead|Exited \([1-9]' || true)
  projects=$(docker ps -a --format '{{.Label "com.docker.compose.project"}}' | sed '/^$/d' | sort -u | wc -l)
  root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)
  use=$(df -P "$root" 2>/dev/null | awk 'NR==2{print $5}' || echo '?')
  printf '%bHost%b %s | Docker %s | Container %s/%s aktiv | Compose %s | Fehler %s | Speicher %s\n' "$B" "$R" "$(hostname)" "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')" "$run" "$all" "$projects" "$bad" "$use"
}

headr(){ cls; printf '%b%s%b  %bv%s%b\n' "$B" "$APP" "$R" "$D" "$VERSION" "$R"; rule; host_context; [[ -n "${1:-}" ]] && printf '%bOrt:%b %s\n' "$CYN" "$R" "$1"; rule; }

health(){
  local id name state code health restart image project any=0
  printf '%bAuffaelligkeiten%b\n' "$B" "$R"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    readarray -t a < <(docker inspect --format '{{.Name}}{{println}}{{.State.Status}}{{println}}{{.State.ExitCode}}{{println}}{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}{{println}}{{.RestartCount}}{{println}}{{.Config.Image}}{{println}}{{index .Config.Labels "com.docker.compose.project"}}' "$id")
    name=${a[0]#/}; state=${a[1]}; code=${a[2]}; health=${a[3]}; restart=${a[4]}; image=${a[5]}; project=${a[6]:-}
    if [[ "$health" == unhealthy || "$state" == restarting || "$state" == dead || ( "$state" == exited && "$code" != 0 ) ]]; then
      printf '  %b%-24s%b Status=%s Exit=%s Health=%s Restarts=%s Image=%s%s\n' "$RED" "$name" "$R" "$state" "$code" "$health" "$restart" "$image" "${project:+ Compose=$project}"
      any=1
    fi
  done < <(docker ps -aq)
  ((any==0)) && ok 'Keine erkennbaren Containerfehler.'
}

dashboard(){ headr 'Start > Gesamtuebersicht'; health; printf '\n'; docker system df 2>/dev/null || true; }

container_pick(){
  local -a ids; mapfile -t ids < <(docker ps -aq)
  ((${#ids[@]})) || { warn 'Keine Container vorhanden.'; pause; return 1; }
  local i row
  for i in "${!ids[@]}"; do
    row=$(docker inspect --format '{{.Name}}|{{.Config.Image}}|{{.State.Status}}{{if .State.Health}}/{{.State.Health.Status}}{{end}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}' "${ids[$i]}" 2>/dev/null); row=${row#/}
    IFS='|' read -r n im st pr sv <<<"$row"
    printf '%2d) %-22s %-26s %-18s %s\n' "$((i+1))" "$n" "$im" "$st" "${pr:+$pr/$sv}"
  done
  printf ' 0) Zurueck\n'; menu 'Container: ' "${#ids[@]}" || return 1; ((REPLY==0)) && return 1
  CID=${ids[$((REPLY-1))]}; CNAME=$(docker inspect --format '{{.Name}}' "$CID"); CNAME=${CNAME#/}
}

container_view(){
  headr 'Start > Container'; container_pick || return
  while true; do
    headr "Start > Container > $CNAME"
    local project service state health image restart workdir ports
    state=$(docker inspect --format '{{.State.Status}}' "$CID"); health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}kein Healthcheck{{end}}' "$CID")
    image=$(docker inspect --format '{{.Config.Image}}' "$CID"); restart=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$CID")
    project=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$CID" 2>/dev/null || true); service=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$CID" 2>/dev/null || true)
    workdir=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$CID" 2>/dev/null || true)
    printf 'Name: %s\nStatus: %s | Health: %s | Restart: %s\nImage: %s\nQuelle: %s\nPfad: %s\n\nPorts:\n' "$CNAME" "$state" "$health" "${restart:-no}" "$image" "${project:+Compose $project / Dienst $service}" "${workdir:-direkter Docker-Container}"
    docker port "$CID" 2>/dev/null | sed 's/^/  /' || echo '  keine'; printf 'Mounts:\n'; docker inspect --format '{{range .Mounts}}  {{.Type}}: {{.Source}} -> {{.Destination}}{{println}}{{end}}' "$CID"
    printf '\n1) Start  2) Stop  3) Neustart  4) Logs  5) Live-Logs\n6) Shell  7) Details  8) Entfernen  9) Zugehoeriges Compose-Projekt  0) Zurueck\n'
    menu 'Aktion: ' 9 || return
    case $REPLY in
      0)return;; 1)docker start "$CID"; pause;; 2)docker stop "$CID"; pause;; 3)docker restart "$CID"; pause;;
      4)docker logs --tail 250 --timestamps "$CID" 2>&1 | less -R -F -X; pause;;
      5)info 'Beenden mit Strg+C'; docker logs -f --tail 100 --timestamps "$CID" <&3 || true; pause;;
      6)local shx=''; for x in bash sh ash; do docker exec "$CID" command -v "$x" >/dev/null 2>&1 && { shx=$x; break; }; done; [[ -n "$shx" ]] && docker exec -it "$CID" "$shx" <&3 || warn 'Keine Shell gefunden.'; pause;;
      7)docker inspect "$CID" | less -R; pause;;
      8)if [[ -n "$project" ]]; then warn "Dieser Container gehoert zu Compose. Entferne den Dienst im Compose-Menue, damit Definition und Ressourcen konsistent bleiben."; else ask "Container $CNAME stoppen und entfernen?" && docker rm -f "$CID" && return; fi; pause;;
      9)[[ -n "$project" ]] && { compose_project "$project"; return; } || { warn 'Kein Compose-Projekt.'; pause; };;
    esac
  done
}

project_meta(){
  local p="$1" cid
  cid=$(docker ps -aq --filter "label=com.docker.compose.project=$p" | head -n1)
  [[ -n "$cid" ]] || return 1
  PDIR=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$cid")
  PFILES=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$cid")
  [[ -n "$PDIR" && -d "$PDIR" ]] || return 1
  COMPOSE=(docker compose --project-directory "$PDIR" -p "$p")
  local oldifs=$IFS f; IFS=',' read -ra fa <<<"$PFILES"; IFS=$oldifs
  for f in "${fa[@]}"; do [[ -n "$f" ]] && COMPOSE+=(-f "$f"); done
}

project_pick(){
  local -a ps; mapfile -t ps < <(docker ps -a --format '{{.Label "com.docker.compose.project"}}' | sed '/^$/d' | sort -u)
  ((${#ps[@]})) || { warn 'Keine Compose-Projekte gefunden.'; pause; return 1; }
  local i p; for i in "${!ps[@]}"; do p=${ps[$i]}; printf '%2d) %-24s %s Container | %s\n' "$((i+1))" "$p" "$(docker ps -aq --filter "label=com.docker.compose.project=$p" | wc -l)" "$(docker ps -q --filter "label=com.docker.compose.project=$p" | wc -l) aktiv"; done
  printf ' 0) Zurueck\n'; menu 'Projekt: ' "${#ps[@]}" || return 1; ((REPLY==0)) && return 1; PROJECT=${ps[$((REPLY-1))]}
}

remove_yaml_service(){
  local file="$1" service="$2" out="$3"
  python3 - "$file" "$service" "$out" <<'PY'
import re,sys
src,name,out=sys.argv[1:]
lines=open(src,encoding='utf-8').readlines()
services=None; base=None; start=None; end=None
for i,line in enumerate(lines):
    if re.match(r'^services\s*:\s*(?:#.*)?$',line): services=i; base=len(line)-len(line.lstrip()); break
if services is None: raise SystemExit('services:-Abschnitt fehlt')
for i in range(services+1,len(lines)):
    line=lines[i]
    if not line.strip() or line.lstrip().startswith('#'): continue
    ind=len(line)-len(line.lstrip())
    if ind<=base: break
    m=re.match(r'^(\s*)([A-Za-z0-9_.-]+)\s*:\s*(?:#.*)?$',line)
    if m and len(m.group(1))>base and m.group(2)==name:
        start=i; level=len(m.group(1)); break
if start is None: raise SystemExit('Dienst nicht in services: gefunden')
end=len(lines)
for i in range(start+1,len(lines)):
    line=lines[i]
    if not line.strip() or line.lstrip().startswith('#'): continue
    ind=len(line)-len(line.lstrip())
    if ind<=base or ind==level: end=i; break
new=lines[:start]+lines[end:]
open(out,'w',encoding='utf-8').writelines(new)
PY
}

remove_service(){
  local p="$1"; project_meta "$p" || { fail 'Compose-Pfad nicht ermittelbar.'; pause; return; }
  local -a services; mapfile -t services < <("${COMPOSE[@]}" config --services 2>/dev/null)
  ((${#services[@]})) || { warn 'Keine Dienste gefunden.'; pause; return; }
  headr "Start > Compose > $p > Dienst entfernen"
  warn 'Ablauf: Backup > neue Konfiguration pruefen > Dienst stoppen > Container entfernen > Datei ersetzen > Projekt abgleichen > unbenutzte projektspezifische Netzwerke pruefen.'
  printf 'Volumes werden nicht automatisch geloescht, da sie Daten enthalten oder geteilt sein koennen.\n\n'
  local i; for i in "${!services[@]}"; do printf '%2d) %s\n' "$((i+1))" "${services[$i]}"; done; printf ' 0) Abbrechen\n'; menu 'Dienst: ' "${#services[@]}" || return; ((REPLY==0)) && return
  local svc=${services[$((REPLY-1))]}
  local cfg=${PFILES%%,*}; [[ "$cfg" = /* ]] || cfg="$PDIR/$cfg"
  [[ -f "$cfg" ]] || { fail "Compose-Datei nicht gefunden: $cfg"; pause; return; }
  local stamp backup temp; stamp=$(date +%Y%m%d-%H%M%S); backup="$cfg.bak-$stamp"; temp="$cfg.tmp-$$"
  cp -a -- "$cfg" "$backup" || { fail 'Backup fehlgeschlagen.'; pause; return; }
  if ! remove_yaml_service "$cfg" "$svc" "$temp"; then rm -f "$temp"; fail 'Dienst konnte nicht sicher aus YAML entfernt werden.'; pause; return; fi
  local -a testcmd=(docker compose --project-directory "$PDIR" -p "$p"); local oldifs=$IFS f; IFS=',' read -ra fa <<<"$PFILES"; IFS=$oldifs
  for f in "${fa[@]}"; do [[ "$f" == "${PFILES%%,*}" ]] && testcmd+=(-f "$temp") || testcmd+=(-f "$f"); done
  if ! "${testcmd[@]}" config -q; then rm -f "$temp"; fail 'Neue Compose-Konfiguration ungueltig. Original bleibt unveraendert.'; pause; return; fi
  printf '\nDienst: %s\nDatei: %s\nBackup: %s\n' "$svc" "$cfg" "$backup"
  ask "Dienst $svc jetzt dauerhaft aus Projekt $p entfernen?" || { rm -f "$temp"; info 'Abgebrochen.'; pause; return; }
  "${COMPOSE[@]}" stop "$svc" || true
  "${COMPOSE[@]}" rm -f -s "$svc" || { rm -f "$temp"; fail 'Container konnte nicht entfernt werden. Konfiguration bleibt unveraendert.'; pause; return; }
  chown --reference="$cfg" "$temp" 2>/dev/null || true; chmod --reference="$cfg" "$temp" 2>/dev/null || true
  mv -f -- "$temp" "$cfg"
  if ! "${COMPOSE[@]}" config -q; then cp -a -- "$backup" "$cfg"; fail 'Validierung nach Austausch fehlgeschlagen. Backup wiederhergestellt.'; pause; return; fi
  "${COMPOSE[@]}" up -d --remove-orphans || warn 'Projekt konnte nicht vollstaendig abgeglichen werden. Backup ist vorhanden.'
  local n used; while IFS= read -r n; do [[ -n "$n" ]] || continue; used=$(docker network inspect -f '{{len .Containers}}' "$n" 2>/dev/null || echo 1); if [[ "$used" == 0 ]]; then docker network rm "$n" >/dev/null && info "Leeres Projektnetzwerk entfernt: $n"; fi; done < <(docker network ls -q --filter "label=com.docker.compose.project=$p")
  ok "Dienst $svc entfernt. Backup: $backup"
  pause
}

compose_project(){
  local p="$1"; project_meta "$p" || { fail 'Projektpfad fehlt oder ist nicht lesbar.'; pause; return; }
  while true; do
    headr "Start > Compose > $p"
    printf 'Pfad: %s\nDateien: %s\n\n' "$PDIR" "$PFILES"
    docker ps -a --filter "label=com.docker.compose.project=$p" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
    printf '\n1) Start/Abgleich  2) Stop  3) Neustart  4) Pull + Abgleich\n5) Logs  6) Konfiguration pruefen  7) Dienst dauerhaft entfernen\n8) Projekt herunterfahren  9) Projekt inklusive Volumes entfernen  0) Zurueck\n'
    menu 'Aktion: ' 9 || return
    case $REPLY in
      0)return;; 1)"${COMPOSE[@]}" up -d --remove-orphans; pause;; 2)"${COMPOSE[@]}" stop; pause;; 3)"${COMPOSE[@]}" restart; pause;;
      4)"${COMPOSE[@]}" pull && "${COMPOSE[@]}" up -d --remove-orphans; pause;; 5)"${COMPOSE[@]}" logs --tail 300 | less -R; pause;;
      6)"${COMPOSE[@]}" config -q && ok 'Konfiguration gueltig.'; pause;; 7)remove_service "$p"; project_meta "$p" || return;;
      8)ask "Projekt $p stoppen und Container sowie Projektnetzwerke entfernen? Volumes bleiben." && "${COMPOSE[@]}" down; pause;;
      9)warn 'Dabei werden auch deklarierte und anonyme Projekt-Volumes mit ihren Daten geloescht.'; ask "Projekt $p inklusive Volumes ENDGUELTIG entfernen?" && { input "Zur Bestaetigung Projektnamen eingeben ($p): "; [[ "$REPLY" == "$p" ]] && "${COMPOSE[@]}" down -v --remove-orphans || warn 'Bestaetigung stimmt nicht.'; }; pause;;
    esac
  done
}

compose_menu(){ headr 'Start > Compose'; project_pick || return; compose_project "$PROJECT"; }

networks(){
  while true; do headr 'Start > Netzwerke'; local -a ns; mapfile -t ns < <(docker network ls -q); local i n row; for i in "${!ns[@]}"; do n=${ns[$i]}; row=$(docker network inspect -f '{{.Name}}|{{.Driver}}|{{.Scope}}|{{len .Containers}}|{{index .Labels "com.docker.compose.project"}}' "$n"); IFS='|' read -r nn dr sc co pr <<<"$row"; printf '%2d) %-25s Driver=%-8s Container=%-3s %s\n' "$((i+1))" "$nn" "$dr" "$co" "${pr:+Compose=$pr}"; done; printf ' 0) Zurueck\n'; menu 'Netzwerk: ' "${#ns[@]}" || return; ((REPLY==0)) && return; n=${ns[$((REPLY-1))]}; headr "Start > Netzwerke > $(docker network inspect -f '{{.Name}}' "$n")"; docker network inspect "$n" | less -R; if [[ $(docker network inspect -f '{{len .Containers}}' "$n") == 0 ]] && [[ $(docker network inspect -f '{{.Name}}' "$n") != bridge && $(docker network inspect -f '{{.Name}}' "$n") != host && $(docker network inspect -f '{{.Name}}' "$n") != none ]]; then ask 'Dieses leere Netzwerk entfernen?' && docker network rm "$n"; fi; pause; done
}

volumes(){ headr 'Start > Volumes'; local v links; while IFS= read -r v; do links=$(docker ps -aq --filter "volume=$v" | wc -l); printf '%-35s verwendet_von=%s\n' "$v" "$links"; done < <(docker volume ls -q); printf '\n'; warn 'Volumes werden nur bewusst und separat geloescht.'; if ask 'Ungenutzte Volumes einzeln anzeigen?'; then docker volume ls -q -f dangling=true; fi; pause; }
images(){ headr 'Start > Images'; docker image ls --digests; printf '\n'; ask 'Nur ungenutzte Images bereinigen?' && docker image prune -a; pause; }
diagnose(){ headr 'Start > Diagnose'; health; printf '\n'; docker info 2>&1 | grep -E 'Server Version|Storage Driver|Cgroup|Kernel Version|Operating System|Docker Root Dir|WARNING' || true; printf '\n'; systemctl --no-pager --full status docker 2>/dev/null | tail -n 20 || true; pause; }

main(){
  engine_check
  while true; do
    dashboard
    printf '\n%bVerwaltung%b\n1) Container mit Herkunft und Ressourcen\n2) Compose-Projekte und Dienste\n3) Netzwerke und Verbindungen\n4) Volumes und Verwendung\n5) Images und Bereinigung\n6) Diagnose\n0) Beenden\n' "$B" "$R"
    menu 'Auswahl: ' 6 || break
    case $REPLY in 0)break;; 1)container_view;; 2)compose_menu;; 3)networks;; 4)volumes;; 5)images;; 6)diagnose;; esac
  done
  printf 'Auf Wiedersehen.\n'
}
trap 'printf "\n"' INT
main "$@"

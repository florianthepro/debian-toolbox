#!/usr/bin/env bash
set -uo pipefail
IFS=$'\n\t'

APP_NAME="Docker Verwaltung"
VERSION="1.0.0"
DOCKER=(docker)
C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_BLUE='\033[34m'; C_CYAN='\033[36m'
[[ -t 1 && "${NO_COLOR:-}" == "" ]] || C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''

ok(){ printf "%b✓%b %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn(){ printf "%b!%b %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err(){ printf "%b✗%b %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
info(){ printf "%b›%b %s\n" "$C_CYAN" "$C_RESET" "$*"; }
line(){ printf '%*s\n' "${COLUMNS:-78}" '' | tr ' ' '─'; }
have(){ command -v "$1" >/dev/null 2>&1; }
pause(){ [[ -t 0 ]] && read -r -p "Weiter mit Enter ..." _ || true; }
clear_screen(){ [[ -t 1 && "${TERM:-dumb}" != dumb ]] && printf '\033[2J\033[H' || true; }
header(){ clear_screen; printf "%b%s%b  %b%s%b\n" "$C_BOLD" "$APP_NAME" "$C_RESET" "$C_DIM" "v$VERSION" "$C_RESET"; line; }
confirm(){ local answer; read -r -p "$1 [j/N]: " answer || return 1; [[ "$answer" =~ ^([jJ]|[jJ][aA])$ ]]; }
choose(){ local prompt="$1" max="$2" value; while true; do read -r -p "$prompt" value || return 1; [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 0 && value <= max )) && { REPLY="$value"; return 0; }; warn "Bitte eine Zahl zwischen 0 und $max eingeben."; done; }

need_root_context(){
  if (( EUID != 0 )); then warn "Nicht als root gestartet. Docker-Berechtigungen des aktuellen Benutzers werden verwendet."; fi
}
check_docker(){
  if ! have docker; then
    err "Docker CLI wurde nicht gefunden. Installiere zuerst Docker Engine aus einer vertrauenswürdigen Paketquelle."
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    err "Docker-Daemon ist nicht erreichbar."
    printf "\nMögliche Ursachen:\n  • Dienst gestoppt: systemctl status docker\n  • fehlende Rechte: sudo oder Mitgliedschaft in der Gruppe docker\n  • DOCKER_HOST zeigt auf ein nicht erreichbares Ziel\n"
    exit 1
  fi
}

count(){ "${DOCKER[@]}" "$@" -q 2>/dev/null | wc -l | tr -d ' '; }
status_value(){ local label="$1" value="$2" level="${3:-normal}"; printf "%-24s " "$label"; case "$level" in ok) printf "%b%s%b\n" "$C_GREEN" "$value" "$C_RESET";; warn) printf "%b%s%b\n" "$C_YELLOW" "$value" "$C_RESET";; bad) printf "%b%s%b\n" "$C_RED" "$value" "$C_RESET";; *) printf "%s\n" "$value";; esac; }

health_scan(){
  local running stopped unhealthy restarting dead dangling project_count failed_services disk_pct root_dir
  running=$(docker ps -q 2>/dev/null | wc -l); stopped=$(docker ps -aq -f status=exited -f status=created 2>/dev/null | wc -l)
  unhealthy=$(docker ps -q -f health=unhealthy 2>/dev/null | wc -l); restarting=$(docker ps -q -f status=restarting 2>/dev/null | wc -l); dead=$(docker ps -aq -f status=dead 2>/dev/null | wc -l)
  dangling=$(docker image ls -q -f dangling=true 2>/dev/null | sort -u | wc -l)
  project_count=$(docker ps -a --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | sed '/^$/d' | sort -u | wc -l)
  root_dir=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || printf '/var/lib/docker')
  disk_pct=$(df -P "$root_dir" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
  printf "%bSystemzustand%b\n\n" "$C_BOLD" "$C_RESET"
  status_value "Laufende Container" "$running" "$([[ $running -gt 0 ]] && echo ok || echo warn)"
  status_value "Gestoppte Container" "$stopped" "$([[ $stopped -gt 0 ]] && echo warn || echo ok)"
  status_value "Unhealthy" "$unhealthy" "$([[ $unhealthy -gt 0 ]] && echo bad || echo ok)"
  status_value "Restarting" "$restarting" "$([[ $restarting -gt 0 ]] && echo bad || echo ok)"
  status_value "Dead" "$dead" "$([[ $dead -gt 0 ]] && echo bad || echo ok)"
  status_value "Compose-Projekte" "$project_count"
  status_value "Ungenutzte Images" "$dangling" "$([[ $dangling -gt 0 ]] && echo warn || echo ok)"
  if [[ "$disk_pct" =~ ^[0-9]+$ ]]; then status_value "Datenträger Docker" "${disk_pct}% belegt" "$([[ $disk_pct -ge 90 ]] && echo bad || ([[ $disk_pct -ge 80 ]] && echo warn || echo ok))"; fi
  printf "\n%bAuffälligkeiten%b\n" "$C_BOLD" "$C_RESET"
  local issues=0 names
  names=$(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null); [[ -n "$names" ]] && { err "Unhealthy: ${names//$'\n'/, }"; issues=1; }
  names=$(docker ps --filter status=restarting --format '{{.Names}}' 2>/dev/null); [[ -n "$names" ]] && { err "Neustart-Schleife: ${names//$'\n'/, }"; issues=1; }
  names=$(docker ps -a --filter status=exited --format '{{if ne .Status "Exited (0)"}}{{.Names}} — {{.Status}}{{end}}' 2>/dev/null | sed '/^$/d'); [[ -n "$names" ]] && { warn "Fehlerhaft beendet:"; printf '%s\n' "$names" | sed 's/^/  /'; issues=1; }
  (( issues == 0 )) && ok "Keine direkt erkennbaren Containerfehler."
}

dashboard(){
  header
  local server os kernel compose
  server=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')
  os=$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || echo '?')
  kernel=$(docker info --format '{{.KernelVersion}}' 2>/dev/null || echo '?')
  compose=$(docker compose version --short 2>/dev/null || echo 'nicht verfügbar')
  printf "%bHost%b  %s | Kernel %s\n" "$C_BOLD" "$C_RESET" "$os" "$kernel"
  printf "%bDocker%b  Engine %s | Compose %s\n\n" "$C_BOLD" "$C_RESET" "$server" "$compose"
  health_scan
  printf "\n"; docker system df 2>/dev/null || true
}

select_container(){
  local -a ids names; mapfile -t ids < <(docker ps -aq); ((${#ids[@]})) || { warn "Keine Container vorhanden."; return 1; }
  printf "\n%bContainer%b\n" "$C_BOLD" "$C_RESET"
  local i id display; for i in "${!ids[@]}"; do id="${ids[$i]}"; display=$(docker inspect --format '{{.Name}}|{{.Config.Image}}|{{.State.Status}}{{if .State.Health}}/{{.State.Health.Status}}{{end}}' "$id" 2>/dev/null); display="${display#/}"; printf " %2d) %-28s %-30s %s\n" "$((i+1))" "${display%%|*}" "$(cut -d'|' -f2 <<<"$display")" "$(cut -d'|' -f3- <<<"$display")"; done
  printf "  0) Zurück\n"; choose "Auswahl: " "${#ids[@]}" || return 1; (( REPLY == 0 )) && return 1; SELECTED_ID="${ids[$((REPLY-1))]}"; SELECTED_NAME=$(docker inspect --format '{{.Name}}' "$SELECTED_ID"); SELECTED_NAME="${SELECTED_NAME#/}";
}

container_detail(){
  select_container || return
  while true; do
    header; local state health image restart ports mounts project workdir
    state=$(docker inspect --format '{{.State.Status}}' "$SELECTED_ID"); health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}kein Healthcheck{{end}}' "$SELECTED_ID")
    image=$(docker inspect --format '{{.Config.Image}}' "$SELECTED_ID"); restart=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$SELECTED_ID")
    project=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$SELECTED_ID" 2>/dev/null || true); workdir=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$SELECTED_ID" 2>/dev/null || true)
    printf "%b%s%b\n\nStatus: %s | Health: %s\nImage: %s\nRestart: %s\n" "$C_BOLD" "$SELECTED_NAME" "$C_RESET" "$state" "$health" "$image" "${restart:-no}"
    [[ -n "$project" ]] && printf "Compose: %s (%s)\n" "$project" "$workdir"
    printf "Ports: "; docker port "$SELECTED_ID" 2>/dev/null | paste -sd ', ' - || printf -- '-'; printf "\nMounts:\n"; docker inspect --format '{{range .Mounts}}  {{.Type}}: {{.Source}} -> {{.Destination}} {{println}}{{end}}' "$SELECTED_ID" 2>/dev/null
    printf "\n1) Starten  2) Stoppen  3) Neustarten  4) Logs  5) Live-Logs\n6) Shell    7) Vollständige Details  8) Entfernen  0) Zurück\n"
    choose "Aktion: " 8 || return
    case "$REPLY" in
      0) return;; 1) docker start "$SELECTED_ID"; pause;; 2) docker stop "$SELECTED_ID"; pause;; 3) docker restart "$SELECTED_ID"; pause;;
      4) docker logs --tail 200 --timestamps "$SELECTED_ID" 2>&1 | less -R -F -X 2>/dev/null || docker logs --tail 200 --timestamps "$SELECTED_ID"; pause;;
      5) info "Beenden mit Strg+C"; docker logs -f --tail 100 --timestamps "$SELECTED_ID" || true; pause;;
      6) local shell=''; for s in bash sh ash; do docker exec "$SELECTED_ID" command -v "$s" >/dev/null 2>&1 && { shell="$s"; break; }; done; [[ -n "$shell" ]] && docker exec -it "$SELECTED_ID" "$shell" || warn "Keine unterstützte Shell im Container gefunden."; pause;;
      7) docker inspect "$SELECTED_ID" | less -R 2>/dev/null || docker inspect "$SELECTED_ID"; pause;;
      8) if confirm "Container '$SELECTED_NAME' wirklich stoppen und entfernen?"; then docker rm -f "$SELECTED_ID" && { ok "Entfernt."; pause; return; }; else info "Abgebrochen."; fi; pause;;
    esac
  done
}

containers_overview(){ header; docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'; printf "\n"; container_detail; }

compose_projects(){
  header
  if ! docker compose version >/dev/null 2>&1; then warn "Docker Compose Plugin ist nicht verfügbar."; pause; return; fi
  local -a projects; mapfile -t projects < <(docker ps -a --format '{{.Label "com.docker.compose.project"}}' | sed '/^$/d' | sort -u)
  ((${#projects[@]})) || { warn "Keine Compose-Projekte über Container-Labels gefunden."; pause; return; }
  local i p; for i in "${!projects[@]}"; do p="${projects[$i]}"; printf " %2d) %-28s %s Container\n" "$((i+1))" "$p" "$(docker ps -a -q --filter "label=com.docker.compose.project=$p" | wc -l)"; done
  printf "  0) Zurück\n"; choose "Projekt: " "${#projects[@]}" || return; ((REPLY==0)) && return; p="${projects[$((REPLY-1))]}"
  local cid dir files; cid=$(docker ps -aq --filter "label=com.docker.compose.project=$p" | head -n1); dir=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$cid"); files=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$cid")
  header; printf "%b%s%b\nPfad: %s\nDateien: %s\n\n" "$C_BOLD" "$p" "$C_RESET" "${dir:-unbekannt}" "${files:-unbekannt}"; docker ps -a --filter "label=com.docker.compose.project=$p" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  printf "\n1) Start/Up  2) Stop  3) Neustart  4) Pull + Up  5) Logs  6) Down  0) Zurück\n"; choose "Aktion: " 6 || return
  [[ -d "$dir" ]] || { err "Projektpfad ist nicht vorhanden oder nicht lesbar: $dir"; pause; return; }
  local -a cc=(docker compose --project-directory "$dir" -p "$p"); IFS=',' read -ra farr <<<"$files"; local f; for f in "${farr[@]}"; do [[ -n "$f" ]] && cc+=(-f "$f"); done
  case "$REPLY" in 0) return;; 1) "${cc[@]}" up -d;; 2) "${cc[@]}" stop;; 3) "${cc[@]}" restart;; 4) "${cc[@]}" pull && "${cc[@]}" up -d --remove-orphans;; 5) "${cc[@]}" logs --tail 200 | less -R 2>/dev/null || "${cc[@]}" logs --tail 200;; 6) confirm "Projekt '$p' herunterfahren? Volumes bleiben erhalten." && "${cc[@]}" down;; esac; pause
}

resource_menu(){
  while true; do header; printf "1) Images\n2) Volumes\n3) Netzwerke\n4) Speicherbelegung detailliert\n0) Zurück\n"; choose "Auswahl: " 4 || return; case "$REPLY" in 0)return;; 1) header; docker image ls --digests; pause;; 2) header; docker volume ls; printf "\n"; docker volume ls -q -f dangling=true | sed 's/^/Ungenutzt: /'; pause;; 3) header; docker network ls; pause;; 4) header; docker system df -v | less -R 2>/dev/null || docker system df -v; pause;; esac; done
}

cleanup_menu(){
  header; printf "%bSichere Bereinigung%b\n\nEs werden standardmäßig keine verwendeten Daten und keine Volumes gelöscht.\n\n1) Gestoppte Container entfernen\n2) Ungenutzte Images entfernen\n3) Build-Cache entfernen\n4) Ungenutzte Netzwerke entfernen\n5) Ungenutzte Volumes entfernen (Datenverlust möglich)\n0) Zurück\n" "$C_BOLD" "$C_RESET"; choose "Auswahl: " 5 || return
  case "$REPLY" in 0)return;; 1) confirm "Alle gestoppten Container entfernen?" && docker container prune -f;; 2) confirm "Alle nicht verwendeten Images entfernen?" && docker image prune -a -f;; 3) confirm "Ungenutzten Build-Cache entfernen?" && docker builder prune -f;; 4) confirm "Ungenutzte Netzwerke entfernen?" && docker network prune -f;; 5) warn "Ungenutzte Volumes können wichtige persistente Daten enthalten."; confirm "Volumes trotzdem endgültig löschen?" && docker volume prune -f;; esac; pause
}

system_info(){ header; docker version; printf "\n"; docker info; pause; }

diagnostics(){
  header; health_scan; printf "\n%bLetzte Docker-Dienstmeldungen%b\n" "$C_BOLD" "$C_RESET"; if have systemctl; then systemctl is-active docker 2>/dev/null && ok "docker.service ist aktiv" || warn "docker.service ist nicht aktiv oder nicht durch systemd verwaltet"; systemctl --no-pager --full status docker 2>/dev/null | tail -n 18 || true; fi
  printf "\n%bContainer mit auffälligem Status%b\n" "$C_BOLD" "$C_RESET"; docker ps -a --format '{{.Names}}|{{.Status}}' | awk -F'|' '$2 ~ /unhealthy|Restarting|Exited \([^0]/ {print "  "$1" — "$2}'
  pause
}

main(){
  need_root_context; check_docker
  while true; do
    dashboard
    printf "\n%bVerwaltung%b\n1) Container verwalten\n2) Compose-Projekte\n3) Images, Volumes und Netzwerke\n4) Diagnose\n5) Sichere Bereinigung\n6) Docker-Systeminformationen\n0) Beenden\n" "$C_BOLD" "$C_RESET"
    choose "Auswahl: " 6 || break
    case "$REPLY" in 0)break;; 1)containers_overview;; 2)compose_projects;; 3)resource_menu;; 4)diagnostics;; 5)cleanup_menu;; 6)system_info;; esac
  done
  printf "\nAuf Wiedersehen.\n"
}

trap 'printf "\n"' INT
main "$@"

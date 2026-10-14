#!/usr/bin/env bash
# -----------------------------------------
# LogDesk Bash 4.4 — Author: Teo Espero
# Revision: 2026-10-13 Rewrite without Python.
# Uses Bash, journalctl, awk, date, sort, tail, find, base64, and tput.
# 2026-10-13 v2.1 Cached files, background refresh, extra log roots.
# 2026-10-13 v2.2 Progressive snapshots and collection diagnostics.
# 2026-10-13 v2.3 Conditional sudo prompt before starting the interface.
# 2026-10-13 v2.6 Start with 200 total; M loads more; bounded preview.
# 2026-10-13 v2.7 Decode multiline journal fields and preserve empty columns.
# 2026-10-13 v2.8 Load all by default; sort by time then source and unit/file.
# 2026-10-13 v2.9 Stream journal records into progressive snapshots.
# 2026-10-13 v3.0 Count accessible entries before loading; record-based progress.
# 2026-10-13 v3.1 Capture once; parse text timestamps in whole-file awk batches.
# 2026-10-13 v4.0 Batch JSON parsing, journal cursor refresh, indexed disk pages.
# 2026-10-13 v4.1 Loading dialog with Escape dismissal.
# 2026-10-13 v4.2 Dialog type titles; unbuffered mawk journal streaming.
# 2026-10-13 v4.3 Merge sorted source batches; bypass inactive filters.
# 2026-10-13 v4.4 Sort dialog: field, direction, Apply/Cancel.
# Sources are read-only. Export creates a new CSV file.
# -----------------------------------------
set -o pipefail
# mawk normally buffers pipe input; interactive mode releases each record.
AWK_JOURNAL_FLAGS=()
if [[ $(awk -W version 2>&1) == *mawk* ]];then AWK_JOURNAL_FLAGS=(-W interactive);fi
export LC_ALL=C.UTF-8
LIMIT=0 LOGDIR=/var/log ROTATED=0 DUMP=0
EXTRA_DIRS=() USER_LOGS=0 WORKER='' SKIP_SUDO=0
while (($#)); do
 case $1 in
 --log-dir) LOGDIR=${2:?Missing directory};shift 2;;
 --extra-dir) EXTRA_DIRS+=("${2:?Missing directory}");shift 2;;
 --no-sudo) SKIP_SUDO=1;shift;;
 --user-logs) USER_LOGS=1;shift;;
 --limit) LIMIT=${2:?Missing limit};shift 2;;
 --rotated) ROTATED=1;shift;;
 --dump) DUMP=1;shift;;
 --help) echo 'Usage: bash logdesk-bash.sh [--log-dir PATH] [--limit N] [--rotated] [--dump] [--user-logs] [--extra-dir PATH] [--no-sudo]';exit;;
 *) echo "Unknown option: $1" >&2;exit 1;;
 esac
done
[[ $LIMIT =~ ^[0-9]+$ ]] || { echo 'Limit must be a nonnegative integer (0 means all).' >&2;exit 1; }
for cmd in awk date sort tail find mktemp tput stat cksum head od tr fold readlink tac ln cut; do
 command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2;exit 1; }
done
# -----------------------------------------
# Check access before entering the alternate screen. sudo alone reads
# the password; this script never receives or stores it. If authentication
# fails, continue with readable sources. --no-sudo disables elevation.
# Keep the original user's log folders when sudo changes HOME to /root.
# -----------------------------------------
if ((USER_LOGS));then
 for dir in "${XDG_STATE_HOME:-$HOME/.local/state}" "$HOME/.cache";do
  [[ -d $dir ]] && EXTRA_DIRS+=("$dir")
 done
 USER_LOGS=0
fi
if ((EUID!=0 && !SKIP_SUDO)) && [[ -t 0 && -t 1 ]];then
 needs_sudo=0
 probe=$(mktemp) || exit 1
 inaccessible=$(find "$LOGDIR" "${EXTRA_DIRS[@]}" \( -type f ! -readable -o -type d ! -executable \) -print -quit 2> "$probe")
 [[ -z $inaccessible && ! -s $probe ]] || needs_sudo=1
 if command -v journalctl >/dev/null;then
  journalctl -n 1 --no-pager > /dev/null 2> "$probe"
  if [[ $? != 0 ]] || LC_ALL=C awk 'tolower($0) ~ /permission|not seeing|insufficient|access denied/ {found=1} END {exit !found}' "$probe";then needs_sudo=1;fi
 fi
 rm -f -- "$probe"
 if ((needs_sudo));then
  printf '\nSome system logs need administrator access.\n'
  if command -v sudo >/dev/null;then
   printf 'sudo may ask for your login password; typing will not appear.\n'
   if sudo -v;then
    script_path=$(readlink -f -- "${BASH_SOURCE[0]}") || exit 1
    elevated_args=(--log-dir "$LOGDIR" --limit "$LIMIT" --no-sudo)
    for dir in "${EXTRA_DIRS[@]}";do elevated_args+=(--extra-dir "$dir");done
    ((ROTATED)) && elevated_args+=(--rotated)
    exec sudo -n /bin/bash -- "$script_path" "${elevated_args[@]}"
   fi
   printf 'Administrator access was not granted. Loading readable logs only.\n'
  else printf 'sudo is unavailable. Loading readable logs only.\n';fi
 fi
fi
# -----------------------------------------
# Private temporary files hold snapshots. Always remove them and restore
# the terminal, including when interrupted. Never run commands from log text.
# -----------------------------------------
TMP=$(mktemp -d) || exit 1
mkdir -p "$TMP/cache"
CACHE="$TMP/cache"
ACTIVE=0
cleanup() {
 if [[ -n $WORKER ]];then kill "$WORKER" 2>/dev/null;wait "$WORKER" 2>/dev/null;fi
 if ((ACTIVE));then printf '\e[0m\e[?25h\e[?1049l'; fi
 rm -rf -- "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
# Escape separators with Bash built-ins. Prefix each string with x so even
# an empty value remains a nonempty TSV field during Bash read.
encode() { local s=$1; s=${s//\\/\\\\};s=${s//$'\t'/\\t};s=${s//$'\n'/\\n};s=${s//$'\r'/\\r};REPLY="x$s"; }
decode() { printf -v REPLY '%b' "${1:1}"; }
# -----------------------------------------
# Sanitise displayed content, keeping tabs/newlines as spaces and removing
# terminal control bytes. Stored messages escape backslashes and TSV separators.
# -----------------------------------------
safe() { local s=$1; s=${s//$'\n'/ };s=${s//$'\t'/ };REPLY=${s//[$'\001'-$'\037'$'\177']/ };  }
levels=(emergency alert critical error warning notice info debug unknown)
severity() {
 local s=${1,,}
 case $s in
 *critical*|*fatal*|*panic*) REPLY='critical*';;
 *error*|*failed*|*failure*) REPLY='error*';;
 *warning*|*warn*) REPLY='warning*';;
 *debug*) REPLY='debug*';;
 *info*) REPLY='info*';;
 *) REPLY=unknown;;esac
}
append() {
 local encoded_unit encoded_message
 encode "$4";encoded_unit=$REPLY;encode "$6";encoded_message=$REPLY
 printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$encoded_unit" "$5" "$encoded_message" >> "$TMP/raw"
 ((RECORDS++))
}
PARTIAL_LAST=-10
publish_partial() {
 [[ ${STREAM:-0} == 1 ]] || return
 ((SECONDS-PARTIAL_LAST>=4)) || return
 PARTIAL_LAST=$SECONDS
 if [[ ${CAPTURING:-0} == 1 ]];then
  # Keep previews small while the journal is still being decoded.
  tail -n 500 "$TMP/raw" | sort -t $'\t' -k1,1nr -k2,2 -k4,4 -s > "$TMP/snapshot.new"
 else sort -t $'\t' -k1,1nr -k2,2 -k4,4 -s "$TMP/raw" > "$TMP/snapshot.new";fi
 mv "$TMP/snapshot.new" "$TMP/snapshot"
}
# -----------------------------------------
# The worker publishes tiny atomic progress records separately from logs.
# File progress counts sources processed, not bytes or remaining time.
# -----------------------------------------
progress_write() {
 [[ ${STREAM:-0} == 1 ]] || return
 printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${ENTRY_TOTAL:-0}" > "$TMP/progress.new"
 mv "$TMP/progress.new" "$TMP/progress"
}
# -----------------------------------------
# Capture each original source once. Count the captured records, then
# load them in batches. The cached text parser works on complete files.
# -----------------------------------------
collect() {
 : > "$TMP/raw"; : > "$TMP/diagnostics"
 local RECORDS=0 FILE_DONE=0 FILE_TOTAL=0 ENTRY_TOTAL=0
 local stream_saved=${STREAM:-0}
 progress_write capturing 0 0 0
 # Parse journal JSON in batches. Cursor-based refresh fetches only new events.
 local CAPTURING=1
 cat > "$TMP/journal-parser.awk" <<'AWK_JOURNAL'
# -----------------------------------------
# JSON lines from journalctl are decoded in one awk process. Handle
# strings, Unicode escapes and byte-array MESSAGE fields without jq.
# -----------------------------------------
function utf(n){if(n<128)return sprintf("%c",n);if(n<2048)return sprintf("%c%c",192+int(n/64),128+n%64);if(n<65536)return sprintf("%c%c%c",224+int(n/4096),128+int(n/64)%64,128+n%64);return sprintf("%c%c%c%c",240+int(n/262144),128+int(n/4096)%64,128+int(n/64)%64,128+n%64)}
function hex(s, n,i,c){n=0;for(i=1;i<=length(s);i++){c=index("0123456789abcdef",tolower(substr(s,i,1)))-1;n=n*16+c}return n}
function space(){while(substr(s,pos,1) ~ /[ \t\r\n]/ && pos<=length(s))pos++}
function string( out,c,n,low){out="";pos++;while(pos<=length(s)){c=substr(s,pos++,1);if(c=="\"")return out;if(c!="\\"){out=out c;continue}c=substr(s,pos++,1);if(c=="n")out=out "\n";else if(c=="t")out=out "\t";else if(c=="r")out=out "\r";else if(c=="b")out=out sprintf("%c",8);else if(c=="f")out=out sprintf("%c",12);else if(c=="u"){n=hex(substr(s,pos,4));pos+=4;if(n>=55296 && n<=56319 && substr(s,pos,2)=="\\u"){low=hex(substr(s,pos+2,4));if(low>=56320 && low<=57343){n=65536+(n-55296)*1024+low-56320;pos+=6}}out=out utf(n)}else out=out c}return out}
function value( c,out,v){space();c=substr(s,pos,1);if(c=="\"")return string();if(c=="["){pos++;out="";space();while(substr(s,pos,1)!="]" && pos<=length(s)){v=value();if(v ~ /^[0-9]+$/){if(v==0)out=out " ";else out=out sprintf("%c",v)}space();if(substr(s,pos,1)==",")pos++;else break}pos++;return out}if(c=="{"){pos++;while(pos<=length(s) && substr(s,pos,1)!="}"){space();string();space();pos++;value();space();if(substr(s,pos,1)==",")pos++;else break}pos++;return ""}out="";while(pos<=length(s) && substr(s,pos,1)!~/[,}\] \t]/)out=out substr(s,pos++,1);return out}
function esc(v, out,i,c){out="x";for(i=1;i<=length(v);i++){c=substr(v,i,1);if(c=="\\")out=out "\\\\";else if(c=="\n")out=out "\\n";else if(c=="\t")out=out "\\t";else if(c=="\r")out=out "\\r";else out=out c}return out}
BEGIN{split("emergency alert critical error warning notice info debug",lev," ");count=0;preview=ENVIRON["JOURNAL_PREVIEW"];cursorfile=ENVIRON["JOURNAL_CURSOR"]}
/^-- cursor: /{if(cursorfile!=""){print substr($0,12)>cursorfile;close(cursorfile)}next}
/^\{/ {
 s=$0;pos=2;t="";p=6;u="journal";identifier="";msg="";have=0
 while(pos<=length(s)){space();if(substr(s,pos,1)=="}")break;k=string();space();pos++;v=value();if(k=="__REALTIME_TIMESTAMP")t=v;else if(k=="PRIORITY")p=v;else if(k=="_SYSTEMD_UNIT")u=v;else if(k=="SYSLOG_IDENTIFIER")identifier=v;else if(k=="MESSAGE"){msg=v;have=1}space();if(substr(s,pos,1)==",")pos++;else break}
 if(t !~ /^[0-9]+$/)next;if(u=="journal" && identifier!="")u=identifier;if(p!~/^[0-7]$/)p=6
 if(!have)msg="[No MESSAGE field in this journal record]";else if(msg=="")msg="[Empty MESSAGE field in this journal record]"
 row=sprintf("%.0f\tjournal\t%s\t%s\tno\t%s",t/1000000,lev[p+1],esc(u),esc(msg));print row;count++
 if(preview!="" && count==1){print row>preview ".new";close(preview ".new");system("mv " preview ".new " preview)}
}
AWK_JOURNAL
 local -a journal_args=(--no-pager -o json --all --show-cursor --output-fields=__REALTIME_TIMESTAMP,MESSAGE,PRIORITY,_SYSTEMD_UNIT,SYSLOG_IDENTIFIER)
 ((LIMIT==0)) || journal_args+=(-n "$LIMIT")
 local cursor='' journal_success=1
 rm -f "$TMP/cursor.new"
 if [[ -s $CACHE/journal.cursor && -f $CACHE/journal.rows ]];then
  IFS= read -r cursor < "$CACHE/journal.cursor"
  [[ -z $cursor ]] || journal_args+=(--after-cursor="$cursor")
 fi
 if command -v journalctl >/dev/null;then
  if ! journalctl "${journal_args[@]}" 2>> "$TMP/diagnostics" | LC_ALL=C JOURNAL_PREVIEW="${STREAM:+$TMP/snapshot}" JOURNAL_CURSOR="$TMP/cursor.new" awk "${AWK_JOURNAL_FLAGS[@]}" -f "$TMP/journal-parser.awk" > "$TMP/journal.delta";then
   # A rotated/vacuumed cursor may be invalid: rebuild that source in full.
   cursor='';journal_args=(--no-pager -o json --all --show-cursor --output-fields=__REALTIME_TIMESTAMP,MESSAGE,PRIORITY,_SYSTEMD_UNIT,SYSLOG_IDENTIFIER)
   ((LIMIT==0)) || journal_args+=(-n "$LIMIT")
   journalctl "${journal_args[@]}" 2>> "$TMP/diagnostics" | LC_ALL=C JOURNAL_PREVIEW="$TMP/snapshot" JOURNAL_CURSOR="$TMP/cursor.new" awk "${AWK_JOURNAL_FLAGS[@]}" -f "$TMP/journal-parser.awk" > "$TMP/journal.delta" || journal_success=0
  fi
  sort -t $'\t' -k1,1nr -k2,2 -k4,4 -s "$TMP/journal.delta" > "$TMP/journal.sorted"
  if ((journal_success==0)) && [[ -f $CACHE/journal.rows ]];then
   cp "$CACHE/journal.rows" "$TMP/raw"
  elif [[ -n $cursor && -f $CACHE/journal.rows ]];then
   sort -m -t $'\t' -k1,1nr -k2,2 -k4,4 -s "$CACHE/journal.rows" "$TMP/journal.sorted" > "$TMP/raw"
  else cp "$TMP/journal.sorted" "$TMP/raw";fi
  if ((journal_success));then
   cp "$TMP/raw" "$CACHE/journal.rows"
   [[ ! -s $TMP/cursor.new ]] || cp "$TMP/cursor.new" "$CACHE/journal.cursor"
  fi
 else echo 'journalctl unavailable; file logs only.' >> "$TMP/diagnostics";fi
 RECORDS=$(awk 'END{print NR+0}' "$TMP/raw")
 CAPTURING=0
 STREAM=$stream_saved
 mv "$TMP/raw" "$TMP/journal.rows";: > "$TMP/raw"
 local journal_total=$RECORDS
 ENTRY_TOTAL=$journal_total
 local file key cached signature reference snapshot count line
 local -a paths=() snapshots=() caches=() signatures=() refs=() counts=()
 find "$LOGDIR" "${EXTRA_DIRS[@]}" -type f -print0 2>> "$TMP/diagnostics" > "$TMP/files"
 while IFS= read -r -d '' file;do
  [[ -r $file && $file != */journal/* && $file != */private/* ]] || continue
  if [[ $file =~ \.[0-9]+(\.gz)?$ || $file == *.gz ]];then ((ROTATED)) || continue;fi
  ((LIMIT==0 || ENTRY_TOTAL<LIMIT)) || break
  key=$(printf '%s' "$file" | cksum);key=${key// /_};cached="$CACHE/$key"
  signature=$(stat -c '%d:%i:%s:%y:%z' -- "$file") || continue;signature+="|$LIMIT"
  reference=$(stat -c %Y -- "$file") || continue
  snapshot="$TMP/capture.${#paths[@]}"
  if [[ -f $cached.signature && $(cat "$cached.signature") == "$signature" ]];then
   snapshot="$cached.rows";count=$(awk 'END{print NR+0}' "$snapshot")
  else
   if [[ $file == *.gz ]];then
    command -v gzip >/dev/null || continue
    gzip -cd -- "$file" > "$snapshot" 2>> "$TMP/diagnostics"
   else cat -- "$file" > "$snapshot" 2>> "$TMP/diagnostics";fi
   if head -c 4096 -- "$snapshot" | od -An -tu1 | awk '{for(i=1;i<=NF;i++)if($i==0)found=1}END{exit !found}';then rm -f "$snapshot";continue;fi
   if ((LIMIT>0));then tail -n "$((LIMIT-ENTRY_TOTAL))" "$snapshot" > "$snapshot.tail";mv "$snapshot.tail" "$snapshot";fi
   count=$(awk 'length($0)>0{n++}END{print n+0}' "$snapshot")
  fi
  paths+=("$file");snapshots+=("$snapshot");caches+=("$cached");signatures+=("$signature");refs+=("$reference");counts+=("$count")
  ENTRY_TOTAL=$((ENTRY_TOTAL+count));progress_write capturing "${#paths[@]}" 0 "$journal_total"
 done < "$TMP/files"
 FILE_TOTAL=${#paths[@]};RECORDS=0
 progress_write journal 0 "$FILE_TOTAL" 0
 # Load the captured journal without decoding and re-encoding its strings.
 cat "$TMP/journal.rows" >> "$TMP/raw";RECORDS=$journal_total
 publish_partial;progress_write journal 0 "$FILE_TOTAL" "$RECORDS"
 cat > "$TMP/text-parser.awk" <<'AWK_TEXT'
# -----------------------------------------
# Parse a whole captured text file in one awk process. mktime handles
# local dates; explicit offsets use calendar arithmetic in UTC.
# -----------------------------------------
function esc(s, out,i,c){out="x";for(i=1;i<=length(s);i++){c=substr(s,i,1);if(c=="\\")out=out "\\\\";else if(c=="\t")out=out "\\t";else if(c=="\r")out=out "\\r";else out=out c}return out}
function leap(y){return y%4==0 && (y%100!=0 || y%400==0)}
function epoch(y,m,d,h,mi,se,zone, days,i,sg,zh,zm){
 if(y<1970 || m<1 || m>12 || d<1 || d>md[m]+(m==2 && leap(y)) || h>23 || mi>59 || se>59)return -1
 if(zone=="")return mktime(sprintf("%d %d %d %d %d %d",y,m,d,h,mi,se))
 days=365*(y-1970)+int((y-1)/4)-int(1969/4)-int((y-1)/100)+int(1969/100)+int((y-1)/400)-int(1969/400)
 for(i=1;i<m;i++)days+=md[i]+(i==2 && leap(y))
 days+=d-1
 if(zone=="Z")return days*86400+h*3600+mi*60+se
 sg=substr(zone,1,1)=="-"?-1:1;gsub(/:/,"",zone);zh=substr(zone,2,2)+0;zm=substr(zone,4,2)+0
 if(zh>23 || zm>59)return -1
 return days*86400+h*3600+mi*60+se-sg*(zh*3600+zm*60)
}
BEGIN{split("31 28 31 30 31 30 31 31 30 31 30 31",md," ");split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec",mn," ");for(i=1;i<=12;i++)months[mn[i]]=i;year=strftime("%Y",reference);unit=esc(ENVIRON["LOGDESK_PARSE_PATH"])}
length($0)>0{
 line=$0;t=-1;inf="no";stamp=line;sub(/^\[/,"",stamp)
 if(match(stamp,/^[0-9][0-9][0-9][0-9][-\/][0-9][0-9][-\/][0-9][0-9][T ][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)){
  datepart=substr(stamp,1,19);zone=substr(stamp,20);sub(/^[.,][0-9]+/,"",zone)
  if(match(zone,/^(Z|[+-][0-9][0-9]:?[0-9][0-9])/))zone=substr(zone,RSTART,RLENGTH);else zone=""
  t=epoch(substr(datepart,1,4)+0,substr(datepart,6,2)+0,substr(datepart,9,2)+0,substr(datepart,12,2)+0,substr(datepart,15,2)+0,substr(datepart,18,2)+0,zone)
 }else if(match(line,/\[[0-9][0-9]\/[A-Za-z][A-Za-z][A-Za-z]\/[0-9][0-9][0-9][0-9]:[0-9][0-9]:[0-9][0-9]:[0-9][0-9] [+-][0-9][0-9][0-9][0-9]\]/)){
  stamp=substr(line,RSTART+1,RLENGTH-2);t=epoch(substr(stamp,8,4)+0,months[substr(stamp,4,3)],substr(stamp,1,2)+0,substr(stamp,13,2)+0,substr(stamp,16,2)+0,substr(stamp,19,2)+0,substr(stamp,22))
 }else if(match(line,/^[A-Z][a-z][a-z] +[0-9][0-9]? +[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)){
  stamp=substr(line,1,RLENGTH);split(stamp,a,/ +/);split(a[3],clock,":");t=epoch(year+0,months[a[1]],a[2]+0,clock[1]+0,clock[2]+0,clock[3]+0,"")
  if(t>reference+86400)t=epoch(year-1,months[a[1]],a[2]+0,clock[1]+0,clock[2]+0,clock[3]+0,"");if(t>=0)inf="yes"
 }
 low=tolower(line);sev="unknown"
 if(low ~ /critical|fatal|panic/)sev="critical*";else if(low ~ /error|failed|failure/)sev="error*";else if(low ~ /warning|warn/)sev="warning*";else if(low ~ /debug/)sev="debug*";else if(low ~ /info/)sev="info*"
 printf "%.0f\tfile\t%s\t%s\t%s\t%s\n",t,sev,unit,inf,esc(line)
}
AWK_TEXT
 local n rowfile
 local -a merge_sources=("$TMP/journal.rows")
 for n in "${!paths[@]}";do
  file=${paths[n]};cached=${caches[n]};snapshot=${snapshots[n]};rowfile="$cached.new"
  progress_write parsing "$FILE_DONE" "$FILE_TOTAL" "$RECORDS"
  if [[ $snapshot == "$cached.rows" ]];then rowfile=$snapshot
  else
   LOGDESK_PARSE_PATH="$file" awk -v reference="${refs[n]}" -f "$TMP/text-parser.awk" "$snapshot" > "$rowfile"
  fi
  # Sort each text batch once; the journal batch is already sorted.
  sort -t $'\t' -k1,1nr -k2,2 -k4,4 -s "$rowfile" > "$TMP/source.$n.sorted"
  merge_sources+=("$TMP/source.$n.sorted")
  cat "$rowfile" >> "$TMP/raw";RECORDS=$((RECORDS+counts[n]))
  if [[ $rowfile != "$cached.rows" ]];then
   if [[ "$(stat -c '%d:%i:%s:%y:%z' -- "$file" 2>/dev/null)|$LIMIT" == "${signatures[n]}" ]];then
    mv "$rowfile" "$cached.rows";printf '%s' "${signatures[n]}" > "$cached.signature"
   else rm -f "$rowfile";fi
   rm -f "$snapshot"
  fi
  ((FILE_DONE++));progress_write files "$FILE_DONE" "$FILE_TOTAL" "$RECORDS";publish_partial
 done
 progress_write sorting "$FILE_DONE" "$FILE_TOTAL" "$RECORDS"
 sort -m -t $'\t' -k1,1nr -k2,2 -k4,4 -s "${merge_sources[@]}" > "$TMP/data"
 progress_write done "$FILE_DONE" "$FILE_TOTAL" "$RECORDS"
}
# -----------------------------------------
# Store the full dataset on disk. awk builds a filtered result plus sparse
# byte offsets; Bash decodes only the visible page. Reuse unchanged filters.
# -----------------------------------------
DATA_VERSION=0 TOTAL_COUNT=0 MATCH_COUNT=0 FILTER_KEY=''
load() {
 if [[ $source_filter != all || -n $level_filter$unit_filter$start_filter$end_filter$keyword_filter ]];then
  TOTAL_COUNT=$(awk 'END{print NR+0}' "$TMP/data")
 fi
 ((DATA_VERSION++));FILTER_KEY='' 
}
source_filter=all level_filter='' unit_filter='' start_filter='' end_filter='' keyword_filter=''
LIMIT_LABEL=all;((LIMIT==0)) || LIMIT_LABEL=$LIMIT
sort_field=date sort_order=desc
auto=0 selected=0 offset=0 status='Ready. f: Filters | Enter: Details | ?: Help'
# -----------------------------------------
# Sort the filtered disk table by a chosen column. Severity uses priority
# rank, not alphabetical order. Unknown dates/severities stay at the end.
# -----------------------------------------
sort_rows() {
 local input=$1 output=$2 direction='' key
 [[ $sort_order != desc ]] || direction=r
 case $sort_field in
 date)
  awk -F '\t' '{print ($1<0?1:0) "\t" $0}' "$input" |
   sort -t $'\t' -k1,1n -k2,2n"$direction" -k3,3 -k5,5 -s | cut -f2- > "$output";;
 severity)
  awk -F '\t' 'BEGIN{split("emergency alert critical error warning notice info debug",a," ");for(i=1;i<=8;i++)rank[a[i]]=i-1}
  {v=$3;sub(/\*$/,"",v);r=(v in rank)?rank[v]:8;print (r==8?1:0) "\t" r "\t" $0}' "$input" |
   sort -t $'\t' -k1,1n -k2,2n"$direction" -k3,3nr -s | cut -f3- > "$output";;
 source|unit|message)
  case $sort_field in source) key=2;;unit) key=4;;message) key=6;;esac
  sort -t $'\t' -k"$key,$key"f"$direction" -k1,1nr -s "$input" > "$output";;
 esac
}
filter() {
 local start='' end='' cachekey
 cachekey="$DATA_VERSION|$sort_field|$sort_order|$source_filter|$level_filter|$unit_filter|$start_filter|$end_filter|$keyword_filter"
 [[ $FILTER_KEY != "$cachekey" ]] || return
 [[ -z $start_filter ]] || start=$(date -d "$start_filter" +%s)
 [[ -z $end_filter ]] || end=$(date -d "$end_filter" +%s)
 # With no conditions, share the snapshot instead of copying/refiltering it.
 local unfiltered=0
 if [[ $source_filter == all && -z $level_filter$unit_filter$start_filter$end_filter$keyword_filter ]];then
  unfiltered=1;rm -f "$TMP/filtered"
  if [[ $sort_field == date && $sort_order == desc ]];then ln "$TMP/data" "$TMP/filtered";else sort_rows "$TMP/data" "$TMP/filtered";fi
 else
 LOGDESK_SOURCE="$source_filter" LOGDESK_LEVEL="$level_filter" LOGDESK_UNIT="$unit_filter" LOGDESK_WORD="$keyword_filter" awk -F '\t' -v start="$start" -v end="$end" '
 function decode(v, o,i,c){o="";for(i=2;i<=length(v);i++){c=substr(v,i,1);if(c=="\\"){c=substr(v,++i,1);if(c=="n")c="\n";else if(c=="t")c="\t";else if(c=="r")c="\r"}o=o c}return o}
 BEGIN{source=ENVIRON["LOGDESK_SOURCE"];level=ENVIRON["LOGDESK_LEVEL"];unit=tolower(ENVIRON["LOGDESK_UNIT"]);word=tolower(ENVIRON["LOGDESK_WORD"])}
 {sev=$3;sub(/\*$/,"",sev);if(source!="all" && source!=$2)next;if(level!="" && sev!=level)next;if(start!="" && $1<start)next;if(end!="" && ($1<0 || $1>end))next
 if(unit!="" || word!=""){u=tolower(decode($4));if(unit!="" && !index(u,unit))next;if(word!="" && !index(tolower(decode($6)) " " u,word))next}print}
 ' "$TMP/data" > "$TMP/filtered.new"
 rm -f "$TMP/filtered"
 if [[ $sort_field == date && $sort_order == desc ]];then mv "$TMP/filtered.new" "$TMP/filtered";else sort_rows "$TMP/filtered.new" "$TMP/filtered";fi
 fi
 # Sparse byte offsets every 256 records let a page start near its target.
 LC_ALL=C awk 'NR%256==1{printf "%.0f\n",offset}{offset+=length($0)+1}END{print NR+0 > countfile}' countfile="$TMP/count" "$TMP/filtered" > "$TMP/page.index"
 IFS= read -r MATCH_COUNT < "$TMP/count";((!unfiltered)) || TOTAL_COUNT=$MATCH_COUNT
 mapfile -t PAGE_INDEX < "$TMP/page.index"
 FILTER_KEY=$cachekey;selected=0;offset=0;PAGE_KEY=''
}
page_load() {
 local key="$DATA_VERSION|$FILTER_KEY|$offset|$PAGE" byte block skip line ts src sev unit inf msg pos
 [[ ${PAGE_KEY:-} != "$key" ]] || return
 times=();sources=();sevs=();units=();inferred=();messages=();view=()
 block=$((offset/256));byte=${PAGE_INDEX[block]:-0};skip=$((offset%256));pos=$offset
 while IFS=$'\t' read -r ts src sev unit inf msg;do
  times[pos]=$ts;sources[pos]=$src;sevs[pos]=$sev;decode "$unit";units[pos]=$REPLY;inferred[pos]=$inf;decode "$msg";messages[pos]=$REPLY;view[pos]=$pos;((pos++))
 done < <(tail -c "+$((byte+1))" "$TMP/filtered" | awk -v skip="$skip" -v n="$PAGE" 'NR>skip{print;if(++count>=n)exit}')
 PAGE_KEY=$key
}
# -----------------------------------------
# Background jobs write a private snapshot. The UI keeps the old data
# until a complete new snapshot is ready; filters remain interactive.
# -----------------------------------------
refresh_start() {
 [[ -z $WORKER ]] || return
 mkdir -p "$TMP/pending";rm -f "$TMP/pending/ready" "$TMP/pending/progress"
 LOADING_DISMISSED=0
 PROGRESS_PHASE=counting;PROGRESS_DONE=0;PROGRESS_TOTAL=0;PROGRESS_RECORDS=0;PROGRESS_ENTRIES=0
 (trap - EXIT INT TERM; TMP="$TMP/pending";STREAM=1;collect;publish_partial; : > "$TMP/ready") & WORKER=$!
 DIRTY=1
 status='Collecting in background; navigation and filters remain available.'
}
PROGRESS_PHASE=counting PROGRESS_DONE=0 PROGRESS_TOTAL=0 PROGRESS_RECORDS=0 PROGRESS_ENTRIES=0 PROGRESS_LAST=''
refresh_poll() {
 [[ -n $WORKER ]] || return
 if [[ -f $TMP/pending/progress ]];then
  local progress_line
  IFS= read -r progress_line < "$TMP/pending/progress"
  if [[ $progress_line != "$PROGRESS_LAST" ]];then
   IFS=$'\t' read -r PROGRESS_PHASE PROGRESS_DONE PROGRESS_TOTAL PROGRESS_RECORDS PROGRESS_ENTRIES <<< "$progress_line"
   PROGRESS_LAST=$progress_line;DIRTY=1
  fi
 fi
 if [[ -f $TMP/pending/snapshot ]];then
 mv "$TMP/pending/snapshot" "$TMP/data"
 local saved=$selected
 load;filter;selected=$saved;DIRTY=1;status="Loaded ${TOTAL_COUNT} entries; collecting remaining sources..."
 fi
 if [[ -f $TMP/pending/ready ]];then
 wait "$WORKER";WORKER=''
 mv "$TMP/pending/data" "$TMP/data";cp "$TMP/pending/diagnostics" "$TMP/diagnostics"
 local saved=$selected
 load;filter;selected=$saved;DIRTY=1;status='Loaded available logs. Sorted by date, then source and unit/file. ?: diagnostics.'
 if ((${TOTAL_COUNT}==0));then status='No entries collected. Press ? for errors; protected logs may need sudo.';fi
 last=$SECONDS
 elif ! kill -0 "$WORKER" 2>/dev/null;then
 wait "$WORKER";WORKER='';status='Collector stopped unexpectedly. Press ? for diagnostics.'
 cp "$TMP/pending/diagnostics" "$TMP/diagnostics" 2>/dev/null || :
 fi
}
if ((DUMP));then collect;cat "$TMP/data";exit;fi
[[ -t 0 && -t 1 ]] || { echo 'Interactive mode needs a terminal.' >&2;exit 1; }
: > "$TMP/data";load;filter;refresh_start
printf '\e[?1049h\e[?25l';ACTIVE=1
# -----------------------------------------
# ANSI sequences draw the interface. Each frame is composed in memory
# and written once; no clear command is used during normal redraws.
# -----------------------------------------
color() {
 case ${1%\*} in emergency|alert|critical) COLOR=35;;error) COLOR=31;;warning) COLOR=33;;notice) COLOR=36;;info) COLOR=32;;debug) COLOR=34;;*) COLOR=37;;esac
}
RESIZE=1
trap 'RESIZE=1;DIRTY=1' WINCH
size() { if ((RESIZE));then H=$(tput lines);W=$(tput cols);RESIZE=0;fi; }
FRAME=''
put() {
 local row=$1 col=$2 text=$3 attr=${4:-0} width=${5:-$((W-col))}
 ((width>0)) || return
 safe "$text";text=${REPLY:0:width}
 printf -v piece '\e[%s;%sH\e[%sm%s\e[0m' "$((row+1))" "$((col+1))" "$attr" "$text";FRAME+=$piece
}
box() {
 local y=$1 x=$2 h=$3 w=$4 title=$5 bar i
 printf -v bar '%*s' "$((w-2))" '';bar=${bar// /─}
 put "$y" "$x" "┌${bar}┐" 36 "$w"
 for ((i=1;i<h-1;i++));do put "$((y+i))" "$x" '│' 36;put "$((y+i))" "$((x+w-1))" '│' 36;done
 put "$((y+h-1))" "$x" "└${bar}┘" 36 "$w";put "$y" "$((x+2))" " $title " 36 "$((w-4))"
}
blank() { local y=$1 x=$2 h=$3 w=$4 line i;printf -v line '%*s' "$w" '';for ((i=0;i<h;i++));do put "$((y+i))" "$x" "$line" 0 "$w";done; }
key() {
 KEY='';local extra
 IFS= read -rsn1 -t "${1:-0.5}" KEY || return
 if [[ $KEY == $'\e' ]];then
 IFS= read -rsn1 -t .05 extra || { KEY=ESC;return; };KEY+=$extra
 if [[ $extra == '[' || $extra == O ]];then
 while IFS= read -rsn1 -t .01 extra;do KEY+=$extra;[[ $extra =~ [A-Za-z~] ]] && break;done
 fi
 case $KEY in $'\e[A'|$'\eOA') KEY=UP;;$'\e[B'|$'\eOB') KEY=DOWN;;$'\e[C'|$'\eOC') KEY=RIGHT;;$'\e[D'|$'\eOD') KEY=LEFT;;$'\e[5~') KEY=PGUP;;$'\e[6~') KEY=PGDN;;$'\e[Z') KEY=BACKTAB;;*) KEY=ESC;;esac
 elif [[ -z $KEY ]];then KEY=ENTER
 elif [[ $KEY == $'\t' ]];then KEY=TAB
 elif [[ $KEY == $'\177' || $KEY == $'\b' ]];then KEY=BACKSPACE
 fi
}
draw() {
 size;FRAME=$'\e[H'
 blank 0 0 "$H" "$W"
 if ((H<22 || W<100));then put 0 0 'Resize to at least 100 columns x 22 rows. q: Quit';return;fi
 PAGE=$((H-17));local count=${MATCH_COUNT} pos i stamp attr label x=2
 ((selected<0)) && selected=0;((selected>=count)) && selected=$((count>0?count-1:0))
 ((selected<offset)) && offset=$selected;((selected>=offset+PAGE)) && offset=$((selected-PAGE+1))
 page_load
 box 0 0 3 "$W" 'LOGDESK BASH 4.4 | Teo Espero'
 put 1 2 "${MATCH_COUNT} matching / ${TOTAL_COUNT} collected | Limit: ${LIMIT_LABEL:-all} | Sort: $sort_field / $sort_order | Auto: $auto"
 box 3 0 3 "$W" Filters
 put 4 2 "Source=$source_filter | Severity=${level_filter:-any} | Unit=$unit_filter | From=$start_filter | Through=$end_filter | Keyword=$keyword_filter"
 # -----------------------------------------
 # Column headers use the same widths as the log rows, so each label
 # sits directly above its data instead of being combined in the border.
 # -----------------------------------------
 box 6 0 "$((PAGE+3))" "$W" 'Log entries'
 printf -v column_header '%-19s %-10s %-20s %s' 'Date / Time' 'Severity' 'Unit / File' 'Message'
 put 7 2 "$column_header" '1;36' "$((W-4))"
 for ((pos=offset;pos<count && pos<offset+PAGE;pos++));do
 i=${view[pos]};stamp='UNKNOWN TIME'
 ((times[i]<0)) || printf -v stamp '%(%Y-%m-%d %H:%M:%S)T' "${times[i]}"
 color "${sevs[i]}";attr=$COLOR;((pos==selected)) && attr="7;$COLOR"
 printf -v line '%-19s %-10s %-20.20s %s' "$stamp" "${sevs[i]}" "${units[i]##*/}" "${messages[i]}"
 put "$((8+pos-offset))" 2 "$line" "$attr" "$((W-4))"
 done
 box "$((H-8))" 0 3 "$W" 'Severity legend (* = inferred from words)'
 for label in critical error warning notice info debug unknown;do color "$label";put "$((H-7))" "$x" "$label" "$COLOR";x=$((x+${#label}+3));done
 box "$((H-5))" 0 3 "$W" 'Selected entry'
 if ((count));then i=${view[selected]};local preview="${units[i]} | ${messages[i]}"
 safe "$preview";preview=$REPLY
 if ((${#preview}>W-4));then preview="${preview:0:$((W-7))}...";fi
 put "$((H-4))" 2 "$preview" 0 "$((W-4))";fi
 if [[ -n $WORKER ]];then
 local pct=0 filled=0 bar rest
 if [[ $PROGRESS_PHASE == done ]];then pct=100
 elif ((PROGRESS_ENTRIES>0));then pct=$((PROGRESS_RECORDS*100/PROGRESS_ENTRIES));((pct<=99)) || pct=99;fi
 filled=$((pct*24/100));printf -v bar '%*s' "$filled" '';bar=${bar// /#}
 printf -v rest '%*s' "$((24-filled))" '';rest=${rest// /-}
 if [[ $PROGRESS_PHASE == capturing || $PROGRESS_PHASE == counting ]];then
 put "$((H-2))" 1 "Capturing / counting... | journal entries $PROGRESS_RECORDS | files captured $PROGRESS_DONE | total pending" 36
 else
 put "$((H-2))" 1 "Loading [$bar$rest] $pct% | $PROGRESS_PHASE | files $PROGRESS_DONE/$PROGRESS_TOTAL | entries $PROGRESS_RECORDS/$PROGRESS_ENTRIES" 36
 fi
 else put "$((H-2))" 1 "$status";fi
 put "$((H-1))" 1 'Up/Down PgUp/PgDn | Enter Details | f Filter | c Clear | r Refresh | a Auto | s Sort | e Export | ? Help | q Quit'
 # -----------------------------------------
 # Show a passive loading dialog while totals are being established.
 # It disappears automatically; Esc can dismiss it without stopping work.
 # -----------------------------------------
 if [[ -n $WORKER && ( $PROGRESS_PHASE == counting || $PROGRESS_PHASE == capturing ) ]] && (( !${LOADING_DISMISSED:-0} && !${UI_MODAL:-0} ));then
  local dw=66 dh=9 x=$(((W-66)/2)) y=$(((H-9)/2))
  local -a spin=('|' '/' '-' '\\')
  blank "$y" "$x" "$dh" "$dw";box "$y" "$x" "$dh" "$dw" '[ Information ] Loading logs'
  put "$((y+2))" "$((x+3))" "${spin[SECONDS%4]} Capturing and counting available entries..." '1;36' "$((dw-6))"
  put "$((y+4))" "$((x+3))" "Sources captured: $PROGRESS_DONE | Known entries: $PROGRESS_ENTRIES" 0 "$((dw-6))"
  put "$((y+5))" "$((x+3))" 'The progress percentage appears when the total is ready.' 0 "$((dw-6))"
  put "$((y+7))" "$((x+3))" 'Closes automatically. Esc: dismiss | q: quit' 33 "$((dw-6))"
 fi
}
# -----------------------------------------
# The modal dialog edits a copy. Choice fields use arrows/space; text
# fields support typing, Backspace and Ctrl+U. Apply validates date bounds.
# -----------------------------------------
# -----------------------------------------
# Edit sorting in a modal dialog; Cancel preserves the active order.
# -----------------------------------------
sort_dialog() {
 local UI_MODAL=1 focus=0 field_index=0 order_index=0 y x dw=70 dh=12 j attr
 local -a fields=(date severity source unit message)
 local -a labels=('Date / Time' 'Severity' 'Source' 'Unit / File' 'Message')
 for j in "${!fields[@]}";do [[ ${fields[j]} != "$sort_field" ]] || field_index=$j;done
 [[ $sort_order != desc ]] || order_index=1
 while :;do
 draw
 if ((H<22 || W<100));then printf '%s' "$FRAME";key;[[ $KEY == ESC ]] && return;continue;fi
 y=$(((H-dh)/2));x=$(((W-dw)/2));blank "$y" "$x" "$dh" "$dw";box "$y" "$x" "$dh" "$dw" '[ Sort ] Sort entries'
 put "$((y+2))" "$((x+3))" 'Field:' 0 12
 attr=36;((focus==0)) && attr='7;36';put "$((y+2))" "$((x+19))" "< ${labels[field_index]} >" "$attr" 45
 put "$((y+4))" "$((x+3))" 'Order:' 0 12
 attr=36;((focus==1)) && attr='7;36'
 local order_label=Ascending;((order_index==0)) || order_label=Descending
 put "$((y+4))" "$((x+19))" "< $order_label >" "$attr" 45
 put "$((y+6))" "$((x+3))" 'Severity ascending: emergency to debug; unknown last.' 0 64
 attr=32;((focus==2)) && attr='7;32';put "$((y+8))" "$((x+18))" '[ Apply ]' "$attr" 12
 attr=0;((focus==3)) && attr=7;put "$((y+8))" "$((x+38))" '[ Cancel ]' "$attr" 12
 put "$((y+10))" "$((x+3))" 'Tab/Up/Down: Move | Left/Right/Space: Choose | Esc: Cancel' 0 64
 printf '%s' "$FRAME";key
 case $KEY in
 ESC) status='Sort changes cancelled.';return;;
 TAB|DOWN) focus=$(((focus+1)%4));;
 BACKTAB|UP) focus=$(((focus+3)%4));;
 LEFT|RIGHT|' ')
 if ((focus==0));then
  if [[ $KEY == LEFT ]];then field_index=$(((field_index+4)%5));else field_index=$(((field_index+1)%5));fi
 elif ((focus==1));then order_index=$((1-order_index));fi;;
 ENTER)
 if ((focus<2));then ((focus++))
 elif ((focus==3));then status='Sort changes cancelled.';return
 else
  sort_field=${fields[field_index]};sort_order=asc;((order_index==0)) || sort_order=desc
  filter;status="Sorted by ${labels[field_index]} ($sort_order).";return
 fi;;
 esac
 done
}
dialog() {
 local UI_MODAL=1
 local values=("$source_filter" "$level_filter" "$unit_filter" "$start_filter" "$end_filter" "$keyword_filter")
 local labels=('Source' 'Severity' 'Log type / file' 'From' 'Through' 'Keyword') focus=0 error='' y x dh=18 dw=88 j attr val start end options index delta
 while :;do
 draw
 if ((H<22 || W<100));then printf '%s' "$FRAME";key;[[ $KEY == ESC ]] && return;continue;fi
 y=$(((H-dh)/2));x=$(((W-dw)/2));blank "$y" "$x" "$dh" "$dw"
 local dialog_title='[ Filters ] Filter logs'
 [[ -z $error ]] || dialog_title='[ Error ] Invalid filter'
 box "$y" "$x" "$dh" "$dw" "$dialog_title"
 put "$((y+1))" "$((x+2))" 'All fields combine. Apply saves; Cancel keeps the current filters.' 0 84
 for ((j=0;j<6;j++));do
 attr=36;((focus==j)) && attr='7;36';val=${values[j]};[[ -n $val ]] || val=''
 [[ $j == 1 && -z $val ]] && val=any
 put "$((y+3+j))" "$((x+2))" "${labels[j]}" 0 18
 printf -v val '%-62.62s' "${val: $(( ${#val}>62 ? ${#val}-62 : 0 ))}";put "$((y+3+j))" "$((x+22))" "$val" "$attr" 62
 done
 put "$((y+10))" "$((x+2))" 'Dates: YYYY-MM-DD HH:MM:SS. Date-only Through means midnight.' 0 84
 put "$((y+11))" "$((x+2))" 'Source/Severity: Left/Right/Space. Text: type, Backspace, Ctrl+U.' 0 84
 put "$((y+12))" "$((x+2))" "$error" 31 84
 attr=32;((focus==6)) && attr='7;32';put "$((y+14))" "$((x+25))" '[ Apply ]' "$attr" 10
 attr=0;((focus==7)) && attr=7;put "$((y+14))" "$((x+45))" '[ Cancel ]' "$attr" 10
 put "$((y+16))" "$((x+2))" 'Tab/Up/Down: Move | Enter: Next/Activate | Esc: Cancel' 0 84
 printf '%s' "$FRAME";key
 case $KEY in
 ESC) status='Filter changes cancelled.';return;;
 TAB|DOWN) focus=$(((focus+1)%8));;
 BACKTAB|UP) focus=$(((focus+7)%8));;
 ENTER)
 if ((focus==7));then status='Filter changes cancelled.';return;fi
 if ((focus<6));then ((focus++));continue;fi
 start='' end='' error=''
 [[ -z ${values[3]} ]] || start=$(date -d "${values[3]}" +%s 2>/dev/null) || error='Invalid From date/time.'
 [[ -z ${values[4]} ]] || end=$(date -d "${values[4]}" +%s 2>/dev/null) || error='Invalid Through date/time.'
 if [[ -z $error && -n $start && -n $end ]] && ((start>end));then error='From must precede Through.';fi
 [[ -z $error ]] || continue
 source_filter=${values[0]};level_filter=${values[1]};unit_filter=${values[2]};start_filter=${values[3]};end_filter=${values[4]};keyword_filter=${values[5]}
 filter;status='Filters applied.';return;;
 *)
 if ((focus==0 || focus==1));then
 if [[ $KEY == LEFT || $KEY == RIGHT || $KEY == ' ' ]];then
 if ((focus==0));then options=(all journal file);else options=('' "${levels[@]}");fi
 index=0;for j in "${!options[@]}";do [[ ${options[j]} == "${values[focus]}" ]] && index=$j;done
 delta=1;[[ $KEY == LEFT ]] && delta=-1
 index=$(((index+delta+${#options[@]})%${#options[@]}));values[focus]=${options[index]}
 fi
 elif ((focus<6));then
 case $KEY in BACKSPACE) values[focus]=${values[focus]%?};;$'\025') values[focus]='';;?) [[ $KEY == [[:print:]] ]] && values[focus]+=$KEY;;esac
 fi;;esac
 done
}
# -----------------------------------------
# Details covers the right half, leaving the list visible on the left.
# Fold long messages into display lines and allow vertical page scrolling.
# -----------------------------------------
details() {
 local UI_MODAL=1
 ((${MATCH_COUNT})) || return
 local i=${view[selected]} scroll=0 dw dh x y=3 page j pos
 local detail_title='[ Information ] Entry details'
 case ${sevs[i]%\*} in
 emergency|alert|critical|error) detail_title='[ Error ] Entry details';;
 warning) detail_title='[ Warning ] Entry details';;
 esac
 while :;do
 draw
 if ((H<22 || W<100));then printf '%s' "$FRAME";key;[[ $KEY == ESC || $KEY == ENTER ]] && return;continue;fi
 dw=$((W/2));dh=$((H-5));x=$((W-dw));page=$((dh-4))
 mapfile -t detail_lines < <({
 printf 'Time: %s\nSource: %s\nSeverity: %s\nUnit/file: %s\nYear inferred: %s\n\nMessage:\n%s\n' "$(if ((times[i]>=0));then date -d "@${times[i]}" --iso-8601=seconds;else echo Unknown;fi)" "${sources[i]}" "${sevs[i]}" "${units[i]}" "${inferred[i]}" "${messages[i]}"
 } | tr -d '\000-\010\013-\037\177' | fold -s -w "$((dw-4))")
 ((scroll<0)) && scroll=0;local max=$(( ${#detail_lines[@]}-page ));((max<0)) && max=0;((scroll>max)) && scroll=$max
 blank "$y" "$x" "$dh" "$dw";box "$y" "$x" "$dh" "$dw" "$detail_title"
 for ((j=0;j<page && scroll+j<${#detail_lines[@]};j++));do put "$((y+1+j))" "$((x+2))" "${detail_lines[scroll+j]}" 0 "$((dw-4))";done
 put "$((y+dh-2))" "$((x+2))" 'Up/Down PgUp/PgDn | Esc/Enter: Close' 0 "$((dw-4))"
 printf '%s' "$FRAME";key
 case $KEY in ESC|ENTER|q) return;;UP) ((scroll--));;DOWN) ((scroll++));;PGUP) scroll=$((scroll-page));;PGDN) scroll=$((scroll+page));;esac
 done
}
diagnostics() {
 local UI_MODAL=1
 local y=3 x=4 dw dh line j
 while :;do
 draw;dw=$((W-8));dh=$((H-6))
 if ((H>=22 && W>=100));then
 blank "$y" "$x" "$dh" "$dw";box "$y" "$x" "$dh" "$dw" '[ Information ] Collection diagnostics'
 local info=('Read-only. Default: all available entries from configured sources.' 'Sort: timestamp first, then log source and service/file for equal timestamps.' 'Unknown timestamps remain visible unless a date filter is applied.' 'Text severity and yearless syslog years are inferred.' 'Use sudo for protected system logs; --extra-dir adds another folder.' 'User logs: --user-logs (run without sudo to use your own home).' 'Collection errors:')
 j=0
 for line in "${info[@]}";do put "$((y+1+j))" "$((x+2))" "$line" 0 "$((dw-4))";((j++));done
 while IFS= read -r line && ((j<dh-3));do put "$((y+1+j))" "$((x+2))" "$line" 33 "$((dw-4))";((j++));done < "${TMP}/pending/diagnostics"
 put "$((y+dh-2))" "$((x+2))" 'Esc / Enter / q: Close' 0 "$((dw-4))"
 fi
 printf '%s' "$FRAME";key
 [[ $KEY == ESC || $KEY == ENTER || $KEY == q ]] && return
 done
}
csv() { local value=${1//\"/\"\"};printf '"%s"' "$value"; }
export_csv() {
 local UI_MODAL=1
 local path='' i stamp k
 # -----------------------------------------
 # Export accepts a literal path. Exclusive creation avoids overwriting
 # an existing file. CSV quotes preserve commas and embedded quotes.
 # -----------------------------------------
 while :;do draw;put "$((H-2))" 1 "Export NEW CSV path: $path";printf '%s' "$FRAME";key
 case $KEY in ESC) return;;ENTER) break;;BACKSPACE) path=${path%?};;?) [[ $KEY == [[:print:]] ]] && path+=$KEY;;esac;done
 [[ -n $path ]] || return
 if ! (set -o noclobber; : > "$path") 2>/dev/null;then status='Export failed: file exists or directory is not writable.';return;fi
 {
 echo 'timestamp,source,unit,severity,inferred_year,message'
 local ts src sev unit inf msg
 while IFS=$'\t' read -r ts src sev unit inf msg;do
 i=0;times[0]=$ts;sources[0]=$src;sevs[0]=$sev;decode "$unit";units[0]=$REPLY;inferred[0]=$inf;decode "$msg";messages[0]=$REPLY
 stamp='';((times[i]<0)) || stamp=$(date -d "@${times[i]}" --iso-8601=seconds)
 csv "$stamp";printf ',';csv "${sources[i]}";printf ',';csv "${units[i]}";printf ',';csv "${sevs[i]}";printf ',';csv "${inferred[i]}";printf ',';csv "${messages[i]}";printf '\n'
 done < "$TMP/filtered"
 } > "$path"
 PAGE_KEY=''
 status="Exported ${MATCH_COUNT} rows to $path"
}
last=$SECONDS
DIRTY=1
LOADING_TICK=-1
while :;do
 refresh_poll
 if [[ -n $WORKER && ( $PROGRESS_PHASE == counting || $PROGRESS_PHASE == capturing ) ]] && ((LOADING_TICK!=SECONDS));then LOADING_TICK=$SECONDS;DIRTY=1;fi
 if ((DIRTY));then draw;printf '%s' "$FRAME";DIRTY=0;fi
 key .15
 [[ -z $KEY ]] || DIRTY=1
 case $KEY in
 q) break;;
 ESC) LOADING_DISMISSED=1;;
 UP) ((selected--));;DOWN) ((selected++));;PGUP) selected=$((selected-PAGE));;PGDN) selected=$((selected+PAGE));;
 f) dialog;;ENTER) details;;

 c) source_filter=all;level_filter='';unit_filter='';start_filter='';end_filter='';keyword_filter='';filter;;
 s|S) sort_dialog;;a) auto=$((1-auto));;e) export_csv;;
 '?') diagnostics;;
 esac
 # -----------------------------------------
 # Request a background snapshot. Repeated requests share the active job.
 # Cache avoids rereading unchanged files; tail seeks for regular files.
 # -----------------------------------------
 if [[ $KEY == r ]] || ((auto && SECONDS-last>=15));then
 refresh_start
 fi
done

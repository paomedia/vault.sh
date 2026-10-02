#!/usr/bin/env bash
# vault.sh - self-contained bash password manager
# https://github.com/paomedia/vault.sh

set -uo pipefail
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "vault.sh: error: bash >= 4.4 is required (this is ${BASH_VERSION})" >&2
    exit 3
fi
: "${VAULT_ID:=}"

## === DATA BEGIN (do not edit by hand) ===
DB_BLOB=""
VAULT_ID="eea8a2794b64c5b9594a704aa0a8fd80"
## === DATA END ===

## === CONFIG BEGIN (you may edit by hand) ===
readonly VLT_VERSION="1.0"
readonly VLT_PERMISSIONS=700
readonly VLT_PERMISSIONS_MK=400
readonly VLT_CIPHER="aes-256-cbc"
readonly VLT_PBKDF2_ITER=200000
readonly VLT_CACHE_PREFIX="vault"
readonly VLT_CHARS_LOWER="abcdefghijklmnopqrstuvwxyz"
readonly VLT_CHARS_UPPER="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
readonly VLT_CHARS_SPECIAL='+*/()[]&_-'
readonly VLT_CHARS_NUM="0123456789"
readonly VLT_RULE_LEN=16
readonly VLT_RULE_LC=6
readonly VLT_RULE_UC=6
readonly VLT_RULE_SPEC=2
readonly VLT_RULE_NUM=2
readonly VLT_FS=$'\x1f'
## === CONFIG END ===

VLT_SELFNAME=""
VLT_SELFPATH=""
VLT_KEY=""
VLT_ACCOUNTS=""

vlt_init_paths() {
    VLT_SELFPATH="$(readlink -f "$0")"
    VLT_SELFNAME="$(basename "$VLT_SELFPATH")"
}

vlt_need() {
    local c
    for c in "$@"; do
        command -v "$c" > /dev/null 2>&1 && continue
        echo "${VLT_SELFNAME}: error: '$c' is required but not found in PATH" >&2
        exit 3
    done
}

vlt_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

vlt_norm() {
    local s
    s="$(vlt_trim "$1")"
    printf '%s' "${s,,}"
}

vlt_ask() {
    local -n _vlt_ask_out="$1"
    local _vlt_ask_v
    read -r -p "$2" _vlt_ask_v
    _vlt_ask_v="$(vlt_trim "$_vlt_ask_v")"
    [ "${4:-}" = lower ] && _vlt_ask_v="${_vlt_ask_v,,}"
    _vlt_ask_out="${_vlt_ask_v:-$3}"
}

vlt_confirm() {
    local answer
    read -r -p "$1 [y/n] ? " answer
    [ "$(vlt_norm "$answer")" = y ]
}

vlt_format_modified() {
    local v="$1"
    if [ -z "$v" ]; then
        printf 'n/a'
    elif [[ "$v" =~ ^[0-9]+$ ]]; then
        printf '%(%c)T' "$v"
    else
        printf '%s' "$v"
    fi
}

vlt_mk_prompt() {
    local mk
    echo -n "${1:-Enter \"${VLT_SELFNAME}\" master key: }" >&2
    { stty -echo < /dev/tty; } 2> /dev/null
    IFS= read -r mk
    { stty echo < /dev/tty; } 2> /dev/null
    echo >&2
    printf '%s' "$mk"
}

vlt_state_path() {
    local run_dir="/run/user/$EUID"
    if [ -d "$run_dir" ] && [ -w "$run_dir" ]; then
        printf '%s/%s' "$run_dir" "$1"
    else
        printf '%s/.%s' "$HOME" "$1"
    fi
}

vlt_mkrfile_path() {
    printf '/run/user/%s/%s-%s.mk' "$EUID" "$VLT_CACHE_PREFIX" "$VAULT_ID"
}

vlt_mkhfile_path() {
    printf '%s/.%s-%s.mk' "$HOME" "$VLT_CACHE_PREFIX" "$VAULT_ID"
}

vlt_reload_field() {
    local line
    line="$(grep -m1 "^$1=" "$VLT_SELFPATH" 2> /dev/null)" || return 0
    line="${line#"$1"=\"}"
    printf -v "$1" '%s' "${line%\"}"
}

vlt_reload_data() {
    vlt_reload_field DB_BLOB
    vlt_reload_field VAULT_ID
}

vlt_save_data() {
    local tmp
    if ! tmp="$(mktemp "${VLT_SELFPATH}.XXXXXX")" \
        || ! VLT_BLOB="$1" VLT_VID="$2" awk '
            /^## === DATA BEGIN/ {
                print
                print "DB_BLOB=\"" ENVIRON["VLT_BLOB"] "\""
                print "VAULT_ID=\"" ENVIRON["VLT_VID"] "\""
                skip = 1
                next
            }
            /^## === DATA END/ { skip = 0 }
            !skip
        ' "$VLT_SELFPATH" > "$tmp" \
        || ! chmod "$VLT_PERMISSIONS" "$tmp" \
        || ! mv "$tmp" "$VLT_SELFPATH"; then
        rm -f "$tmp"
        echo "${VLT_SELFNAME}: error: could not rewrite ${VLT_SELFPATH}, vault left unchanged" >&2
        return 1
    fi
    DB_BLOB="$1"
    VAULT_ID="$2"
}

vlt_ensure_vault_id() {
    vlt_reload_data
    [ -n "$VAULT_ID" ] && return
    vlt_need flock

    local bootfd hash
    hash="$(printf '%s' "$VLT_SELFPATH" | openssl dgst -sha256 -r | cut -c1-16)"
    exec {bootfd}> "$(vlt_state_path "${VLT_SELFNAME//[^a-zA-Z0-9_.-]/_}.${hash}.bootstrap.lock")"
    flock -x "$bootfd"
    vlt_reload_data
    if [ -z "$VAULT_ID" ]; then
        vlt_save_data "$DB_BLOB" "$(openssl rand -hex 16)" || exit 1
    fi
    exec {bootfd}>&-
}

vlt_lock_acquire() {
    vlt_need flock
    vlt_ensure_vault_id
    local lockfd
    exec {lockfd}> "$(vlt_state_path "${VLT_CACHE_PREFIX}-${VAULT_ID}.lock")"
    flock -x "$lockfd"
    vlt_reload_data
}

vlt_crypt() {
    VLT_MK="$1" openssl enc ${2:-} -"${VLT_CIPHER}" -pbkdf2 -iter "${VLT_PBKDF2_ITER}" \
        -salt -base64 -A -pass env:VLT_MK 2> /dev/null
}

vlt_unlock() {
    vlt_ensure_vault_id
    local mk="" plain="" f
    for f in "$(vlt_mkrfile_path)" "$(vlt_mkhfile_path)"; do
        [ -f "$f" ] && mk="$(head -n1 "$f")" && break
    done
    [ -n "$mk" ] || mk="$(vlt_mk_prompt)"
    if [ -n "$DB_BLOB" ] && ! plain="$(printf '%s' "$DB_BLOB" | vlt_crypt "$mk" -d \
            | LC_ALL=C awk -F"$VLT_FS" 'NF && (NF < 4 || NF > 5) { bad = 1 } 1; END { exit bad }')"; then
        echo "Bad key :(" >&2
        return 1
    fi
    VLT_KEY="$mk"
    VLT_ACCOUNTS="$plain"
}

vlt_save_accounts() {
    local blob
    if ! blob="$(printf '%s' "$1" | vlt_crypt "$VLT_KEY")" || [ -z "$blob" ]; then
        echo "${VLT_SELFNAME}: error: encryption failed, vault left unchanged" >&2
        return 1
    fi
    vlt_save_data "$blob" "$VAULT_ID"
}

vlt_record() {
    local IFS="$VLT_FS"
    printf -v "$1" '%s' "${*:2}"
}

vlt_find() {
    local line
    while IFS= read -r line; do
        if [ -n "$line" ] && [ "${line%%"$VLT_FS"*}" = "$2" ]; then
            printf '%s' "$line"
            return 0
        fi
    done <<< "$1"
    return 1
}

vlt_replace() {
    local line out=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ "${line%%"$VLT_FS"*}" = "$2" ]; then
            [ -n "${3:-}" ] || continue
            line="$3"
        fi
        out+="${out:+$'\n'}$line"
    done <<< "$1"
    printf '%s' "$out"
}

vlt_append() {
    if [ -n "$1" ]; then printf '%s\n%s' "$1" "$2"; else printf '%s' "$2"; fi
}

vlt_open_service() {
    target="$(vlt_norm "$2")"
    if [ -z "$target" ]; then
        echo "${VLT_SELFNAME} $1: please provide a SERVICE name"
        return 1
    fi
    vlt_lock_acquire
    vlt_unlock || return 1
    if ! old="$(vlt_find "$VLT_ACCOUNTS" "$target")"; then
        echo "${VLT_SELFNAME} $1: service \"$target\" not found"
        return 1
    fi
}

vlt_reject_duplicate() {
    vlt_find "$VLT_ACCOUNTS" "$1" > /dev/null || return 0
    echo "Service \"$1\" already registered"
    echo "Find a unique name or delete it."
    return 1
}

vlt_print_record() {
    local svc em un pw md
    IFS="$VLT_FS" read -r svc em un pw md <<< "$2"
    echo "$1"
    echo "  Name      $svc"
    echo "  E-mail    $em"
    echo "  Username  $un"
    echo "  Password  $pw"
    echo "  Modified  $(vlt_format_modified "$md")"
}

vlt_parse_dump_json() {
    jq -r --arg fs "$VLT_FS" '
        if (.accounts | type) != "array" then error("\"accounts\" is not an array") else . end
        | .accounts[]
        | if type == "array" and length == 5 and all(.[]; type == "string")
          then join($fs)
          else error("malformed row (expected 5 strings)")
          end
    '
}

vlt_pick() {
    local n="$1" charset="$2"
    [ "$n" -le 0 ] && return 0
    LC_ALL=C tr -dc "$charset" < /dev/urandom | head -c "$n"
}

vlt_gen_password() {
    local len="${1:-$VLT_RULE_LEN}" lc="${2:-$VLT_RULE_LC}" uc="${3:-$VLT_RULE_UC}"
    local spec="${4:-$VLT_RULE_SPEC}" num="${5:-$VLT_RULE_NUM}"
    local n ok=1 sum
    for n in "$len" "$lc" "$uc" "$spec" "$num"; do
        [[ "$n" =~ ^(0|[1-9][0-9]*)$ ]] || ok=0
    done
    (( ok )) && sum=$(( lc + uc + spec + num ))
    if (( ! ok )) || (( len < sum )); then
        echo "${VLT_SELFNAME}: error: bad password rules (non-negative integers, len >= lc+uc+spec+num)" >&2
        exit 2
    fi
    {
        vlt_pick "$lc" "$VLT_CHARS_LOWER"
        vlt_pick "$uc" "$VLT_CHARS_UPPER"
        vlt_pick "$spec" "$VLT_CHARS_SPECIAL"
        vlt_pick "$num" "$VLT_CHARS_NUM"
        vlt_pick $(( len - sum )) "$VLT_CHARS_LOWER"
    } | fold -w1 | shuf | tr -d '\n'
}

cmd_genpasswd() {
    vlt_gen_password "$@"
    echo
}

cmd_add() {
    vlt_lock_acquire
    vlt_unlock || return 1
    local service email username password record
    vlt_ask service "Service: " "n/a" lower
    vlt_reject_duplicate "$service" || return 1
    vlt_ask email "E-mail: " "n/a" lower
    vlt_ask username "Username: " "n/a"
    vlt_ask password "Password (leave blank to generate): " "$(vlt_gen_password)"
    vlt_record record "$service" "$email" "$username" "$password" "$(printf '%(%s)T')"
    vlt_save_accounts "$(vlt_append "$VLT_ACCOUNTS" "$record")" || return 1
    vlt_print_record "New service successfully added" "$record"
}

cmd_update() {
    local target old svc em un pw
    vlt_open_service update "${1:-}" || return 1
    IFS="$VLT_FS" read -r svc em un pw _ <<< "$old"
    local service email username password record
    vlt_ask service "Service [$svc]: " "$svc" lower
    [ "$service" = "$svc" ] || vlt_reject_duplicate "$service" || return 1
    vlt_ask email "E-mail [$em]: " "$em" lower
    vlt_ask username "Username [$un]: " "$un"
    vlt_ask password "Password [leave blank to keep current]: " "$pw"
    vlt_record record "$service" "$email" "$username" "$password" "$(printf '%(%s)T')"
    vlt_save_accounts "$(vlt_replace "$VLT_ACCOUNTS" "$svc" "$record")" || return 1
    vlt_print_record "Service successfully updated" "$record"
}

cmd_delete() {
    local target old
    vlt_open_service delete "${1:-}" || return 1
    vlt_save_accounts "$(vlt_replace "$VLT_ACCOUNTS" "$target")"
}

cmd_import() {
    if [ -t 0 ]; then
        echo "${VLT_SELFNAME} import: expects a decrypted dump (JSON) on stdin"
        echo "usage: /path/to/other-vault dump --decrypt | ${VLT_SELFNAME} import"
        echo "       ${VLT_SELFNAME} import < dump.json"
        return 1
    fi
    vlt_need jq

    local imported
    if ! imported="$(vlt_parse_dump_json)"; then
        echo "${VLT_SELFNAME} import: could not parse the JSON on stdin"
        return 1
    fi

    if ! ( exec < /dev/tty ) 2> /dev/null; then
        echo "${VLT_SELFNAME} import: no controlling terminal available for the master key/confirmation prompts" >&2
        return 1
    fi
    exec < /dev/tty

    if [ -z "$imported" ]; then
        echo "Nothing to import: source vault has no accounts"
        return 0
    fi

    vlt_lock_acquire
    vlt_unlock || return 1

    local -A have=()
    local svc rec new=() skipped=() list
    while IFS= read -r rec; do
        [ -n "$rec" ] && have["${rec%%"$VLT_FS"*}"]=1
    done <<< "$VLT_ACCOUNTS"
    while IFS= read -r rec; do
        svc="${rec%%"$VLT_FS"*}"
        if [ -n "${have[$svc]:-}" ]; then
            skipped+=("$svc")
        else
            have[$svc]=1
            new+=("$rec")
        fi
    done <<< "$imported"
    printf -v list '%s, ' "${skipped[@]}"
    list="${list%, }"

    if [ "${#new[@]}" -eq 0 ]; then
        echo "Nothing to import: all ${#skipped[@]} service(s) already registered ($list)"
        return 0
    fi

    echo "Found ${#new[@]} account(s) to import:"
    printf '  %s\n' "${new[@]%%"$VLT_FS"*}"
    [ "${#skipped[@]}" -gt 0 ] && echo "Skipping ${#skipped[@]} already-registered service(s): $list"

    if ! vlt_confirm "Import these ${#new[@]} account(s)"; then
        echo "${VLT_SELFNAME} import: operation aborted"
        return 1
    fi
    vlt_save_accounts "$(vlt_append "$VLT_ACCOUNTS" "$(printf '%s\n' "${new[@]}")")" || return 1
    echo "Imported ${#new[@]} account(s)"
}

vlt_mk_files() {
    case "$1" in
        -r|--ram)  vlt_mkrfile_path ;;
        -h|--home) vlt_mkhfile_path ;;
        "")        vlt_mkrfile_path; echo; vlt_mkhfile_path ;;
        *)         return 1 ;;
    esac
}

cmd_savemk() {
    local file
    vlt_ensure_vault_id
    if [ -z "${1:-}" ] || ! file="$(vlt_mk_files "$1")"; then
        echo "${VLT_SELFNAME}: use --ram or --home option"
        return 1
    fi

    vlt_unlock || return 1

    mkdir -p "$(dirname "$file")" 2> /dev/null
    if ! ( umask 077; printf '%s\n' "$VLT_KEY" > "$file" ) 2> /dev/null; then
        echo "${VLT_SELFNAME}: error while writing on \"$file\""
        return 2
    fi
    chmod "$VLT_PERMISSIONS_MK" "$file"
    echo "Master key saved in $file"
}

cmd_clearmk() {
    local files f removed=0
    vlt_reload_data
    if ! files="$(vlt_mk_files "${1:-}")"; then
        echo "${VLT_SELFNAME}: use --ram, --home, or no option to clear both"
        return 1
    fi
    if [ -n "$VAULT_ID" ]; then
        while IFS= read -r f; do
            [ -f "$f" ] && rm -f "$f" && removed=1
        done <<< "$files"
    fi

    if [ "$removed" -eq 1 ]; then
        echo "Master key cache cleared"
    else
        echo "No cached master key found"
    fi
}

cmd_dump() {
    case "${1:-}" in
        "")
            # base64: nothing to escape
            printf '{\n  "blob": "%s"\n}\n' "$DB_BLOB"
            return 0
            ;;
        --decrypt) ;;
        *)
            echo "${VLT_SELFNAME} dump: unknown option \"$1\""
            return 1
            ;;
    esac

    vlt_need jq
    vlt_unlock || return 1
    printf '%s' "$VLT_ACCOUNTS" | jq -Rn --arg fs "$VLT_FS" \
        '{accounts: [inputs | select(length > 0) | split($fs) | (. + [""])[0:5]]}'
}

vlt_show_row() {
    local force="$1" line="${gray}│${reset}" cell color pad i=0
    shift
    for cell in "$@"; do
        color="$force"
        if [ -z "$color" ]; then
            if [ "$cell" = "n/a" ]; then color="$gray"; elif [ "$i" -eq 0 ]; then color="$green"; fi
        fi
        printf -v pad '%*s' $(( widths[i] - ${#cell} )) ''
        line+=" ${color}${cell}${reset}${pad} ${gray}│${reset}"
        i=$(( i + 1 ))
    done
    printf '%s\n' "$line"
}

cmd_show() {
    local keyword
    keyword="$(vlt_norm "${1:-}")"

    if [ -n "$DB_BLOB" ]; then
        vlt_unlock || return 1
    fi
    if [ -z "$VLT_ACCOUNTS" ]; then
        echo "Account list is empty"
        return 0
    fi

    local headers=(SERVICE EMAIL USERNAME PASSWORD MODIFIED)
    local widths=() cells=() row=() i f0 f1 f2 f3 f4
    for i in 0 1 2 3 4; do
        widths[i]=${#headers[i]}
    done
    while IFS="$VLT_FS" read -r f0 f1 f2 f3 f4; do
        [ -n "$f0" ] && [[ "$f0" == *"$keyword"* ]] || continue
        row=("$f0" "$f1" "$f2" "$f3" "$(vlt_format_modified "$f4")")
        for i in 0 1 2 3 4; do
            (( ${#row[i]} > widths[i] )) && widths[i]=${#row[i]}
        done
        cells+=("${row[@]}")
    done < <(sort -f -t "$VLT_FS" -k1,1 <<< "$VLT_ACCOUNTS")

    if [ "${#cells[@]}" -eq 0 ]; then
        echo "\"$keyword\": no matches"
        return 1
    fi

    local gray="" blue="" green="" reset=""
    if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
        gray=$'\e[90m'
        blue=$'\e[34m'
        green=$'\e[32m'
        reset=$'\e[0m'
    fi

    local top="" mid="" bot="" seg r
    for i in 0 1 2 3 4; do
        printf -v seg '%*s' $(( widths[i] + 2 )) ''
        seg="${seg// /─}"
        top+="┬$seg"
        mid+="┼$seg"
        bot+="┴$seg"
    done

    echo "${gray}┌${top#┬}┐${reset}"
    vlt_show_row "$blue" "${headers[@]}"
    for (( r = 0; r < ${#cells[@]}; r += 5 )); do
        echo "${gray}├${mid#┼}┤${reset}"
        vlt_show_row "" "${cells[@]:r:5}"
    done
    echo "${gray}└${bot#┴}┘${reset}"
}

cmd_reset() {
    if ! vlt_confirm "${VLT_SELFNAME}: erase all data"; then
        echo "${VLT_SELFNAME} reset: operation aborted"
        return 1
    fi
    vlt_lock_acquire
    # Drop this vault's cached keys while VAULT_ID still names them.
    rm -f "$(vlt_mkrfile_path)" "$(vlt_mkhfile_path)"
    vlt_save_data "" "$(openssl rand -hex 16)"
}

cmd_version() {
    echo "vault.sh ${VLT_VERSION}"
    echo "location: ${VLT_SELFPATH}"
}

cmd_help() {
    cat <<EOF
vault.sh: bash command line password manager.
Accounts data is encrypted in source code itself.

USAGE
  ${VLT_SELFNAME} COMMAND [ARG]...

COMMANDS
  add                add new account
  clearmk [-r|-h]    remove cached master key (both if no option given)
  delete SERVICE     delete account by SERVICE name
  dump [--decrypt]   display database as json (--decrypt requires jq)
  genpasswd [...]    display a random generated password
  help, -h, --help   display this help and exit
  import             import accounts from a vault dump on stdin
  reset              erase database, reinit
  savemk -r|-h       save master key in ram or home for future use
  show [KEYWORD]     display accounts that match KEYWORD
  update SERVICE     update account fields (blank keeps current value)
  version            output version information and exit

IMPORT USAGE
  /path/to/other-vault dump --decrypt | ${VLT_SELFNAME} import
  ${VLT_SELFNAME} import < dump.json

SAVEMK USAGE
  ${VLT_SELFNAME} savemk -r|-h

  -r, --ram          save master key temporarily in ram
                     mk will be in /run/user/<uid>/${VLT_CACHE_PREFIX}-<vault-id>.mk
  -h, --home         save master key permanently
                     mk will be in ~/.${VLT_CACHE_PREFIX}-<vault-id>.mk

CLEARMK USAGE
  ${VLT_SELFNAME} clearmk [-r|-h]

  -r, --ram          remove only the ram-cached master key
  -h, --home         remove only the home-cached master key
  (no option)        remove both

GENPASSWD USAGE
  ${VLT_SELFNAME} genpasswd [LEN [LC [UC [SPEC [NUM]]]]]

  LEN                password length (default=${VLT_RULE_LEN})
  LC                 minimum lowercase chars (default=${VLT_RULE_LC})
  UC                 exact uppercase chars (default=${VLT_RULE_UC})
  SPEC               exact special chars (default=${VLT_RULE_SPEC})
  NUM                exact numerical chars (default=${VLT_RULE_NUM})
EOF
}

main() {
    vlt_init_paths

    local cmd="${1:-help}"
    [ "$#" -gt 0 ] && shift
    case "$cmd" in -h|--help) cmd=help ;; esac

    if declare -f "cmd_${cmd}" > /dev/null; then
        "cmd_${cmd}" "$@"
        exit $?
    fi

    echo "${VLT_SELFNAME}: ${cmd}: subcommand not found"
    echo "Try ${VLT_SELFNAME} help for more info."
    exit 1
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi

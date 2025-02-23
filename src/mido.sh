#!/usr/bin/env bash
set -Eeuo pipefail

handle_curl_error() {

  local error_code="$1"
  local server_name="$2"

  case "$error_code" in
    1) error "Unsupported protocol!" ;;
    2) error "Failed to initialize curl!" ;;
    3) error "The URL format is malformed!" ;;
    5) error "Failed to resolve address of proxy host!" ;;
    6) error "Failed to resolve $server_name servers! Is there an Internet connection?" ;;
    7) error "Failed to contact $server_name servers! Is there an Internet connection or is the server down?" ;;
    8) error "$server_name servers returned a malformed HTTP response!" ;;
    16) error "A problem was detected in the HTTP2 framing layer!" ;;
    22) error "$server_name servers returned a failing HTTP status code!" ;;
    23) error "Failed at writing Windows media to disk! Out of disk space or permission error?" ;;
    26) error "Failed to read Windows media from disk!" ;;
    27) error "Ran out of memory during download!" ;;
    28) error "Connection timed out to $server_name server!" ;;
    35) error "SSL connection error from $server_name server!" ;;
    36) error "Failed to continue earlier download!" ;;
    52) error "Received no data from the $server_name server!" ;;
    63) error "$server_name servers returned an unexpectedly large response!" ;;
    # POSIX defines exit statuses 1-125 as usable by us
    # https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_08_02
    $((error_code <= 125)))
      # Must be some other server or network error (possibly with this specific request/file)
      # This is when accounting for all possible errors in the curl manual assuming a correctly formed curl command and an HTTP(S) request, using only the curl features we're using, and a sane build
      error "Miscellaneous server or network error, reason: $error_code"
      ;;
    126 | 127 ) error "Curl command not found!" ;;
    # Exit statuses are undefined by POSIX beyond this point
    *)
      case "$(kill -l "$error_code")" in
        # Signals defined to exist by POSIX:
        # https://pubs.opengroup.org/onlinepubs/009695399/basedefs/signal.h.html
        INT) error "Curl was interrupted!" ;;
        # There could be other signals but these are most common
        SEGV | ABRT ) error "Curl crashed! Please report any core dumps to curl developers." ;;
        *) error "Curl terminated due to fatal signal $error_code !" ;;
      esac
  esac

  return 1
}

get_agent() {

  local user_agent

  # Determine approximate latest Firefox release
  browser_version="$((124 + ($(date +%s) - 1710892800) / 2419200))"
  echo "Mozilla/5.0 (X11; Linux x86_64; rv:${browser_version}.0) Gecko/20100101 Firefox/${browser_version}.0"

  return 0
}

download_windows() {

  local id="$1"
  local lang="$2"
  local desc="$3"
  local sku_id=""
  local sku_url=""
  local iso_url=""
  local iso_json=""
  local language=""
  local session_id=""
  local user_agent=""
  local download_type=""
  local windows_version=""
  local iso_download_link=""
  local download_page_html=""
  local product_edition_id=""
  local language_skuid_json=""
  local profile="606624d44113"

  user_agent=$(get_agent)
  language=$(getLanguage "$lang" "name")

  case "${id,,}" in
    "win11x64" ) windows_version="11" && download_type="1" ;;
    "win10x64" ) windows_version="10" && download_type="1" ;;
    "win11arm64" ) windows_version="11arm64" && download_type="2" ;;
    * ) error "Invalid VERSION specified, value \"$id\" is not recognized!" && return 1 ;;
  esac

  local url="https://www.microsoft.com/en-us/software-download/windows$windows_version"
  [[ "${id,,}" == "win10"* ]] && url+="ISO"

  # uuidgen: For MacOS (installed by default) and other systems (e.g. with no /proc) that don't have a kernel interface for generating random UUIDs
  session_id=$(cat /proc/sys/kernel/random/uuid 2> /dev/null || uuidgen --random)

  # Get product edition ID for latest release of given Windows version
  # Product edition ID: This specifies both the Windows release (e.g. 22H2) and edition ("multi-edition" is default, either Home/Pro/Edu/etc., we select "Pro" in the answer files) in one number
  # This is the *only* request we make that Fido doesn't. Fido manually maintains a list of all the Windows release/edition product edition IDs in its script (see: $WindowsVersions array). This is helpful for downloading older releases (e.g. Windows 10 1909, 21H1, etc.) but we always want to get the newest release which is why we get this value dynamically
  # Also, keeping a "$WindowsVersions" array like Fido does would be way too much of a maintenance burden
  # Remove "Accept" header that curl sends by default
  [[ "$DEBUG" == [Yy1]* ]] && echo "Parsing download page: ${url}"
  download_page_html=$(curl --silent --max-time 30 --user-agent "$user_agent" --header "Accept:" --max-filesize 1M --fail --proto =https --tlsv1.2 --http1.1 -- "$url") || {
    handle_curl_error "$?" "Microsoft"
    return $?
  }

  [[ "$DEBUG" == [Yy1]* ]] && echo -n "Getting Product edition ID: "
  product_edition_id=$(echo "$download_page_html" | grep -Eo '<option value="[0-9]+">Windows' | cut -d '"' -f 2 | head -n 1 | tr -cd '0-9' | head -c 16)
  [[ "$DEBUG" == [Yy1]* ]] && echo "$product_edition_id"

  if [ -z "$product_edition_id" ]; then
    error "Product edition ID not found!"
    return 1
  fi

  [[ "$DEBUG" == [Yy1]* ]] && echo "Permit Session ID: $session_id"
  # Permit Session ID
  curl --silent --max-time 30 --output /dev/null --user-agent "$user_agent" --header "Accept:" --max-filesize 100K --fail --proto =https --tlsv1.2 --http1.1 -- "https://vlscppe.microsoft.com/tags?org_id=y6jn8c31&session_id=$session_id" || {
    # This should only happen if there's been some change to how this API works
    handle_curl_error "$?" "Microsoft"
    return $?
  }

  [[ "$DEBUG" == [Yy1]* ]] && echo -n "Getting language SKU ID: "
  sku_url="https://www.microsoft.com/software-download-connector/api/getskuinformationbyproductedition?profile=$profile&ProductEditionId=$product_edition_id&SKU=undefined&friendlyFileName=undefined&Locale=en-US&sessionID=$session_id"
  language_skuid_json=$(curl --silent --max-time 30 --request GET --user-agent "$user_agent" --referer "$url" --header "Accept:" --max-filesize 100K --fail --proto =https --tlsv1.2 --http1.1 -- "$sku_url") || {
    handle_curl_error "$?" "Microsoft"
    return $?
  }

  { sku_id=$(echo "$language_skuid_json" | jq --arg LANG "$language" -r '.Skus[] | select(.Language==$LANG).Id') 2>/dev/null; rc=$?; } || :

  if [ -z "$sku_id" ] || [[ "${sku_id,,}" == "null" ]] || (( rc != 0 )); then
    language=$(getLanguage "$lang" "desc")
    error "No download in the $language language available for $desc!"
    return 1
  fi

  [[ "$DEBUG" == [Yy1]* ]] && echo "$sku_id"
  [[ "$DEBUG" == [Yy1]* ]] && echo "Getting ISO download link..."

  # Get ISO download link
  # If any request is going to be blocked by Microsoft it's always this last one (the previous requests always seem to succeed)

  iso_url="https://www.microsoft.com/software-download-connector/api/GetProductDownloadLinksBySku?profile=$profile&ProductEditionId=undefined&SKU=$sku_id&friendlyFileName=undefined&Locale=en-US&sessionID=$session_id"
  iso_json=$(curl --silent --max-time 30 --request GET --user-agent "$user_agent" --referer "$url" --header "Accept:" --max-filesize 100K --fail --proto =https --tlsv1.2 --http1.1 -- "$iso_url")

  if ! [ "$iso_json" ]; then
    # This should only happen if there's been some change to how this API works
    error "Microsoft servers gave us an empty response to our request for an automated download."
    return 1
  fi

  if echo "$iso_json" | grep -q "Sentinel marked this request as rejected."; then
    error "Microsoft blocked the automated download request based on your IP address."
    return 1
  fi

  if echo "$iso_json" | grep -q "We are unable to complete your request at this time."; then
    error "Microsoft blocked the automated download request based on your IP address."
    return 1
  fi

  { iso_download_link=$(echo "$iso_json" | jq --argjson TYPE "$download_type" -r '.ProductDownloadOptions[] | select(.DownloadType==$TYPE).Uri') 2>/dev/null; rc=$?; } || :

  if [ -z "$iso_download_link" ] || [[ "${iso_download_link,,}" == "null" ]] || (( rc != 0 )); then
    error "Microsoft servers gave us no download link to our request for an automated download!"
    info "Response: $iso_json"
    return 1
  fi

  MIDO_URL="$iso_download_link"
  return 0
}

download_windows_eval() {

  local id="$1"
  local lang="$2"
  local desc="$3"
  local filter=""
  local culture=""
  local language=""
  local user_agent=""
  local enterprise_type=""
  local windows_version=""

  case "${id,,}" in
    "win11${PLATFORM,,}-enterprise-eval" )
      enterprise_type="enterprise"
      windows_version="windows-11-enterprise" ;;
    "win11${PLATFORM,,}-enterprise-iot-eval" )
      enterprise_type="iot"
      windows_version="windows-11-iot-enterprise-ltsc-eval" ;;
    "win11${PLATFORM,,}-enterprise-ltsc-eval" )
      enterprise_type="iot"
      windows_version="windows-11-iot-enterprise-ltsc-eval" ;;
    "win10${PLATFORM,,}-enterprise-eval" )
      enterprise_type="enterprise"
      windows_version="windows-10-enterprise" ;;
    "win10${PLATFORM,,}-enterprise-ltsc-eval" )
      enterprise_type="ltsc"
      windows_version="windows-10-enterprise" ;;
    "win2025-eval" )
      enterprise_type="server"
      windows_version="windows-server-2025" ;;
    "win2022-eval" )
      enterprise_type="server"
      windows_version="windows-server-2022" ;;
    "win2019-eval" )
      enterprise_type="server"
      windows_version="windows-server-2019" ;;
    "win2016-eval" )
      enterprise_type="server"
      windows_version="windows-server-2016" ;;
    "win2012r2-eval" )
      enterprise_type="server"
      windows_version="windows-server-2012-r2" ;;
    * )
      error "Invalid VERSION specified, value \"$id\" is not recognized!" && return 1 ;;
  esac

  user_agent=$(get_agent)
  culture=$(getLanguage "$lang" "culture")

  local country="${culture#*-}"
  local iso_download_page_html=""
  local url="https://www.microsoft.com/en-us/evalcenter/download-$windows_version"

  [[ "$DEBUG" == [Yy1]* ]] && echo "Parsing download page: ${url}"
  iso_download_page_html=$(curl --silent --max-time 30 --user-agent "$user_agent" --location --max-filesize 1M --fail --proto =https --tlsv1.2 --http1.1 -- "$url") || {
    handle_curl_error "$?" "Microsoft"
    return $?
  }

  if ! [ "$iso_download_page_html" ]; then
    # This should only happen if there's been some change to where this download page is located
    error "Windows server download page gave us an empty response"
    return 1
  fi

  [[ "$DEBUG" == [Yy1]* ]] && echo "Getting download link.."

  if [[ "$enterprise_type" == "iot" ]]; then
    filter="https://go.microsoft.com/fwlink/?linkid=[0-9]\+&clcid=0x[0-9a-z]\+&culture=${culture,,}&country=${country^^}"
  else
    filter="https://go.microsoft.com/fwlink/p/?LinkID=[0-9]\+&clcid=0x[0-9a-z]\+&culture=${culture,,}&country=${country^^}"
  fi

  iso_download_links=$(echo "$iso_download_page_html" | grep -io "$filter") || {
    # This should only happen if there's been some change to the download endpoint web address
    if [[ "${lang,,}" == "en" ]] || [[ "${lang,,}" == "en-"* ]]; then
      error "Windows server download page gave us no download link!"
    else
      language=$(getLanguage "$lang" "desc")
      error "No download in the $language language available for $desc!"
    fi
    return 1
  }

  case "$enterprise_type" in
    "enterprise" )
      iso_download_link=$(echo "$iso_download_links" | head -n 2 | tail -n 1)
      ;;
    "iot" )
      if [[ "${PLATFORM,,}" == "x64" ]]; then
        iso_download_link=$(echo "$iso_download_links" | head -n 1)
      fi
      if [[ "${PLATFORM,,}" == "arm64" ]]; then
        iso_download_link=$(echo "$iso_download_links" | head -n 2 | tail -n 1)
      fi
      ;;
    "ltsc" )
      iso_download_link=$(echo "$iso_download_links" | head -n 4 | tail -n 1)
      ;;
    "server" )
      iso_download_link=$(echo "$iso_download_links" | head -n 1)
      ;;
    * )
      error "Invalid type specified, value \"$enterprise_type\" is not recognized!" && return 1 ;;
  esac

  [[ "$DEBUG" == [Yy1]* ]] && echo "Found download link: $iso_download_link"

  # Follow redirect so proceeding log message is useful
  # This is a request we make that Fido doesn't

  iso_download_link=$(curl --silent --max-time 30 --user-agent "$user_agent" --location --output /dev/null --silent --write-out "%{url_effective}" --head --fail --proto =https --tlsv1.2 --http1.1 -- "$iso_download_link") || {
    # This should only happen if the Microsoft servers are down
    handle_curl_error "$?" "Microsoft"
    return $?
  }

  MIDO_URL="$iso_download_link"
  return 0
}

getWindows() {

  local version="$1"
  local lang="$2"
  local desc="$3"

  local language edition
  language=$(getLanguage "$lang" "desc")
  edition=$(printEdition "$version" "$desc")

  local msg="Requesting $desc from the Microsoft servers..."
  info "$msg" && html "$msg"

  case "${version,,}" in
    "win2008r2" | "win81${PLATFORM,,}-enterprise"* | "win11${PLATFORM,,}-enterprise-iot"* | "win11${PLATFORM,,}-enterprise-ltsc"* )
      if [[ "${lang,,}" != "en" ]] && [[ "${lang,,}" != "en-"* ]]; then
        error "No download in the $language language available for $edition!"
        MIDO_URL="" && return 1
      fi ;;
  esac

  case "${version,,}" in
    "win11${PLATFORM,,}" ) ;;
    "win11${PLATFORM,,}-enterprise-iot"* ) ;;
    "win11${PLATFORM,,}-enterprise-ltsc"* ) ;;
    * )
      if [[ "${PLATFORM,,}" != "x64" ]]; then
        error "No download for the ${PLATFORM^^} platform available for $edition!"
        MIDO_URL="" && return 1
      fi ;;
  esac

  case "${version,,}" in
    "win10${PLATFORM,,}" | "win11${PLATFORM,,}" )
      download_windows "$version" "$lang" "$edition" && return 0
      ;;
    "win11${PLATFORM,,}-enterprise"* | "win10${PLATFORM,,}-enterprise"* )
      download_windows_eval "$version" "$lang" "$edition" && return 0
      ;;
    "win2025-eval" | "win2022-eval" | "win2019-eval" | "win2016-eval" | "win2012r2-eval" )
      download_windows_eval "$version" "$lang" "$edition" && return 0
      ;;
    "win81${PLATFORM,,}-enterprise"* | "win2008r2" )
      ;;
    * ) error "Invalid VERSION specified, value \"$version\" is not recognized!" ;;
  esac

  if [[ "${PLATFORM,,}" != "x64" ]]; then
    MIDO_URL=""
    return 1
  fi

  if [[ "${lang,,}" != "en" ]] && [[ "${lang,,}" != "en-"* ]]; then
    MIDO_URL=""
    return 1
  fi

  case "${version,,}" in
    "win81${PLATFORM,,}-enterprise"* )
      MIDO_URL="https://download.microsoft.com/download/B/9/9/B999286E-0A47-406D-8B3D-5B5AD7373A4A/9600.17050.WINBLUE_REFRESH.140317-1640_X64FRE_ENTERPRISE_EVAL_EN-US-IR3_CENA_X64FREE_EN-US_DV9.ISO"
      return 0
      ;;
    "win11${PLATFORM,,}-enterprise-iot"* | "win11${PLATFORM,,}-enterprise-ltsc"* )
      MIDO_URL="https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26100.1.240331-1435.ge_release_CLIENT_IOT_LTSC_EVAL_x64FRE_en-us.iso"
      return 0
      ;;
    "win2025-eval" )
      MIDO_URL="https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26100.1.240331-1435.ge_release_SERVER_EVAL_x64FRE_en-us.iso"
      return 0
      ;;
    "win2022-eval" )
      MIDO_URL="https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso"
      return 0
      ;;
    "win2019-eval" )
      MIDO_URL="https://software-download.microsoft.com/download/pr/17763.737.190906-2324.rs5_release_svc_refresh_SERVER_EVAL_x64FRE_en-us_1.iso"
      return 0
      ;;
    "win2016-eval" )
      MIDO_URL="https://software-download.microsoft.com/download/pr/Windows_Server_2016_Datacenter_EVAL_en-us_14393_refresh.ISO"
      return 0
      ;;
    "win2012r2-eval" )
      MIDO_URL="https://download.microsoft.com/download/6/2/A/62A76ABB-9990-4EFC-A4FE-C7D698DAEB96/9600.17050.WINBLUE_REFRESH.140317-1640_X64FRE_SERVER_EVAL_EN-US-IR3_SSS_X64FREE_EN-US_DV9.ISO"
      return 0
      ;;
    "win2008r2" )
      MIDO_URL="https://download.microsoft.com/download/4/1/D/41DEA7E0-B30D-4012-A1E3-F24DC03BA1BB/7601.17514.101119-1850_x64fre_server_eval_en-us-GRMSXEVAL_EN_DVD.iso"
      return 0
      ;;
  esac

  MIDO_URL=""
  return 1
}

getCatalog() {

  local id="$1"
  local ret="$2"
  local url=""
  local name=""
  local edition=""

  case "${id,,}" in
    "win11${PLATFORM,,}" )
      edition="Professional"
      name="Windows 11 Pro"
      url="https://go.microsoft.com/fwlink?linkid=2156292" ;;
    "win10${PLATFORM,,}" )
      edition="Professional"
      name="Windows 10 Pro"
      url="https://go.microsoft.com/fwlink/?LinkId=841361" ;;
    "win11${PLATFORM,,}-enterprise" | "win11${PLATFORM,,}-enterprise-eval")
      edition="Enterprise"
      name="Windows 11 Enterprise"
      url="https://go.microsoft.com/fwlink?linkid=2156292" ;;
    "win10${PLATFORM,,}-enterprise" | "win10${PLATFORM,,}-enterprise-eval" )
      edition="Enterprise"
      name="Windows 10 Enterprise"
      url="https://go.microsoft.com/fwlink/?LinkId=841361" ;;
  esac

  case "${ret,,}" in
    "url" ) echo "$url" ;;
    "name" ) echo "$name" ;;
    "edition" ) echo "$edition" ;;
    *) echo "";;
  esac

  return 0
}

getMG() {

  local version="$1"
  local lang="$2"
  local desc="$3"

  local locale=""
  local culture=""
  local language=""
  local user_agent=""

  user_agent=$(get_agent)
  language=$(getLanguage "$lang" "desc")
  culture=$(getLanguage "$lang" "culture")

  local msg="Requesting download link from massgrave.dev..."
  info "$msg" && html "$msg"

  local pattern=""
  local locale="${culture,,}"
  local platform="${PLATFORM,,}"
  local url="https://massgrave.dev/"

  if [[ "${PLATFORM,,}" != "arm64" ]]; then

    case "${version,,}" in
      "win11${PLATFORM,,}" )
        url+="windows_11_links"
        pattern="consumer"
        ;;
      "win11${PLATFORM,,}-enterprise" | "win11${PLATFORM,,}-enterprise-eval" )
        url+="windows_11_links"
        pattern="business"
        ;;
      "win11${PLATFORM,,}-ltsc" | "win11${PLATFORM,,}-enterprise-ltsc-eval" )
        url+="windows_ltsc_links"
        pattern="11_enterprise_ltsc"
        ;;
      "win11${PLATFORM,,}-iot" | "win11${PLATFORM,,}-enterprise-iot-eval" )
        url+="windows_ltsc_links"
        pattern="11_iot"
        ;;
      "win10${PLATFORM,,}" )
        url+="windows_10_links"
        pattern="consumer"
        ;;
      "win10${PLATFORM,,}-enterprise" | "win10${PLATFORM,,}-enterprise-eval" )
        url+="windows_10_links"
        pattern="business"
        ;;
      "win10${PLATFORM,,}-ltsc" | "win10${PLATFORM,,}-enterprise-ltsc-eval" )
        url+="windows_ltsc_links"
        pattern="10_enterprise_ltsc"
        ;;
      "win10${PLATFORM,,}-iot" | "win10${PLATFORM,,}-enterprise-iot-eval" )
        url+="windows_ltsc_links"
        pattern="10_iot"
        ;;
      "win81${PLATFORM,,}-enterprise" | "win81${PLATFORM,,}-enterprise-eval" )
        url+="windows_8.1_links"
        pattern="8.1_enterprise"
        locale=$(getLanguage "$lang" "code")
        [[ "$locale" == "sr" ]] && locale="sr-latn"
        ;;
      "win2025" | "win2025-eval" )
        url+="windows_server_links"
        pattern="server_2025"
        ;;
      "win2022" | "win2022-eval" )
        url+="windows_server_links"
        pattern="server_2022"
        ;;
      "win2019" | "win2019-eval" )
        url+="windows_server_links"
        pattern="server_2019"
        ;;
      "win2016" | "win2016-eval" )
        url+="windows_server_links"
        pattern="server_2016"
        locale=$(getLanguage "$lang" "code")
        [[ "$locale" == "hk" ]] && locale="ct"
        [[ "$locale" == "tw" ]] && locale="ct"
        ;;
      "win2012r2" | "win2012r2-eval" )
        url+="windows_server_links"
        pattern="server_2012_r2"
        locale=$(getLanguage "$lang" "code")
        ;;
      "win2008r2" | "win2008r2-eval" )
        url+="windows_server_links"
        pattern="server_2008_r2"
        locale=$(getLanguage "$lang" "code")
        ;;
      "win7x64" | "win7x64-enterprise" )
        url+="windows_7_links"
        pattern="enterprise"
        locale=$(getLanguage "$lang" "code")
        ;;
      "win7x64-ultimate" )
        url+="windows_7_links"
        pattern="ultimate"
        locale=$(getLanguage "$lang" "code")
        ;;
      "win7x86" | "win7x86-enterprise" )
        platform="x86"
        url+="windows_7_links"
        pattern="enterprise"
        locale=$(getLanguage "$lang" "code")
        ;;
      "win7x86-ultimate" )
        platform="x86"
        url+="windows_7_links"
        pattern="ultimate"
        locale=$(getLanguage "$lang" "code")
        ;;
      "winvistax64" | "winvistax64-enterprise" )
        url+="windows_vista_links"
        pattern="enterprise"
        locale=$(getLanguage "$lang" "code")
        ;;
      "winvistax64-ultimate" )
        url+="windows_vista_links"
        pattern="sp2"
        locale=$(getLanguage "$lang" "code")
        ;;
      "winvistax86" | "winvistax86-enterprise" )
        platform="x86"
        url+="windows_vista_links"
        pattern="enterprise"
        locale=$(getLanguage "$lang" "code")
        ;;
      "winvistax86-ultimate" )
        platform="x86"
        url+="windows_vista_links"
        pattern="sp2"
        locale=$(getLanguage "$lang" "code")
        ;;
      "winxpx86" )
        platform="x86"
        url+="windows_xp_links"
        pattern="xp"
        locale=$(getLanguage "$lang" "code")
        [[ "$locale" == "pt" ]] && locale="pt-br"
        [[ "$locale" == "pp" ]] && locale="pt-pt"
        [[ "$locale" == "cn" ]] && locale="zh-hans"
        [[ "$locale" == "hk" ]] && locale="zh-hk"
        [[ "$locale" == "tw" ]] && locale="zh-tw"
        ;;
      "winxpx64" )
        url+="windows_xp_links"
        pattern="xp"
        locale=$(getLanguage "$lang" "code")
        ;;
    esac

  else

    case "${version,,}" in
      "win11${PLATFORM,,}" | "win11${PLATFORM,,}-enterprise" | "win11${PLATFORM,,}-enterprise-eval" )
        url+="windows_arm_links"
        pattern="11_business"
        ;;
      "win11${PLATFORM,,}-ltsc" | "win11${PLATFORM,,}-enterprise-ltsc-eval" )
        url+="windows_arm_links"
        pattern="11_iot_enterprise_ltsc"
        ;;
      "win10${PLATFORM,,}" | "win10${PLATFORM,,}-enterprise" | "win10${PLATFORM,,}-enterprise-eval" )
        url+="windows_arm_links"
        pattern="Pro_10"
        locale="$language"
        [[ "$locale" == "Chinese" ]] && locale="ChnSimp"
        [[ "$locale" == "Chinese HK" ]] && locale="ChnTrad"
        [[ "$locale" == "Chinese TW" ]] && locale="ChnTrad"
        ;;
      "win10${PLATFORM,,}-ltsc" | "win10${PLATFORM,,}-enterprise-ltsc-eval" )
        url+="windows_arm_links"
        pattern="10_iot_enterprise_ltsc"
        ;;
    esac
  
  fi

  local body=""

  [[ "$DEBUG" == [Yy1]* ]] && echo "Parsing download page: ${url}"
  body=$(curl --silent --max-time 30 --user-agent "$user_agent" --location --max-filesize 1M --fail --proto =https --tlsv1.2 --http1.1 -- "$url") || {
    handle_curl_error "$?" "Massgrave"
    return $?
  }

  local list=""
  list=$(echo "$body" | grep -Eo "(http|https)://[a-zA-Z0-9./?=_%:-]*" | grep -i '\.iso$')

  local result=""
  result=$(echo "$list" | grep -i "${platform}" | grep "${pattern}" | grep -i -m 1 "${locale,,}_")

  if [ -z "$result" ]; then
    if [[ "${lang,,}" != "en" ]] && [[ "${lang,,}" != "en-"* ]]; then
      error "No download in the $language language available for $desc!"
    else
      error "Failed to parse download link for $desc! Please report this at $SUPPORT/issues."
    fi
    return 1
  fi

  MG_URL="$result"
  return 0
}

getESD() {

  local dir="$1"
  local version="$2"
  local lang="$3"
  local desc="$4"
  local culture
  local language
  local editionName
  local winCatalog size

  culture=$(getLanguage "$lang" "culture")
  winCatalog=$(getCatalog "$version" "url")
  editionName=$(getCatalog "$version" "edition")

  if [ -z "$winCatalog" ] || [ -z "$editionName" ]; then
    error "Invalid VERSION specified, value \"$version\" is not recognized!" && return 1
  fi

  local msg="Downloading product information from Microsoft server..."
  info "$msg" && html "$msg"

  rm -rf "$dir"
  mkdir -p "$dir"

  local wFile="catalog.cab"
  local xFile="products.xml"
  local eFile="esd_edition.xml"
  local fFile="products_filter.xml"

  { wget "$winCatalog" -O "$dir/$wFile" -q --timeout=30 --no-http-keep-alive; rc=$?; } || :

  msg="Failed to download $winCatalog"
  (( rc == 3 )) && error "$msg , cannot write file (disk full?)" && return 1
  (( rc == 4 )) && error "$msg , network failure!" && return 1
  (( rc == 8 )) && error "$msg , server issued an error response!" && return 1
  (( rc != 0 )) && error "$msg , reason: $rc" && return 1

  cd "$dir"

  if ! cabextract "$wFile" > /dev/null; then
    cd /run
    error "Failed to extract $wFile!" && return 1
  fi

  cd /run

  if [ ! -s "$dir/$xFile" ]; then
    error "Failed to find $xFile in $wFile!" && return 1
  fi

  local edQuery='//File[Architecture="'${PLATFORM}'"][Edition="'${editionName}'"]'

  echo -e '<Catalog>' > "$dir/$fFile"
  xmllint --nonet --xpath "${edQuery}" "$dir/$xFile" >> "$dir/$fFile" 2>/dev/null
  echo -e '</Catalog>'>> "$dir/$fFile"

  xmllint --nonet --xpath "//File[LanguageCode=\"${culture,,}\"]" "$dir/$fFile" >"$dir/$eFile"

  size=$(stat -c%s "$dir/$eFile")
  if ((size<20)); then
    desc=$(printEdition "$version" "$desc")
    language=$(getLanguage "$lang" "desc")
    error "No download in the $language language available for $desc!" && return 1
  fi

  local tag="FilePath"
  ESD=$(xmllint --nonet --xpath "//$tag" "$dir/$eFile" | sed -E -e "s/<[\/]?$tag>//g")

  if [ -z "$ESD" ]; then
    error "Failed to find ESD URL in $eFile!" && return 1
  fi

  tag="Sha1"
  ESD_SUM=$(xmllint --nonet --xpath "//$tag" "$dir/$eFile" | sed -E -e "s/<[\/]?$tag>//g")
  tag="Size"
  ESD_SIZE=$(xmllint --nonet --xpath "//$tag" "$dir/$eFile" | sed -E -e "s/<[\/]?$tag>//g")

  rm -rf "$dir"
  return 0
}

verifyFile() {

  local iso="$1"
  local size="$2"
  local total="$3"
  local check="$4"

  if [ -n "$size" ] && [[ "$total" != "$size" ]] && [[ "$size" != "0" ]]; then
    warn "The downloaded file has an unexpected size: $total bytes, while expected value was: $size bytes. Please report this at $SUPPORT/issues"
  fi

  local hash=""
  local algo="SHA256"

  [ -z "$check" ] && return 0
  [[ "$VERIFY" != [Yy1]* ]] && return 0
  [[ "${#check}" == "40" ]] && algo="SHA1"

  local msg="Verifying downloaded ISO..."
  info "$msg" && html "$msg"

  if [[ "${algo,,}" != "sha256" ]]; then
    hash=$(sha1sum "$iso" | cut -f1 -d' ')
  else
    hash=$(sha256sum "$iso" | cut -f1 -d' ')
  fi

  if [[ "$hash" == "$check" ]]; then
    info "Succesfully verified ISO!" && return 0
  fi

  error "The downloaded file has an invalid $algo checksum: $hash , while expected value was: $check. Please report this at $SUPPORT/issues"
  return 1
}

downloadFile() {

  local iso="$1"
  local url="$2"
  local sum="$3"
  local size="$4"
  local lang="$5"
  local desc="$6"
  local rc total progress domain dots space folder

  rm -f "$iso"

  if [ -n "$size" ] && [[ "$size" != "0" ]]; then
    folder=$(dirname -- "$iso")
    space=$(df --output=avail -B 1 "$folder" | tail -n 1)
    (( size > space )) && error "Not enough free space left to download file!" && return 1
  fi

  # Check if running with interactive TTY or redirected to docker log
  if [ -t 1 ]; then
    progress="--progress=bar:noscroll"
  else
    progress="--progress=dot:giga"
  fi

  local msg="Downloading $desc"
  html "$msg..."

  domain=$(echo "$url" | awk -F/ '{print $3}')
  dots=$(echo "$domain" | tr -cd '.' | wc -c)
  (( dots > 1 )) && domain=$(expr "$domain" : '.*\.\(.*\..*\)')

  if [ -n "$domain" ] && [[ "${domain,,}" != *"microsoft.com" ]]; then
    msg="Downloading $desc from $domain"
  fi

  info "$msg..."
  /run/progress.sh "$iso" "$size" "$msg ([P])..." &

  { wget "$url" -O "$iso" -q --timeout=30 --no-http-keep-alive --show-progress "$progress"; rc=$?; } || :

  fKill "progress.sh"

  if (( rc == 0 )) && [ -f "$iso" ]; then
    total=$(stat -c%s "$iso")
    if [ "$total" -lt 100000000 ]; then
      error "Invalid download link: $url (is only $total bytes?). Please report this at $SUPPORT/issues." && return 1
    fi
    verifyFile "$iso" "$size" "$total" "$sum" || return 1
    html "Download finished successfully..." && return 0
  fi

  msg="Failed to download $url"
  (( rc == 3 )) && error "$msg , cannot write file (disk full?)" && return 1
  (( rc == 4 )) && error "$msg , network failure!" && return 1
  (( rc == 8 )) && error "$msg , server issued an error response!" && return 1

  error "$msg , reason: $rc"
  return 1
}

downloadImage() {

  local iso="$1"
  local version="$2"
  local lang="$3"
  local delay=5
  local tried="n"
  local success="n"
  local url sum size base desc language
  local msg="Will retry after $delay seconds..."

  if [[ "${version,,}" == "http"* ]]; then
    base=$(basename "$iso")
    desc=$(fromFile "$base")
    downloadFile "$iso" "$version" "" "" "" "$desc" && return 0
    info "$msg" && html "$msg" && sleep "$delay"
    downloadFile "$iso" "$version" "" "" "" "$desc" && return 0
    rm -f "$iso"
    return 1
  fi

  if ! validVersion "$version" "en"; then
    error "Invalid VERSION specified, value \"$version\" is not recognized!" && return 1
  fi

  desc=$(printVersion "$version" "")

  if [[ "${lang,,}" != "en" ]] && [[ "${lang,,}" != "en-"* ]]; then
    language=$(getLanguage "$lang" "desc")
    if ! validVersion "$version" "$lang"; then
      desc=$(printEdition "$version" "$desc")
      error "The $language language version of $desc is not available, please switch to English." && return 1
    fi
    desc+=" in $language"
  fi

  if isMido "$version" "$lang"; then

    tried="y"
    success="n"

    if getWindows "$version" "$lang" "$desc"; then
      success="y"
    else
      info "$msg" && html "$msg" && sleep "$delay"
      getWindows "$version" "$lang" "$desc" && success="y"
    fi

    if [[ "$success" == "y" ]]; then
      size=$(getMido "$version" "$lang" "size" )
      sum=$(getMido "$version" "$lang" "sum")
      downloadFile "$iso" "$MIDO_URL" "$sum" "$size" "$lang" "$desc" && return 0
      info "$msg" && html "$msg" && sleep "$delay"
      downloadFile "$iso" "$MIDO_URL" "$sum" "$size" "$lang" "$desc" && return 0
      rm -f "$iso"
    fi
  fi

  switchEdition "$version"

  if isESD "$version" "$lang"; then

    if [[ "$tried" != "n" ]]; then
      info "Failed to download $desc, will try a diferent method now..."
    fi

    tried="y"
    success="n"

    if getESD "$TMP/esd" "$version" "$lang" "$desc"; then
      success="y"
    else
      info "$msg" && html "$msg" && sleep "$delay"
      getESD "$TMP/esd" "$version" "$lang" "$desc" && success="y"
    fi

    if [[ "$success" == "y" ]]; then
      ISO="${ISO%.*}.esd"
      downloadFile "$ISO" "$ESD" "$ESD_SUM" "$ESD_SIZE" "$lang" "$desc" && return 0
      info "$msg" && html "$msg" && sleep "$delay"
      downloadFile "$ISO" "$ESD" "$ESD_SUM" "$ESD_SIZE" "$lang" "$desc" && return 0
      rm -f "$ISO"
      ISO="$iso"
    fi

  fi

  for ((i=1;i<=MIRRORS;i++)); do

    url=$(getLink "$i" "$version" "$lang")

    if [ -n "$url" ]; then
      if [[ "$tried" != "n" ]]; then
        info "Failed to download $desc, will try another mirror now..."
      fi
      tried="y"
      size=$(getSize "$i" "$version" "$lang")
      sum=$(getHash "$i" "$version" "$lang")
      downloadFile "$iso" "$url" "$sum" "$size" "$lang" "$desc" && return 0
      info "$msg" && html "$msg" && sleep "$delay"
      downloadFile "$iso" "$url" "$sum" "$size" "$lang" "$desc" && return 0
      rm -f "$iso"
    fi

  done

  if isMG "$version" "$lang"; then

    if [[ "$tried" != "n" ]]; then
      info "Failed to download $desc, will try a diferent method now..."
    fi

    tried="y"
    success="n"

    if getMG "$version" "$lang" "$desc"; then
      success="y"
    else
      info "$msg" && html "$msg" && sleep "$delay"
      getMG "$version" "$lang" "$desc" && success="y"
    fi

    if [[ "$success" == "y" ]]; then
      downloadFile "$iso" "$MG_URL" "" "" "$lang" "$desc" && return 0
      info "$msg" && html "$msg" && sleep "$delay"
      downloadFile "$iso" "$MG_URL" "" "" "$lang" "$desc" && return 0
      rm -f "$iso"
    fi

  fi

  return 1
}

return 0
